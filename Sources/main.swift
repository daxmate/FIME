import Cocoa
import InputMethodKit

// MARK: - Logging

/// 调试日志文件路径
/// 所有 FIME 的日志都会追加到这个文件，方便开发调试
let logPath = "/tmp/fime_debug.log"

/// 写一行日志到 `/tmp/fime_debug.log`
/// - Parameter msg: 日志内容（会自动加 `[FIME]` 前缀和换行）
func log(_ msg: String) {
    let line = "[FIME] \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - App Delegate

/// FIME 应用代理
///
/// 负责创建 IMKServer 实例并启动输入法运行循环。
/// IMKServer 是 InputMethodKit 的核心组件，负责与系统输入法框架通信。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// IMK 服务器实例，连接名称必须与 Info.plist 中的 InputMethodConnectionName 一致
    let server = IMKServer(
        name: "FIME_Connection",
        bundleIdentifier: Bundle.main.bundleIdentifier
    )

    /// 应用启动完成后的回调
    /// - Parameter notification: 启动通知
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate: didFinishLaunching")
    }
}

// MARK: - 应用入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
