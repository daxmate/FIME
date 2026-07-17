import Cocoa
import InputMethodKit
import CoreGraphics

// MARK: - 输入模式

/// FIME 输入模式
enum InputMode: String {
    /// 原始输出模式 — 透传所有按键
    case raw = "ABC"
    /// 模糊预测模式 — 捕获字母输入，显示候选词
    case fuzzy = "FIME"
}

/// FIME 输入法核心控制器
///
/// ## 模式切换
/// 快速按一次 Shift（左/右均可）切换模式。
///
/// ### 原理
/// modifier 键事件（Shift 等）输入法收不到，也无法通过 AppKit
/// 的 event monitor 或 sendEvent 拦截。方案：用 `CGEventSourceFlagsState`
/// 定时轮询当前修饰键状态，检测 Shift 的按下/释放时序。
///
/// `CGEventSourceFlagsState` 是 CoreGraphics 系统调用，读取系统范围
/// 的修饰键状态，不需要辅助功能权限。
@objc(FIMEController)
final class FIMEController: IMKInputController {

    // MARK: - 属性

    private let engine: WordEngine
    private var currentInput = ""
    private var selectedIndex = 0
    private let panel: FIMEPanel

    /// 当前模式，默认为 raw
    private var mode: InputMode = .raw {
        didSet { log("mode: \(mode.rawValue)") }
    }

    /// Shift 按下的时间点，由轮询定时器记录
    private var shiftDownAt: TimeInterval = 0
    /// 上次轮询时 Shift 的状态
    private var lastPollShift = false
    /// 轮询定时器
    private var shiftTimer: Timer?

    /// 模式指示器前缀
    private var modeIndicator: String { "[\(mode.rawValue)]" }

    // MARK: - 初始化

    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        let db = WordDatabase()
        self.engine = WordEngine(database: db)
        self.panel = FIMEPanel()
        super.init(server: server, delegate: delegate, client: client)
        startShiftPolling()
        log("init OK, mode: \(mode.rawValue)")
    }

    /// 启动 Shift 状态轮询
    ///
    /// 每 80ms 读取一次 `CGEventSourceFlagsState`，检测 Shift 状态变化。
    /// 一旦发现 Shift 被按下又释放（30ms~500ms 内），触发模式切换。
    private func startShiftPolling() {
        shiftTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) {
            [weak self] _ in
            self?.pollShiftState()
        }
    }

    /// 轮询一次 Shift 状态
    private func pollShiftState() {
        let currentShift = CGEventSource.flagsState(.combinedSessionState)
            .contains(.maskShift)

        if currentShift && !lastPollShift {
            // Shift 被按下
            shiftDownAt = CACurrentMediaTime()
        } else if !currentShift && lastPollShift, shiftDownAt > 0 {
            // Shift 被释放 — 检查是否短按切换
            let elapsed = CACurrentMediaTime() - shiftDownAt
            if client() != nil && elapsed >= 0.03 && elapsed <= 0.5 {
                toggleMode()
            }
            shiftDownAt = 0
        }

        lastPollShift = currentShift
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        log("activateServer")
    }

    override func deactivateServer(_ sender: Any!) {
        super.deactivateServer(sender)
        currentInput = ""
        selectedIndex = 0
        panel.dismiss()
        log("deactivateServer")
    }

    // MARK: - 键盘事件

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let clt = sender as? any IMKTextInput else { return false }

        switch mode {
        case .raw:
            return handleRawMode(event: event, clt: clt)
        case .fuzzy:
            return handleFuzzyMode(event: event, clt: clt)
        }
    }

    // MARK: - Raw Mode

    private func handleRawMode(event: NSEvent, clt: any IMKTextInput) -> Bool {
        if !currentInput.isEmpty {
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
            clearState()
        }
        return false
    }

    // MARK: - Fuzzy Mode

    private func handleFuzzyMode(event: NSEvent, clt: any IMKTextInput) -> Bool {
        // Backspace
        if event.keyCode == 51 {
            guard !currentInput.isEmpty else { return false }
            currentInput.removeLast()
            selectedIndex = 0
            if currentInput.isEmpty {
                clt.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
                panel.dismiss()
            } else {
                updateMarkedText(clt: clt)
                showCandidates(clt: clt)
            }
            return true
        }

        // 方向键
        if [123, 124, 125, 126].contains(event.keyCode) {
            guard !currentInput.isEmpty else { return false }
            let cands = engine.candidates(for: currentInput)
            guard !cands.isEmpty else { return false }
            selectedIndex = event.keyCode == 125 || event.keyCode == 124
                ? min(selectedIndex + 1, cands.count - 1)
                : max(selectedIndex - 1, 0)
            panel.updateHighlight(selectedIndex)
            updateMarkedText(clt: clt)
            return true
        }

        // 字符键
        if let chars = event.characters, let firstChar = chars.first {
            if firstChar.isLetter {
                currentInput.append(firstChar.lowercased())
                selectedIndex = 0
                updateMarkedText(clt: clt)
                showCandidates(clt: clt)
                return true
            }

            if firstChar == " " {
                if !currentInput.isEmpty {
                    return commitSelected(clt: clt, space: true)
                } else {
                    clt.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                return true
            }

            if firstChar >= "1" && firstChar <= "8" {
                guard !currentInput.isEmpty else { return false }
                return commitNth(Int(String(firstChar))! - 1, clt: clt)
            }
        }

        // 功能键
        switch event.keyCode {
        case 53: // Escape
            guard !currentInput.isEmpty else { return false }
            clearInline(clt: clt)
            return true
        case 36: // Return
            guard !currentInput.isEmpty else { return false }
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
            clearState()
            return true
        case 48: // Tab
            guard !currentInput.isEmpty else { return false }
            let cands = engine.candidates(for: currentInput)
            guard !cands.isEmpty else { return false }
            selectedIndex = (selectedIndex + 1) % cands.count
            panel.updateHighlight(selectedIndex)
            updateMarkedText(clt: clt)
            return true
        default:
            return false
        }
    }

    // MARK: - 模式切换

    private func toggleMode() {
        // 提交未完成的输入
        if !currentInput.isEmpty, let clt = client() {
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        clearState()

        mode = mode == .raw ? .fuzzy : .raw

        // 视觉提示
        if let clt = client() {
            var caretRect = NSRect.zero
            _ = clt.attributes(forCharacterIndex: 0, lineHeightRectangle: &caretRect)
            panel.showModeIndicator(mode.rawValue, near: caretRect)
        }
    }

    // MARK: - 提交

    private func commitSelected(clt: any IMKTextInput, space: Bool = false) -> Bool {
        let cands = engine.candidates(for: currentInput)
        let output: String
        if let word = cands[safe: selectedIndex] {
            engine.select(word)
            output = space ? word + " " : word
        } else if let first = cands.first {
            engine.select(first)
            output = space ? first + " " : first
        } else {
            output = space ? currentInput + " " : currentInput
        }
        clt.insertText(output, replacementRange: NSRange(location: NSNotFound, length: 0))
        clearState()
        return true
    }

    private func commitNth(_ idx: Int, clt: any IMKTextInput) -> Bool {
        let cands = engine.candidates(for: currentInput)
        guard let word = cands[safe: idx] else { return false }
        engine.select(word)
        clt.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))
        clearState()
        return true
    }

    // MARK: - 显示

    private func updateMarkedText(clt: any IMKTextInput) {
        let cands = engine.candidates(for: currentInput)
        let display: String
        if let word = cands[safe: selectedIndex] {
            display = "\(modeIndicator) \(currentInput) ▸ \(word)"
        } else {
            display = "\(modeIndicator) \(currentInput)"
        }
        clt.setMarkedText(display,
            selectionRange: NSRange(location: currentInput.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func showCandidates(clt: any IMKTextInput) {
        let cands = engine.candidates(for: currentInput)
        if cands.isEmpty { panel.dismiss(); return }

        var caretRect = NSRect.zero
        _ = clt.attributes(forCharacterIndex: 0, lineHeightRectangle: &caretRect)
        panel.update(candidates: cands, highlighted: selectedIndex) { [weak self] idx in
            guard let self = self, let clt = self.client() else { return }
            let cands = self.engine.candidates(for: self.currentInput)
            guard let word = cands[safe: idx] else { return }
            self.engine.select(word)
            clt.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.clearState()
        }
        panel.showNear(caretRect)
    }

    // MARK: - 辅助

    private func clearInline(clt: any IMKTextInput) {
        clt.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        clearState()
    }

    private func clearState() {
        currentInput = ""
        selectedIndex = 0
        panel.dismiss()
    }

    // MARK: - IMK 回调

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard mode == .fuzzy, let clt = sender as? any IMKTextInput, let string = string else { return false }
        for char in string {
            if char.isLetter {
                currentInput.append(char.lowercased())
                clt.setMarkedText(currentInput,
                    selectionRange: NSRange(location: currentInput.count, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        selectedIndex = 0
        showCandidates(clt: clt)
        return true
    }

    override func commitComposition(_ sender: Any!) {
        guard let clt = self.client(), !currentInput.isEmpty else { return }
        clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
        clearState()
    }

    override func hidePalettes() {
        panel.dismiss()
        super.hidePalettes()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
