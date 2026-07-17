import Cocoa
import InputMethodKit

// MARK: - Logging

/// 调试日志文件路径
let logPath = "/tmp/fime_debug.log"

/// 写一行日志到 `/tmp/fime_debug.log`
/// - Parameter msg: 日志内容
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

// MARK: - FIME Application

/// FIME 的应用主类
///
/// 继承 `NSApplication` 并重写 `sendEvent`，用于拦截 `.flagsChanged` 事件。
///
/// 为什么这么做：
/// - `handle(_:client:)` 收不到 modifier 键事件
/// - CGEvent tap 需要辅助功能权限
/// - `NSEvent.addLocalMonitorForEvents` 在输入法进程中收不到修饰键
/// - 但 `NSApplication.sendEvent` 在输入法进程中会收到所有事件
///   （包括 flagsChanged），因为输入法进程有完整的 NSApplication 运行循环
///
/// Squirrel（Rime）也使用相同的 `sendEvent` 重写方案。
final class FIMEApplication: NSApplication {
    /// 当前活跃的输入法控制器
    ///
    /// 由控制器在 `activateServer` / `deactivateServer` 中设置。
    /// 因为输入法进程内可能会创建多个控制器实例（每个客户端 app 一个），
    /// 所以用 weak 引用避免持有已失效的控制器。
    weak var activeController: FIMEController?

    /// 重写 sendEvent 拦截修饰键事件
    ///
    /// `sendEvent` 是 NSApplication 分发所有事件的入口点。
    /// 标记键（flagsChanged）是其中之一。
    ///
    /// - Parameter event: 系统事件
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            activeController?.handleFlagsChanged(event)
        }
        super.sendEvent(event)
    }
}

// MARK: - App Delegate

/// FIME 应用代理
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// IMK 服务器实例
    let server = IMKServer(
        name: "FIME_Connection",
        bundleIdentifier: Bundle.main.bundleIdentifier
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate: didFinishLaunching")
    }
}

// MARK: - 应用入口

let app = FIMEApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
