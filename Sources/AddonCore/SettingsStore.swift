import Foundation

public struct SettingsStore {
    public let fileURL: URL
    public init(fileURL: URL? = nil) throws {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            guard let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw AddonError.message("无法定位本机应用数据目录。")
            }
            self.fileURL = parent.appendingPathComponent("WoWAddonManager", isDirectory: true).appendingPathComponent("settings.json")
        }
    }
    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppSettings() }
        do { return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: fileURL)) }
        catch { throw AddonError.message("无法读取已保存的配置。请保留配置文件并检查其内容：\(fileURL.path)") }
    }
    public func save(_ settings: AppSettings) throws {
        let parent = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
