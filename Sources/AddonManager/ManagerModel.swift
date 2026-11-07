import AppKit
import Combine
import Foundation
import AddonCore

@MainActor
final class ManagerModel: ObservableObject {
    @Published private(set) var settings = AppSettings()
    @Published private(set) var isChecking = false
    @Published var errorMessage: String?
    private var store: SettingsStore?
    private let client = GitHubReleaseClient()
    private var timer: Task<Void, Never>?
    private var loadFailed = false

    init() {
        do {
            let testPath = ProcessInfo.processInfo.environment["WOW_ADDON_MANAGER_CONFIG"]
            let savedStore = try SettingsStore(fileURL: testPath.map { URL(fileURLWithPath: $0) })
            store = savedStore
            settings = try savedStore.load()
        } catch {
            loadFailed = true
            errorMessage = error.localizedDescription
        }
    }

    func start() {
        guard timer == nil, !loadFailed else { return }
        timer = Task {
            await checkAll()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
                if Task.isCancelled { return }
                await checkAll()
            }
        }
    }

    func selectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择魔兽世界插件目录"
        panel.message = "选择无限服客户端的 AddOns 文件夹。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var next = settings
        next.directoryPath = url.standardizedFileURL.path
        save(next, event: "已设置插件目录")
    }

    func saveAddon(existing: Addon?, name: String, repository: String, asset: String, directory: String, automatic: Bool) throws -> UUID {
        guard !loadFailed else { throw AddonError.message("配置读取失败，不能修改配置。") }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = try GitHubReleaseClient.parseRepository(repository)
        let assetName = asset.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AddonError.message("请输入插件名称。") }
        guard !assetName.isEmpty, assetName.lowercased().hasSuffix(".zip"), !assetName.contains("/"), !assetName.contains("\\") else { throw AddonError.message("请输入 ZIP 附件名或通配规则，例如 MyAddon-*.zip。") }
        guard !folder.isEmpty, folder.utf8.count <= 180, folder.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else { throw AddonError.message("插件文件夹名只能使用英文字母、数字、下划线和连字符。") }
        guard !settings.addons.contains(where: { $0.id != existing?.id && $0.addonDirectory.caseInsensitiveCompare(folder) == .orderedSame }) else { throw AddonError.message("已有插件使用此文件夹名。") }
        var next = settings
        if let existing, let index = next.addons.firstIndex(where: { $0.id == existing.id }) {
            guard existing.managedDirectory == nil || existing.addonDirectory == folder else { throw AddonError.message("已安装插件的文件夹名不能修改。") }
            next.addons[index].name = trimmedName
            next.addons[index].repository = repo
            next.addons[index].assetName = assetName
            next.addons[index].addonDirectory = folder
            next.addons[index].automaticUpdates = automatic
            try persist(&next, event: "已修改插件 \(trimmedName)")
            return existing.id
        } else {
            let addon = Addon(name: trimmedName, repository: repo, assetName: assetName, addonDirectory: folder, automaticUpdates: automatic)
            next.addons.append(addon)
            try persist(&next, event: "已添加插件 \(trimmedName)")
            return addon.id
        }
    }

    func remove(_ addon: Addon) {
        var next = settings
        next.addons.removeAll { $0.id == addon.id }
        save(next, event: "已移除插件配置 \(addon.name)；游戏文件未删除")
    }

    func setAutomatic(_ id: UUID, _ enabled: Bool) {
        var next = settings
        guard let index = next.addons.firstIndex(where: { $0.id == id }) else { return }
        next.addons[index].automaticUpdates = enabled
        save(next, event: "\(next.addons[index].name) · 自动更新已\(enabled ? "开启" : "关闭")")
    }

    func checkAll() async {
        guard !isChecking, !loadFailed else { return }
        isChecking = true
        defer { isChecking = false }
        for id in settings.addons.map(\.id) { await check(id, forceInstall: false) }
    }

    func checkOne(_ id: UUID, install: Bool) async {
        guard !isChecking, !loadFailed else { return }
        isChecking = true
        defer { isChecking = false }
        await check(id, forceInstall: install)
    }

    private func check(_ id: UUID, forceInstall: Bool) async {
        guard let addon = settings.addons.first(where: { $0.id == id }) else { return }
        do {
            let release = try await client.latest(repository: addon.repository)
            let asset = try client.asset(named: addon.assetName, in: release)
            let root = URL(fileURLWithPath: settings.directoryPath, isDirectory: true).standardizedFileURL
            let managed = addon.managedDirectory == root.path && addon.installedReleaseID != nil
            let installedPath = root.appendingPathComponent(addon.addonDirectory, isDirectory: true).path
            var existingDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: installedPath, isDirectory: &existingDirectory) && existingDirectory.boolValue
            let isCurrent = managed && exists && addon.installedReleaseID == release.id && addon.installedAssetID == asset.id && addon.installedDigest == asset.digest
            if isCurrent {
                try update(id, status: "已是最新 · \(release.tagName)", event: nil)
                return
            }
            guard forceInstall || addon.automaticUpdates else {
                try update(id, status: "发现 \(release.tagName)，自动更新已关闭", event: "\(addon.name) · 发现 \(release.tagName)")
                return
            }
            guard !settings.directoryPath.isEmpty else { throw AddonError.message("请先选择游戏插件目录。") }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AddonError.message("插件目录不存在，请重新选择。") }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("wow-addon-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let archive = temporary.appendingPathComponent("release.zip")
            try await client.download(asset, to: archive)
            _ = try await Task.detached(priority: .userInitiated) {
                try AddonInstaller().install(archive: archive, destination: root, addonDirectory: addon.addonDirectory, isManaged: managed)
            }.value
            guard let index = settings.addons.firstIndex(where: { $0.id == id }) else { return }
            var next = settings
            next.addons[index].installedReleaseID = release.id
            next.addons[index].installedAssetID = asset.id
            next.addons[index].installedDigest = asset.digest
            next.addons[index].installedTag = release.tagName
            next.addons[index].managedDirectory = root.path
            next.addons[index].lastStatus = "已安装 \(release.tagName)"
            try persist(&next, event: "\(addon.name) · 已安装 \(release.tagName)")
        } catch {
            do { try update(id, status: "需要处理：\(error.localizedDescription)", event: "\(addon.name) · \(error.localizedDescription)") }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func update(_ id: UUID, status: String, event: String?) throws {
        guard let index = settings.addons.firstIndex(where: { $0.id == id }) else { return }
        var next = settings
        next.addons[index].lastStatus = status
        try persist(&next, event: event)
    }
    private func save(_ value: AppSettings, event: String) {
        do { var next = value; try persist(&next, event: event) }
        catch { errorMessage = "保存失败：\(error.localizedDescription)" }
    }
    private func persist(_ value: inout AppSettings, event: String?) throws {
        if let event {
            value.history.insert(HistoryEntry(message: event), at: 0)
            if value.history.count > 100 { value.history = Array(value.history.prefix(100)) }
        }
        guard let store else { throw AddonError.message("配置存储不可用。") }
        try store.save(value)
        settings = value
    }
}
