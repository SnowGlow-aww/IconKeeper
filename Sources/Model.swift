import AppKit
import UniformTypeIdentifiers

struct AlertInfo {
    var title: String
    var message: String
    var offersSettings = false

    static let permission = AlertInfo(
        title: "没有「App 管理」权限",
        message: "到 系统设置 › 隐私与安全性 › App 管理 里打开 IconKeeper，再试一次。",
        offersSettings: true)
}

enum EntryStatus {
    case ok, lost, missingApp, missingIcon
}

struct ImportCandidate: Identifiable {
    let app: String
    let image: NSImage
    var selected = true

    var id: String { app }
    var name: String { ((app as NSString).lastPathComponent as NSString).deletingPathExtension }
}

@MainActor
final class Model: ObservableObject {
    @Published var entries: [Entry] = []
    /// 图标文件内容变了路径却没变，靠它让缩略图和状态重新算
    @Published var revision = 0
    @Published var agentLoaded = false
    @Published var lastLog: String?
    @Published var alert: AlertInfo?
    @Published var importCandidates: [ImportCandidate] = []
    /// 正在拖放悬停的目标：某一行的 app 路径，或整个窗口 (windowDropTarget)。
    /// 命令行工具的 SDK 没有 SwiftUI 宏插件，用不了 @State，视图状态放这里
    @Published var dropTarget: String?
    static let windowDropTarget = "window"

    func setDropTarget(_ target: String, _ active: Bool) {
        if active {
            dropTarget = target
        } else if dropTarget == target {
            dropTarget = nil
        }
    }

    init() {
        entries = Config.load()
        if Agent.appLocationOK {
            // 每次打开都按当前 app 位置和列表校准一次后台守护
            Agent.sync(entries)
        } else {
            alert = AlertInfo(
                title: "请先把 IconKeeper 拖进「应用程序」文件夹",
                message: "后台守护会记住 IconKeeper 的位置。放进「应用程序」文件夹后再打开，App 更新后才能自动补回图标。")
        }
        refresh()
    }

    func reload() {
        entries = Config.load()
        refresh()
    }

    private func refresh() {
        agentLoaded = Agent.loaded
        lastLog = Store.lastLog()
        revision += 1
    }

    func status(of entry: Entry) -> EntryStatus {
        if !fm.fileExists(atPath: entry.app) { return .missingApp }
        if !fm.fileExists(atPath: entry.iconPath) { return .missingIcon }
        return Icons.intact(entry.app) ? .ok : .lost
    }

    func enableAgent() {
        Agent.sync(entries)
        refresh()
    }

    // MARK: 添加、更换

    func addApp() {
        guard let app = Panels.chooseApp() else { return }
        pickIcon(for: app.path)
    }

    func pickIcon(for app: String) {
        guard let image = Panels.chooseImage(for: app) else { return }
        setIcon(app: app, image: image)
    }

    /// 拖进来的东西：拖到某一行上的图片 = 给这一行换图标；拖进来的 App = 新增
    func handleDrop(_ urls: [URL], onto entry: Entry?) -> Bool {
        let apps = urls.filter { $0.pathExtension == "app" }
        let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        // 拖放回调里不能直接弹模态面板，放到下一轮
        if let entry, let image = images.first {
            DispatchQueue.main.async { self.setIcon(app: entry.app, image: image) }
            return true
        }
        if let app = apps.first {
            DispatchQueue.main.async { self.pickIcon(for: app.path) }
            return true
        }
        if !images.isEmpty {
            alert = AlertInfo(title: "拖到哪个 App 上？", message: "把图片拖到要换图标的那一行上；要新增 App 就先把 App 拖进来。")
            return true
        }
        return false
    }

    func setIcon(app: String, image url: URL) {
        guard NSImage(contentsOf: url) != nil, let data = try? Data(contentsOf: url) else {
            alert = AlertInfo(title: "读不了这张图片", message: url.lastPathComponent)
            return
        }
        // 先真正设上图标，设不上就什么都不改，免得列表里记着一个没生效的图标
        do {
            try Icons.apply(imageAt: url.path, to: app)
        } catch Icons.Failure.denied {
            alert = .permission
            return
        } catch {
            alert = AlertInfo(title: "设置图标失败", message: error.localizedDescription)
            return
        }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let fileName = iconFileName(for: app, ext: ext)
        do {
            try fm.createDirectory(at: Store.iconsDir, withIntermediateDirectories: true)
            // 已经读进内存，选的就是旧副本本身也不怕；旧副本可能是唯一的一份，进废纸篓而不是直接删
            if let old = entries.first(where: { $0.app == app }) { trashManagedCopy(old) }
            try data.write(to: Store.iconsDir.appendingPathComponent(fileName))
        } catch {
            alert = AlertInfo(title: "保存图标副本失败", message: error.localizedDescription)
            return
        }
        upsert(Entry(app: app, icon: fileName))
        persist()
        Store.log("已设置图标: \(app)")
        Icons.refreshDock()
        refresh()
    }

    // MARK: 移除

    func remove(_ entry: Entry, restoreOriginal: Bool) {
        // 先清掉图标，清不掉就保持原样。后台检查会等 20 秒再读列表，赶得上下面把它移出列表
        if restoreOriginal, fm.fileExists(atPath: entry.app) {
            guard Icons.restoreOriginal(entry.app) else {
                alert = .permission
                return
            }
            Store.log("已恢复原图标: \(entry.app)")
            Icons.refreshDock()
        }
        entries.removeAll { $0.app == entry.app }
        persist()
        trashManagedCopy(entry)
        refresh()
    }

    /// icons/ 里的副本可能是这个图标唯一的一份（比如导入来的），只移进废纸篓
    private func trashManagedCopy(_ entry: Entry) {
        guard entry.iconIsManagedCopy, fm.fileExists(atPath: entry.iconPath) else { return }
        try? fm.trashItem(at: URL(fileURLWithPath: entry.iconPath), resultingItemURL: nil)
    }

    // MARK: 全部重新应用

    func reapplyAll() {
        var changed = false
        var failures: [String] = []
        var denied = false
        for entry in entries where fm.fileExists(atPath: entry.app) {
            do {
                try Icons.apply(entry)
                changed = true
            } catch Icons.Failure.denied {
                denied = true
            } catch {
                failures.append("\(entry.name)：\(error.localizedDescription)")
            }
        }
        if changed {
            Store.log("已全部重新应用")
            Icons.refreshDock()
        }
        if denied {
            alert = .permission
        } else if !failures.isEmpty {
            alert = AlertInfo(title: "有图标没设上", message: failures.joined(separator: "\n"))
        }
        refresh()
    }

    // MARK: 导入现有自定义图标

    func scanExisting() {
        let managed = Set(entries.map(\.app))
        var found: [ImportCandidate] = []
        for dir in ["/Applications", Store.home.appendingPathComponent("Applications").path] {
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for name in names.sorted() where name.hasSuffix(".app") {
                let app = dir + "/" + name
                guard !managed.contains(app), Icons.intact(app) else { continue }
                found.append(ImportCandidate(app: app, image: NSWorkspace.shared.icon(forFile: app)))
            }
        }
        if found.isEmpty {
            alert = AlertInfo(title: "没有可以导入的", message: "应用程序文件夹里换过图标的 App 都已经在守护了。")
        } else {
            importCandidates = found
        }
    }

    func importSelected() {
        var failures: [String] = []
        for candidate in importCandidates where candidate.selected {
            let icns = Icons.extractCustom(candidate.app)
            let ext = icns == nil ? "png" : "icns"
            guard let data = icns ?? pngData(candidate.image) else {
                failures.append(candidate.name)
                continue
            }
            let fileName = iconFileName(for: candidate.app, ext: ext)
            do {
                try fm.createDirectory(at: Store.iconsDir, withIntermediateDirectories: true)
                try data.write(to: Store.iconsDir.appendingPathComponent(fileName))
                upsert(Entry(app: candidate.app, icon: fileName))
                Store.log("已导入: \(candidate.app)")
            } catch {
                failures.append(candidate.name)
            }
        }
        importCandidates = []
        persist()
        if !failures.isEmpty {
            alert = AlertInfo(title: "有 App 没导入成功", message: failures.joined(separator: "、"))
        }
        refresh()
    }

    // MARK: 内部

    private func upsert(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.app == entry.app }) {
            entries[index] = entry
        } else {
            entries.append(entry)
            entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try Config.save(entries)
        } catch {
            alert = AlertInfo(title: "保存列表失败", message: error.localizedDescription)
            return false
        }
        Agent.sync(entries)
        return true
    }

    /// icons/ 里给这个 app 用的文件名。被别的 app 占用、或磁盘上已有不属于它的同名文件时加编号，
    /// 绝不覆盖别的文件（磁盘不分大小写）
    private func iconFileName(for app: String, ext: String) -> String {
        let base = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        let own = entries.first { $0.app == app }?.icon.lowercased()
        let taken = Set(entries.filter { $0.app != app }.map { $0.icon.lowercased() })
        func occupied(_ name: String) -> Bool {
            taken.contains(name.lowercased())
                || (name.lowercased() != own && fm.fileExists(atPath: Store.iconsDir.appendingPathComponent(name).path))
        }
        var name = "\(base).\(ext)"
        var number = 2
        while occupied(name) {
            name = "\(base) \(number).\(ext)"
            number += 1
        }
        return name
    }

    private func pngData(_ image: NSImage) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

enum Panels {
    /// 选图片的面板单独记住上次的文件夹，不被选 App 时的 /Applications 覆盖
    private static let imageFolderKey = "lastImageFolder"

    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择要换图标的 App"
        panel.prompt = "选择"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseImage(for app: String) -> URL? {
        let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if let folder = UserDefaults.standard.url(forKey: imageFolderKey) { panel.directoryURL = folder }
        panel.message = "给「\(name)」选一张图标（icns、png、jpg 都可以）"
        panel.prompt = "用这张"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: imageFolderKey)
        return url
    }
}
