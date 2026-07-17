import Cocoa
import InputMethodKit

// MARK: - 输入模式

/// FIME 输入模式
///
/// - `raw`: 原始输出模式
///   - 所有按键直接透传到当前应用
///   - 按 Shift 切换到 fuzzy
///
/// - `fuzzy`: 模糊预测模式
///   - 捕获字母输入，子序列匹配，显示候选
///   - 按 Shift 切换到 raw
enum InputMode: String {
    case raw = "ABC"
    case fuzzy = "FIME"
}

// MARK: - 输入法控制器

/// FIME 输入法核心控制器
///
/// ## 模式切换
/// 快速按一次 Shift（左/右均可）切换模式。
///
/// ### 原理
/// modifier 键（Shift/Ctrl/Option）的事件类型是 `flagsChanged`，
/// 不是 `keyDown`，所以 `handle(_:client:)` 收不到它们。
///
/// 解决方案（来自 Squirrel/Rime）：
/// 1. `FIMEApplication` 继承 `NSApplication`，重写 `sendEvent`
/// 2. `sendEvent` 是 NSApplication 分发所有事件的入口
/// 3. 拦截 `.flagsChanged` 事件，转发给活跃的控制器
/// 4. 控制器追踪 Shift 按下的时序：
///    - 30ms~500ms 内的快速按+放 → 模式切换
///    - 长按 >500ms → 修饰键用途，不切换
@objc(FIMEController)
final class FIMEController: IMKInputController {

    // MARK: - 属性

    /// 预测引擎
    private let engine: WordEngine

    /// 当前输入
    private var currentInput = ""

    /// 当前选中的候选索引
    private var selectedIndex = 0

    /// 自定义候选窗
    private let panel: FIMEPanel

    /// 当前模式，默认为 raw
    private var mode: InputMode = .raw {
        didSet {
            log("mode: \(mode.rawValue)")
        }
    }

    /// Shift 按下的时间点
    private var shiftDownAt: TimeInterval = 0

    /// Shift 是否按下
    private var shiftIsDown = false

    /// 模式指示器前缀
    private var modeIndicator: String {
        "[\(mode.rawValue)]"
    }

    // MARK: - 初始化

    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        let db = WordDatabase()
        self.engine = WordEngine(database: db)
        self.panel = FIMEPanel()
        super.init(server: server, delegate: delegate, client: client)
        log("init OK, mode: \(mode.rawValue)")
    }

    /// 输入法被激活
    ///
    /// 将自己注册到 `FIMEApplication.activeController`，
    /// 这样 `sendEvent` 才能把 flagsChanged 事件转发过来。
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        (NSApp as? FIMEApplication)?.activeController = self
        log("activateServer: registered")
    }

    /// 输入法被停用
    override func deactivateServer(_ sender: Any!) {
        super.deactivateServer(sender)
        // 如果本控制器是当前的 activeController，清除引用
        if (NSApp as? FIMEApplication)?.activeController === self {
            (NSApp as? FIMEApplication)?.activeController = nil
        }
        currentInput = ""
        selectedIndex = 0
        panel.dismiss()
        log("deactivateServer")
    }

    // MARK: - flagsChanged 事件处理

    /// 处理 flagsChanged 事件（由 `FIMEApplication.sendEvent` 调用）
    ///
    /// 监听 Shift 键的按下和释放，通过时间差判断是「切换」还是「修饰」。
    ///
    /// - Parameter event: NSEvent，类型为 `.flagsChanged`
    func handleFlagsChanged(_ event: NSEvent) {
        let nowShiftIsDown = event.modifierFlags.contains(.shift)

        if nowShiftIsDown && !shiftIsDown {
            // Shift 按下
            shiftDownAt = CACurrentMediaTime()
        } else if !nowShiftIsDown && shiftIsDown, shiftDownAt > 0 {
            // Shift 释放 — 检查是否是短按切换
            let elapsed = CACurrentMediaTime() - shiftDownAt
            if elapsed >= 0.03 && elapsed <= 0.5 {
                toggleMode()
                log("shift toggle: \(Int(elapsed * 1000))ms")
            }
            shiftDownAt = 0
        }

        shiftIsDown = nowShiftIsDown
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

    /// 原始输出模式：所有按键透传
    private func handleRawMode(event: NSEvent, clt: any IMKTextInput) -> Bool {
        if !currentInput.isEmpty {
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
            currentInput = ""
            selectedIndex = 0
            panel.dismiss()
        }
        return false
    }

    // MARK: - Fuzzy Mode

    /// 模糊预测模式：捕获字母，匹配候选
    private func handleFuzzyMode(event: NSEvent, clt: any IMKTextInput) -> Bool {
        // ── Backspace ──
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

        // ── 方向键 ──
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

        // ── 字符键 ──
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

        // ── 功能键 ──
        switch event.keyCode {
        case 53: // Escape
            guard !currentInput.isEmpty else { return false }
            clearInput(clt: clt)
            return true
        case 36: // Return
            guard !currentInput.isEmpty else { return false }
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
            clearInput(clt: clt)
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

    /// 切换模式（raw ↔ fuzzy）并显示视觉提示
    private func toggleMode() {
        if !currentInput.isEmpty, let clt = client() {
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        currentInput = ""
        selectedIndex = 0
        panel.dismiss()

        mode = mode == .raw ? .fuzzy : .raw

        // 显示模式切换的视觉提示
        showModeIndicator()
    }

    /// 在光标附近显示短暂的模式切换提示
    private func showModeIndicator() {
        guard let clt = client() else { return }
        var caretRect = NSRect.zero
        _ = clt.attributes(forCharacterIndex: 0, lineHeightRectangle: &caretRect)
        panel.showModeIndicator(mode.rawValue, near: caretRect)
    }

    // MARK: - 辅助方法

    private func clearInput(clt: any IMKTextInput) {
        clt.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
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
        clearInput(clt: clt)
    }

    override func hidePalettes() {
        panel.dismiss()
        super.hidePalettes()
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
        clearInput(clt: clt)
        return true
    }

    private func commitNth(_ idx: Int, clt: any IMKTextInput) -> Bool {
        let cands = engine.candidates(for: currentInput)
        guard let word = cands[safe: idx] else { return false }
        engine.select(word)
        clt.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))
        clearInput(clt: clt)
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
        if cands.isEmpty {
            panel.dismiss()
            return
        }

        var caretRect = NSRect.zero
        _ = clt.attributes(forCharacterIndex: 0, lineHeightRectangle: &caretRect)

        panel.update(candidates: cands, highlighted: selectedIndex) { [weak self] idx in
            guard let self = self, let clt = self.client() else { return }
            let cands = self.engine.candidates(for: self.currentInput)
            guard let word = cands[safe: idx] else { return }
            self.engine.select(word)
            clt.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.clearInput(clt: clt)
        }
        panel.showNear(caretRect)
    }
}

// MARK: - 安全下标

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
