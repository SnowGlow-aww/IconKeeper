import AppKit

let fm = FileManager.default

/// 数据都放在 ~/Library/Application Support/CustomAppIcons：
/// icons.conf 是守护列表，icons/ 存图标副本，apply-icons.log 记每次设置和修复
enum Store {
    static let home = fm.homeDirectoryForCurrentUser
    static let base = home.appendingPathComponent("Library/Application Support/CustomAppIcons")
    static let iconsDir = base.appendingPathComponent("icons")
    static let configURL = base.appendingPathComponent("icons.conf")
    static let logURL = base.appendingPathComponent("apply-icons.log")

    static func log(_ message: String) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = Data("\(stamp.string(from: Date())) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: logURL)
        }
    }

    static func lastLog() -> String? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map(String.init)
    }
}

struct Entry: Identifiable, Equatable {
    var app: String
    /// icons.conf 里的写法：icons/ 下的文件名，或绝对路径
    var icon: String

    var id: String { app }
    var name: String { ((app as NSString).lastPathComponent as NSString).deletingPathExtension }
    var iconPath: String { icon.hasPrefix("/") ? icon : Store.iconsDir.appendingPathComponent(icon).path }
    var iconIsManagedCopy: Bool { iconPath.hasPrefix(Store.iconsDir.path + "/") }
}

/// icons.conf 每行「app 路径 = 图标文件」
enum Config {
    static func load() -> [Entry] {
        guard let text = try? String(contentsOf: Store.configURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.range(of: " = ") else { return nil }
            return Entry(app: String(line[..<eq.lowerBound]), icon: String(line[eq.upperBound...]))
        }
    }

    static func save(_ entries: [Entry]) throws {
        var text = "# 每行：app 路径 = 图标文件（icons/ 目录下的文件名，或绝对路径）\n# 一般在 IconKeeper 窗口里管理即可\n"
        for entry in entries { text += "\(entry.app) = \(entry.icon)\n" }
        try fm.createDirectory(at: Store.base, withIntermediateDirectories: true)
        try text.write(to: Store.configURL, atomically: true, encoding: .utf8)
    }
}

enum Icons {
    enum Failure: LocalizedError {
        case unreadableImage(String)
        case denied

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let path): "读不到图标文件：\(path)"
            case .denied: "系统拒绝修改（检查「App 管理」里是否允许了 IconKeeper）"
            }
        }
    }

    /// 图标完好 = 包根目录有 Icon\r，且 FinderInfo 第 8 字节带 kHasCustomIcon (0x04)。
    /// 自更新的 app 升级时会删掉 Icon\r 却留下标志，程序坞就显示成文件夹。
    static func intact(_ app: String) -> Bool {
        guard fm.fileExists(atPath: app + "/Icon\r") else { return false }
        var info = [UInt8](repeating: 0, count: 32)
        return getxattr(app, "com.apple.FinderInfo", &info, info.count, 0, 0) >= 9 && info[8] & 0x04 != 0
    }

    static func apply(_ entry: Entry) throws {
        try apply(imageAt: entry.iconPath, to: entry.app)
    }

    static func apply(imageAt path: String, to app: String) throws {
        guard let image = NSImage(contentsOfFile: path) else { throw Failure.unreadableImage(path) }
        guard NSWorkspace.shared.setIcon(image, forFile: app, options: []) else { throw Failure.denied }
    }

    static func restoreOriginal(_ app: String) -> Bool {
        NSWorkspace.shared.setIcon(nil, forFile: app, options: [])
    }

    /// 取出 app 现有的自定义图标：Icon\r 资源分支里的第一份资源就是原样的 icns
    static func extractCustom(_ app: String) -> Data? {
        let path = app + "/Icon\r"
        let size = getxattr(path, "com.apple.ResourceFork", nil, 0, 0, 0)
        guard size > 16 else { return nil }
        var fork = [UInt8](repeating: 0, count: size)
        guard getxattr(path, "com.apple.ResourceFork", &fork, size, 0, 0) == size else { return nil }
        func be32(_ i: Int) -> Int { fork[i..<i + 4].reduce(0) { $0 << 8 | Int($1) } }
        let start = be32(0) + 4
        guard start <= size else { return nil }
        let end = start + be32(start - 4)
        guard end <= size, end - start > 8 else { return nil }
        let data = Data(fork[start..<end])
        return data.starts(with: "icns".utf8) ? data : nil
    }

    /// 程序坞会把失效时的文件夹图标缓存下来，清掉缓存再重启它（窗口和应用不受影响）
    static func refreshDock() {
        var dir = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &dir, dir.count) > 0 {
            let cacheDir = dir.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            try? fm.removeItem(atPath: cacheDir + "com.apple.dock.iconcache")
        }
        run("/usr/bin/killall", ["Dock"])
    }
}

/// 后台守护：~/Library/LaunchAgents 里的 LaunchAgent，WatchPaths 跟着守护列表走，
/// 列表里的 app 包根目录一有增删（Icon\r 被删）或 /Applications 里整包替换就跑一次 --check
enum Agent {
    static let label = "com.amia.custom-app-icons"
    static let plistURL = Store.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static var target: String { "gui/\(getuid())/\(label)" }

    static var loaded: Bool { run("/bin/launchctl", ["print", target]) == 0 }

    /// 后台守护要记住 IconKeeper 的位置，必须装在「应用程序」里。
    /// 从下载目录直接打开时系统会把 App 搬到随机的临时路径（App Translocation），不能指向那里
    static var appLocationOK: Bool {
        let path = Bundle.main.bundlePath
        return !path.contains("/AppTranslocation/")
            && (path.hasPrefix("/Applications/") || path.hasPrefix(Store.home.path + "/Applications/"))
    }

    /// 按当前列表写好 plist，内容有变或没在运行才重新加载
    @discardableResult
    static func sync(_ entries: [Entry]) -> Bool {
        guard appLocationOK else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/IconKeeper.app/Contents/MacOS/IconKeeper", "--check"],
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "com.amia.IconKeeper"],
            "WatchPaths": entries.map(\.app) + ["/Applications"],
            "RunAtLoad": true,
            "StartInterval": 3600,
            "ProcessType": "Background",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return false }
        if (try? Data(contentsOf: plistURL)) == data, loaded { return true }
        do { try data.write(to: plistURL, options: .atomic) } catch { return false }
        run("/bin/launchctl", ["bootout", target])
        for _ in 0..<5 {
            if run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path]) == 0 { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}
