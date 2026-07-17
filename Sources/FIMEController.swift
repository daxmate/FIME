import Cocoa
import InputMethodKit

// MARK: - 输入模式

/// FIME 输入模式
///
/// - `raw`: 原始输出模式
///   - 所有按键直接透传到当前应用，不做任何处理
///   - 表现同系统默认英文输入法
///   - 按 Shift 可在任意时刻切到 fuzzy 模式
///
/// - `fuzzy`: 模糊预测模式
///   - 捕获字母输入进行子序列匹配
///   - 显示候选词面板，支持导航和选择
///   - 按 Shift 可切回 raw 模式
enum InputMode: String {
    /// 原始输出模式 — 透传所有按键，如同系统英文输入法
    case raw = "ABC"
    /// 模糊预测模式 — 捕获字母输入，显示候选词
    case fuzzy = "FIME"
}

// MARK: - 输入法控制器

/// FIME 输入法核心控制器
///
/// `FIMEController` 继承自 `IMKInputController`，是 FIME 输入法的核心。
/// 支持两种模式：
/// - **raw（原始输出）**：透传所有按键，行为同系统英文输入法
/// - **fuzzy（模糊预测）**：捕获字母输入进行子序列匹配
///
/// ## 模式切换
/// 快速按一次 **Shift**（左/右均可）切换模式。
///
/// 检测原理：通过 `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)`
/// 监听 modifier 键事件，追踪 Shift 的按下和释放时序。
/// 如果 Shift 在 30ms–500ms 内被按下+释放（期间没有其他按键），
/// 则判定为模式切换动作。
///
/// ## 按键映射（fuzzy 模式）
/// | 按键 | 行为 |
/// |------|------|
/// | `a`–`z` | 输入字母，触发子序列匹配和候选更新 |
/// | `Backspace` | 删除上一个输入的字符 |
/// | `↑` `↓` `←` `→` | 在上/下一个候选之间切换 |
/// | `Tab` | 向下循环候选（到底回到第一个） |
/// | `Space` | 提交当前选中的候选 + 空格 |
/// | `Enter` | 输出原文（不选候选） |
/// | `1`–`8` | 直接选中并提交第 N 个候选 |
/// | `Escape` | 清空所有输入 |
///
/// ## 设计说明
/// - 不使用 `IMKCandidates` 框架（`selectCandidateWithIdentifier:` 存在 bug）
/// - 使用自定义 `FIMEPanel`（NSPanel）渲染候选列表
/// - raw 模式下所有事件通过返回 `false` 透传，系统继续正常分发
/// - Shift 检测通过 flagsChanged 事件监听器而非 `handle(_:client:)`
@objc(FIMEController)
final class FIMEController: IMKInputController {

    // MARK: - 属性

    /// 预测引擎，提供候选词查询和选择频率记录
    private let engine: WordEngine

    /// 用户当前输入的字母串（未提交的 raw input）
    private var currentInput = ""

    /// 当前在候选列表中选中的索引（从 0 开始）
    private var selectedIndex = 0

    /// 自定义候选窗面板
    private let panel: FIMEPanel

    /// 当前输入模式，默认为 raw（原始输出）
    private var mode: InputMode = .raw {
        didSet {
            log("mode: \(mode.rawValue)")
        }
    }

    /// ⏱ Shift 键按下的时间点
    ///
    /// 由 flagsChanged 监听器在 Shift keyDown 时记录。
    /// 在 Shift keyUp 时比较时间差，判断是「短按切换」还是「长按修饰」。
    private var shiftDownAt: TimeInterval = 0

    /// 当前是否处于 Shift 按下状态
    ///
    /// 用于边缘检测：从 true→false 时触发 toggle 判定
    private var shiftIsDown = false

    /// flagsChanged 事件监听器
    ///
    /// `handle(_:client:)` 收不到 modifier 键事件，
    /// 必须通过 NSEvent 的 local monitor 来监听 flagsChanged。
    private var flagsMonitor: Any?

    /// 记录当前模式对应的 marked text 前缀，用于 inline 指示器
    private var modeIndicator: String {
        "[\(mode.rawValue)]"
    }

    // MARK: - 初始化与生命周期

    /// 初始化输入法控制器
    ///
    /// 创建依赖链并启动 flagsChanged 事件监听。
    ///
    /// - Parameters:
    ///   - server: IMK 服务器实例
    ///   - delegate: 委托对象（通常为 nil）
    ///   - client: 初始客户端（文本输入对象）
    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        let db = WordDatabase()
        self.engine = WordEngine(database: db)
        self.panel = FIMEPanel()
        super.init(server: server, delegate: delegate, client: client)
        setupFlagsMonitor()
        log("init OK")
    }

    /// 设置 flagsChanged 事件监听器
    ///
    /// modifier 键事件（Shift/Ctrl/Option/Command）不以 keyDown 形式
    /// 到达 `handle(_:client:)`，需要通过 NSEvent 的 local monitor
    /// 在当前进程的事件流中捕获 `.flagsChanged` 事件。
    ///
    /// 监听器只跟踪 Shift 的按下和释放状态，不影响事件传递。
    private func setupFlagsMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleFlagsChanged(event)
            return event // ⚠️ 必须返回 event，否则 modifier 键会"卡住"
        }
        log("flagsMonitor: installed")
    }

    /// 处理 flagsChanged 事件（Shift 键按下/释放）
    ///
    /// 边缘检测 Shift 状态变化：
    /// - `shiftIsDown` 从 false→true：记录按下时间
    /// - `shiftIsDown` 从 true→false：如果按下的持续时间在 [30ms, 500ms]
    ///   范围内，且 FIME 当前是活跃输入法（client() != nil），则切换模式。
    ///
    /// 长按 Shift（>500ms）视为修饰键操作（如大写输入），不触发切换。
    ///
    /// - Parameter event: flagsChanged 事件
    private func handleFlagsChanged(_ event: NSEvent) {
        let nowShiftIsDown = event.modifierFlags.contains(.shift)

        if nowShiftIsDown && !shiftIsDown {
            // Shift 被按下
            shiftDownAt = CACurrentMediaTime()
        } else if !nowShiftIsDown && shiftIsDown, shiftDownAt > 0 {
            // Shift 被释放 — 检查是否是短按切换
            guard client() != nil else {
                // FIME 不是当前活跃输入法，忽略
                shiftDownAt = 0
                shiftIsDown = false
                return
            }
            let elapsed = CACurrentMediaTime() - shiftDownAt
            if elapsed >= 0.03 && elapsed <= 0.5 {
                // 30ms ~ 500ms 内的快速按+放 → 模式切换
                toggleMode()
                log("shift toggle: \(Int(elapsed * 1000))ms")
            } else {
                log("shift ignored: \(Int(elapsed * 1000))ms (not a quick tap)")
            }
            shiftDownAt = 0
        }

        shiftIsDown = nowShiftIsDown
    }

    /// 输入法被激活（用户切换到 FIME 时调用）
    ///
    /// 此时 `client()` 方法可用，可以获取客户端的 bundle identifier 等信息。
    /// - Parameter sender: 激活源（通常为 nil）
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        log("activateServer: client=\(client() != nil)")
    }

    /// 输入法被停用（用户切换到其他输入法时调用）
    ///
    /// 关闭候选窗，清空输入状态以清理屏幕。
    /// - Parameter sender: 停用源（通常为 nil）
    override func deactivateServer(_ sender: Any!) {
        super.deactivateServer(sender)
        currentInput = ""
        selectedIndex = 0
        shiftDownAt = 0
        panel.dismiss()
        log("deactivateServer")
    }

    // MARK: - 键盘事件处理

    /// 处理键盘按下事件
    ///
    /// 这是输入法的核心方法。处理流程：
    /// 1. 根据当前模式分派到 `handleRawMode` 或 `handleFuzzyMode`
    ///
    /// 注意：modifier 键事件（Shift 等）不会到达此方法，
    /// 它们在 `setupFlagsMonitor` 中单独处理。
    ///
    /// - Parameters:
    ///   - event: 键盘事件
    ///   - sender: 文本输入客户端（遵从 `IMKTextInput` 协议）
    /// - Returns: `true` 表示事件已消费，`false` 表示未处理（让系统继续分发）
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let clt = sender as? any IMKTextInput else {
            log("handle: NOT IMKTextInput")
            return false
        }

        // 按当前模式分派
        switch mode {
        case .raw:
            return handleRawMode(event: event, clt: clt)
        case .fuzzy:
            return handleFuzzyMode(event: event, clt: clt)
        }
    }

    // MARK: - Raw Mode

    /// 处理原始输出模式下的按键事件
    ///
    /// 在 raw 模式下，FIME 不拦截任何按键，所有事件透传给应用。
    ///
    /// - Parameters:
    ///   - event: 键盘事件
    ///   - clt: 文本输入客户端
    /// - Returns: 始终返回 `false`，让事件继续传递给应用
    private func handleRawMode(event: NSEvent, clt: any IMKTextInput) -> Bool {
        // 安全网：如果 fuzzy 模式留下了未提交的输入，强制提交
        if !currentInput.isEmpty {
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
            currentInput = ""
            selectedIndex = 0
            panel.dismiss()
        }
        // 所有按键透传
        return false
    }

    // MARK: - Fuzzy Mode

    /// 处理模糊预测模式下的按键事件
    ///
    /// 捕获字母输入，使用子序列匹配算法从词库中查找候选词，
    /// 显示候选窗供用户选择。
    ///
    /// - Parameters:
    ///   - event: 键盘事件
    ///   - clt: 文本输入客户端
    /// - Returns: `true` 表示事件已消费
    private func handleFuzzyMode(event: NSEvent, clt: any IMKTextInput) -> Bool {
        // ── Backspace ──────────────────────────────────────────
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
            log("backspace: input='\(currentInput)'")
            return true
        }

        // ── 方向键：↑ ↓ ← → ─────────────────────────────────
        if [123, 124, 125, 126].contains(event.keyCode) {
            guard !currentInput.isEmpty else { return false }
            let cands = engine.candidates(for: currentInput)
            guard !cands.isEmpty else { return false }

            if event.keyCode == 125 || event.keyCode == 124 { // Down / Right → 下一个
                selectedIndex = min(selectedIndex + 1, cands.count - 1)
            } else { // Up / Left → 上一个
                selectedIndex = max(selectedIndex - 1, 0)
            }

            panel.updateHighlight(selectedIndex)
            updateMarkedText(clt: clt)
            log("arrow: idx=\(selectedIndex) word='\(cands[selectedIndex])'")
            return true
        }

        // ── 含字符的按键（字母、空格、数字） ──────────────────
        if let chars = event.characters, let firstChar = chars.first {
            log("handle: char='\(firstChar)' kc=\(event.keyCode)")

            // 字母输入：追加到 currentInput
            if firstChar.isLetter {
                currentInput.append(firstChar.lowercased())
                selectedIndex = 0
                updateMarkedText(clt: clt)
                log("setMarkedText='\(currentInput)'")
                showCandidates(clt: clt)
                return true
            }

            // Space：提交选中候选 + 空格
            if firstChar == " " {
                if !currentInput.isEmpty {
                    return commitSelected(clt: clt, space: true)
                } else {
                    clt.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
                    log("insertText space")
                }
                return true
            }

            // 1–8：直接选中并提交第 N 个候选
            if firstChar >= "1" && firstChar <= "8" {
                guard !currentInput.isEmpty else { return false }
                return commitNth(Int(String(firstChar))! - 1, clt: clt)
            }
        }

        // ── 特殊功能键 ─────────────────────────────────────────
        switch event.keyCode {
        case 53: // Escape — 清空所有输入
            guard !currentInput.isEmpty else { return false }
            clt.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            currentInput = ""
            selectedIndex = 0
            panel.dismiss()
            log("clear on esc")
            return true

        case 36: // Return — 输出原文
            guard !currentInput.isEmpty else { return false }
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
            log("commitRaw: '\(currentInput)'")
            currentInput = ""
            selectedIndex = 0
            panel.dismiss()
            return true

        case 48: // Tab — 向下循环候选
            guard !currentInput.isEmpty else { return false }
            let cands = engine.candidates(for: currentInput)
            guard !cands.isEmpty else { return false }
            selectedIndex = (selectedIndex + 1) % cands.count
            panel.updateHighlight(selectedIndex)
            updateMarkedText(clt: clt)
            log("tab: idx=\(selectedIndex) word='\(cands[selectedIndex])'")
            return true

        default:
            return false
        }
    }

    // MARK: - 模式切换

    /// 切换输入模式（raw ↔ fuzzy）
    ///
    /// 切换时自动提交未完成的输入、隐藏候选窗。
    private func toggleMode() {
        // 清理当前状态：提交未完成的输入
        if !currentInput.isEmpty, let clt = client() {
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        currentInput = ""
        selectedIndex = 0
        panel.dismiss()

        // 切换模式
        mode = mode == .raw ? .fuzzy : .raw
    }

    /// IMK 框架的 fallback 输入方法
    ///
    /// 当 `handle(_:client:)` 返回 `false` 且系统确定该事件为文本输入时调用。
    /// 仅在 raw 模式下可能触发，留作安全网。
    ///
    /// - Parameters:
    ///   - string: 输入的文本
    ///   - sender: 文本输入客户端
    /// - Returns: `true` 表示已处理
    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        log("inputText fallback: '\(string ?? "nil")'")
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

    /// 提交当前组合输入（系统要求时调用）
    ///
    /// 当输入法失去焦点或切换应用时，系统调用此方法
    /// 要求输入法提交当前正在编辑的文本。
    ///
    /// - Parameter sender: 提交源
    override func commitComposition(_ sender: Any!) {
        guard let clt = self.client(), !currentInput.isEmpty else { return }
        clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
        currentInput = ""
        selectedIndex = 0
        panel.dismiss()
    }

    /// 隐藏所有浮动面板
    ///
    /// 输入法停用前由系统调用，确保自定义面板被关闭。
    override func hidePalettes() {
        panel.dismiss()
        super.hidePalettes()
    }

    // MARK: - 提交方法

    /// 提交当前选中的候选词
    ///
    /// 从 `engine.candidates(for: currentInput)` 中取 `selectedIndex` 对应的词，
    /// 记录选择频率后提交到客户端。
    /// 如果 `space` 为 true，则在词后加一个空格。
    ///
    /// - Parameters:
    ///   - clt: 文本输入客户端
    ///   - space: 是否在词后追加空格
    /// - Returns: 始终返回 `true`
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
        log("commitSelected: '\(output)'")
        currentInput = ""
        selectedIndex = 0
        panel.dismiss()
        return true
    }

    /// 提交第 N 个候选（数字键 1–8 直接选择）
    ///
    /// 不经过当前选中索引，直接从候选列表中取第 `idx` 个提交。
    ///
    /// - Parameters:
    ///   - idx: 候选索引（0–7，对应按键 1–8）
    ///   - clt: 文本输入客户端
    /// - Returns: 如果索引有效返回 `true`，否则返回 `false`
    private func commitNth(_ idx: Int, clt: any IMKTextInput) -> Bool {
        let cands = engine.candidates(for: currentInput)
        guard let word = cands[safe: idx] else { return false }
        engine.select(word)
        clt.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))
        log("commitNth[\(idx)]: '\(word)'")
        currentInput = ""
        selectedIndex = 0
        panel.dismiss()
        return true
    }

    // MARK: - 显示方法

    /// 更新 inline 预览文本
    ///
    /// 在文本光标处显示带模式指示器的暂未提交文本：
    /// `[FIME] 输入词 ▸ 选中候选`
    ///
    /// 如果当前没有候选，只显示 `[FIME] 输入词`。
    ///
    /// - Parameter clt: 文本输入客户端
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

    /// 在光标附近显示候选窗
    ///
    /// 查询 `IMKTextInput` 的 `attributes(forCharacterIndex:lineHeightRectangle:)`
    /// 获取光标屏幕位置，然后调用 `FIMEPanel.showNear(_:)` 定位面板。
    /// 同时设置候选点击回调。
    ///
    /// - Parameter clt: 文本输入客户端
    private func showCandidates(clt: any IMKTextInput) {
        let cands = engine.candidates(for: currentInput)
        if cands.isEmpty {
            panel.dismiss()
            return
        }

        // 获取光标在屏幕上的位置矩形
        var caretRect = NSRect.zero
        _ = clt.attributes(forCharacterIndex: 0, lineHeightRectangle: &caretRect)

        // 更新面板并设置点击回调
        panel.update(candidates: cands, highlighted: selectedIndex) { [weak self] idx in
            guard let self = self, let clt = self.client() else { return }
            let cands = self.engine.candidates(for: self.currentInput)
            guard let word = cands[safe: idx] else { return }
            self.engine.select(word)
            clt.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.currentInput = ""
            self.selectedIndex = 0
            self.panel.dismiss()
            log("panelClick: '\(word)'")
        }
        panel.showNear(caretRect)
    }
}

// MARK: - 安全下标扩展

extension Array {
    /// 安全的下标访问，越界时返回 nil 而非崩溃
    /// - Parameter index: 索引
    /// - Returns: 元素（如果索引有效）或 nil
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
