import Cocoa
import InputMethodKit

// MARK: - Logging

let logPath = "/tmp/fime_debug.log"

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = IMKServer(
        name: "FIME_Connection",
        bundleIdentifier: Bundle.main.bundleIdentifier
    )
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate: didFinishLaunching")
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
