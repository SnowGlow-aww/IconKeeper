import SwiftUI

struct IconKeeperApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = Model()

    var body: some Scene {
        Window("IconKeeper", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 420)
        }
        .defaultSize(width: 700, height: 540)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private let appManagementSettings = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!

struct ContentView: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                ContentUnavailableView {
                    Label("还没有守护的 App", systemImage: "app.dashed")
                } description: {
                    Text("点右上角的 ＋ 添加，或者直接把 App 拖进窗口。\n已经换过图标的 App 可以用「导入」一键收进来。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.entries) { entry in
                    EntryRow(entry: entry)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            StatusBar()
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls, onto: nil)
        } isTargeted: { model.setDropTarget(Model.windowDropTarget, $0) }
        .overlay {
            if model.dropTarget == Model.windowDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.addApp() } label: { Label("添加 App", systemImage: "plus") }
                    .help("添加 App 并选择图标")
                Button { model.scanExisting() } label: { Label("导入", systemImage: "square.and.arrow.down") }
                    .help("把已经换过图标、还没守护的 App 收进来")
                Button { model.reapplyAll() } label: { Label("全部重新应用", systemImage: "arrow.clockwise") }
                    .help("把列表里的图标全部重新设置一遍")
                    .disabled(model.entries.isEmpty)
                Button { NSWorkspace.shared.open(Store.iconsDir) } label: { Label("图标文件夹", systemImage: "folder") }
                    .help("打开存放图标副本的文件夹")
            }
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { info in
            if info.offersSettings {
                Button("打开系统设置") { NSWorkspace.shared.open(appManagementSettings) }
            }
            Button("好", role: .cancel) {}
        } message: { info in
            Text(info.message)
        }
        .sheet(isPresented: Binding(
            get: { !model.importCandidates.isEmpty },
            set: { if !$0 { model.importCandidates = [] } }
        )) {
            ImportSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }
}

struct EntryRow: View {
    @EnvironmentObject private var model: Model
    let entry: Entry

    var body: some View {
        HStack(spacing: 14) {
            IconThumb(path: entry.iconPath, revision: model.revision)
                .frame(width: 52, height: 52)
                .overlay {
                    if model.dropTarget == entry.app {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5]))
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.headline)
                Text(entry.app)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                StatusLabel(status: model.status(of: entry))
            }
            Spacer(minLength: 8)
            Button("更换图标…") { model.pickIcon(for: entry.app) }
            Menu {
                Button("恢复原图标并移除") { model.remove(entry, restoreOriginal: true) }
                Button("保留当前图标，只停止守护") { model.remove(entry, restoreOriginal: false) }
                Divider()
                Button("在访达中显示 App") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.app)])
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls, onto: entry)
        } isTargeted: { model.setDropTarget(entry.app, $0) }
    }
}

struct IconThumb: View {
    let path: String
    /// 只用来在图标文件被覆盖后触发重绘
    let revision: Int

    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusLabel: View {
    let status: EntryStatus

    var body: some View {
        Group {
            switch status {
            case .ok:
                Label("已生效", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .lost:
                Label("图标丢失，后台会自动补回", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .missingApp:
                Label("找不到这个 App", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            case .missingIcon:
                Label("图标文件不见了，请重新选择", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .font(.caption)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.agentLoaded ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            if model.agentLoaded {
                Text("后台守护已开启 · App 更新抹掉图标后约 20 秒内自动补回")
            } else {
                Text("后台守护没有运行")
                Button("开启") { model.enableAgent() }
                    .controlSize(.small)
            }
            Spacer(minLength: 12)
            if let last = model.lastLog {
                Text("最近：" + last.replacingOccurrences(of: "/Applications/", with: ""))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct ImportSheet: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这些 App 换过图标，但还没有守护").font(.headline)
            Text("导入会把它们现在的图标原样存一份，以后 App 更新抹掉了就自动补回。")
                .font(.callout)
                .foregroundStyle(.secondary)
            List($model.importCandidates) { $candidate in
                Toggle(isOn: $candidate.selected) {
                    HStack(spacing: 10) {
                        Image(nsImage: candidate.image)
                            .resizable()
                            .frame(width: 32, height: 32)
                        Text(candidate.name)
                    }
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("取消") { model.importCandidates = [] }
                    .keyboardShortcut(.cancelAction)
                Button("导入所选") { model.importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.importCandidates.contains { $0.selected })
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
