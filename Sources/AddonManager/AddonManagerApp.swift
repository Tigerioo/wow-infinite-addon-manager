import AppKit
import SwiftUI
import AddonCore

@main
struct AddonManagerApp: App {
    @StateObject private var model = ManagerModel()
    var body: some Scene {
        WindowGroup("魔兽插件管理器") {
            ContentView().environmentObject(model)
                .frame(minWidth: 760, minHeight: 500)
                .task { model.start() }
        }
        .windowStyle(.titleBar)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: ManagerModel
    @State private var showingAdd = false
    @State private var editingAddon: Addon?
    @State private var selection = 0

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("插件管理", systemImage: "square.grid.2x2").tag(0)
                Label("更新记录", systemImage: "clock.arrow.circlepath").tag(1)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            if selection == 1 { HistoryView() }
            else { plugins }
        }
        .sheet(isPresented: $showingAdd) { AddAddonView(addon: nil) }
        .sheet(item: $editingAddon) { AddAddonView(addon: $0) }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var plugins: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("插件管理").font(.title2.weight(.semibold))
                Spacer()
                Button { model.selectDirectory() } label: { Text("选择插件目录…") }
                    .disabled(model.isChecking || model.loadFailed)
                Button { showingAdd = true } label: { Label("添加插件", systemImage: "plus") }
                    .disabled(model.isChecking || model.settings.directoryPath.isEmpty)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            HStack(alignment: .top, spacing: 8) {
                Text("插件目录").foregroundStyle(.secondary)
                if model.settings.directoryPath.isEmpty {
                    Text("尚未选择，请先选择无限服客户端的 AddOns 文件夹。")
                } else {
                    Text(model.settings.directoryPath).textSelection(.enabled).lineLimit(2)
                }
                Spacer()
            }.font(.callout).padding(.horizontal, 24).padding(.bottom, 14)
            Divider()
            HStack {
                Button { Task { await model.checkAll() } } label: { Label("检查更新", systemImage: "arrow.clockwise") }
                    .disabled(model.isChecking || model.settings.addons.isEmpty)
                if model.isChecking { ProgressView().controlSize(.small); Text("正在检查或安装…").foregroundStyle(.secondary) }
                Spacer()
                Text("运行期间每 6 小时检查一次").foregroundStyle(.secondary)
            }.font(.callout).padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            if model.settings.addons.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有插件").font(.headline)
                    Text(model.settings.directoryPath.isEmpty ? "先选择插件目录，再添加 GitHub 仓库。" : "添加你的 GitHub 仓库，配置 Release 附件和插件文件夹。")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.settings.addons) { addon in
                        AddonRow(addon: addon, edit: { editingAddon = addon })
                    }
                }.listStyle(.inset)
            }
            Divider()
            Text("自动更新仅在本应用运行时生效。更新前请退出游戏；不会覆盖未纳管的同名文件夹。")
                .foregroundStyle(.secondary).font(.caption).padding(.horizontal, 24).padding(.vertical, 10)
        }
    }
}

struct AddonRow: View {
    @EnvironmentObject private var model: ManagerModel
    let addon: Addon
    let edit: () -> Void
    @State private var confirmingRemoval = false
    @State private var confirmingAdoption = false
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(addon.name).font(.headline)
                Text(addon.repository).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("附件：\(addon.assetName) · 目录：\(addon.addonDirectory)").font(.caption).foregroundStyle(.secondary)
                Text(addon.lastStatus).font(.callout).foregroundStyle(addon.lastStatus.hasPrefix("需要处理") ? Color.red : Color.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 10) {
                Toggle("自动更新", isOn: Binding(get: { addon.automaticUpdates }, set: { model.setAutomatic(addon.id, $0) }))
                    .disabled(model.isChecking)
                HStack {
                    if model.canAdopt(addon) {
                        Button("接管已有插件") { confirmingAdoption = true }
                    }
                    Button("编辑", action: edit)
                    Button("移除") { confirmingRemoval = true }
                    Button("检查并安装") { Task { await model.checkOne(addon.id, install: true) } }
                }.disabled(model.isChecking)
            }.fixedSize()
        }.padding(.vertical, 9)
        .alert("接管已有插件？", isPresented: $confirmingAdoption) {
            Button("取消", role: .cancel) {}
            Button("备份并接管") { Task { await model.checkOne(addon.id, install: true, adoptExisting: true) } }
        } message: {
            Text("将备份现有的 \(addon.addonDirectory) 文件夹，再用指定 Release 替换。该文件夹中的本地修改不会自动合并，请先退出游戏并确认备份。")
        }
        .alert("移除插件配置？", isPresented: $confirmingRemoval) {
            Button("取消", role: .cancel) {}
            Button("移除配置", role: .destructive) { model.remove(addon) }
        } message: {
            Text("将停止管理 \(addon.name)。游戏目录中的插件和备份文件不会删除。")
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: ManagerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("更新记录").font(.title2.weight(.semibold)).padding(24)
            Divider()
            if model.settings.history.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.settings.history) { item in
                    HStack(alignment: .top) {
                        Text(item.message).textSelection(.enabled)
                        Spacer()
                        Text(item.date, style: .date).foregroundStyle(.secondary)
                        Text(item.date, style: .time).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.listStyle(.inset)
            }
        }
    }
}

struct AddAddonView: View {
    @EnvironmentObject private var model: ManagerModel
    @Environment(\.dismiss) private var dismiss
    let addon: Addon?
    @State private var name = ""
    @State private var repository = ""
    @State private var asset = ""
    @State private var directory = ""
    @State private var automatic = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(addon == nil ? "添加插件" : "编辑插件").font(.title2.weight(.semibold))
            Form {
                TextField("插件名称", text: $name)
                TextField("GitHub 仓库", text: $repository, prompt: Text("owner/repository 或 HTTPS 地址"))
                TextField("Release ZIP 附件名或规则", text: $asset, prompt: Text("例如 MyAddon-*.zip"))
                TextField("插件文件夹名", text: $directory, prompt: Text("例如 MyAddon"))
                    .disabled(addon?.managedDirectory != nil)
                Toggle("自动检查并安装更新", isOn: $automatic)
            }.formStyle(.grouped)
            Text("支持使用 * 匹配版本号；必须唯一匹配公开仓库正式 Release 中的 ZIP。已有同名文件夹不会自动覆盖。")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(addon == nil ? "添加" : "保存") {
                    do {
                        let id = try model.saveAddon(existing: addon, name: name, repository: repository, asset: asset, directory: directory, automatic: automatic)
                        dismiss()
                        Task { await model.checkOne(id, install: false) }
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 530)
        .onAppear {
            if let addon {
                name = addon.name; repository = addon.repository; asset = addon.assetName
                directory = addon.addonDirectory; automatic = addon.automaticUpdates
            }
        }
    }
}
