import AppKit

/// 双击打开是窗口；LaunchAgent 用 --check 在后台检查修复；--install-agent 只写好后台守护就退出
@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--check") { check() }
        if arguments.contains("--install-agent") { exit(Agent.sync(Config.load()) ? 0 : 1) }
        IconKeeperApp.main()
    }

    static func check() -> Never {
        func broken() -> [Entry] {
            Config.load().filter { fm.fileExists(atPath: $0.app) && !Icons.intact($0.app) }
        }
        guard !broken().isEmpty else { exit(0) }

        // 刚触发时可能还在更新中，等它写完再动手
        Thread.sleep(forTimeInterval: 20)

        var changed = false
        for entry in broken() {
            do {
                try Icons.apply(entry)
                Store.log("已恢复图标: \(entry.app)")
                changed = true
            } catch {
                Store.log("恢复失败: \(entry.app) — \(error.localizedDescription)")
            }
        }
        if changed { Icons.refreshDock() }
        exit(0)
    }
}
