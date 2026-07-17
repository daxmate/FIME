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
/// 按 **Shift**（左/右均可）切换模式。检测逻辑：
/// 1. 记录 Shift 按下的时间戳
/// 2. 如果下一个按键事件不带 Shift 修饰符 → Shift 已被释放 → 切换模式
/// 3. 如果下一个按键事件带有 Shift 修饰符 → 用户是在输入大写字母，不切换
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

    /// Shift 键按下的时间戳
    ///
    /// 用于判断 Shift 是作为修饰键（大写字母）还是作为模式切换。
    /// 非零值表示 Shift 被按下但还未确定用途。
    /// 收到下一个非-Shift 按键时根据修饰符状态决定是否切换。
    private var shiftDownAt: TimeInterval = 0

    /// 记录当前模式对应的 marked text 前缀，用于 inline 指示器
    private var modeIndicator: String {
        "[" + mode.rawValue + "]"
    }

    // MARK: - 初始化与生命周期

    /// 初始化输入法控制器
    ///
    /// 创建 `WordDatabase` → `WordEngine` → `FIMEPanel` 的依赖链。
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
        log("init OK")
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
    /// 1. 检测 Shift 键按下，记录时间戳（用于后续判断是否切换模式）
    /// 2. 检查 Shift 释放后的模式切换条件
    /// 3. 根据当前模式分派到 `handleRawMode` 或 `handleFuzzyMode`
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

        // ── 第一步：检测 Shift 键按下 ────────────────────────
        // keyCode 56 = 左 Shift, 60 = 右 Shift
        // 记录时间但不消费事件（return false），让 Shift 修饰符状态正确传递给应用
        if event.keyCode == 56 || event.keyCode == 60 {
            shiftDownAt = event.timestamp
            return false
        }

        // ── 第二步：检查是否需要切换模式 ──────────────────────
        // 如果 Shift 刚被按下过（shiftDownAt > 0），说明刚才的 Shift 事件已经传递给了应用。
        // 现在收到了一个非 Shift 的按键，可以判断 Shift 的用途：
        if shiftDownAt > 0 {
            let gap = event.timestamp - shiftDownAt
            if event.modifierFlags.contains(.shift) {
                // Shift 仍然被按住 → 用户是在用 Shift 输入大写字母
                // 不是模式切换，清除标记即可
                shiftDownAt = 0
            } else if gap > 0.05 {
                // Shift 已被释放（当前按键没有 Shift 修饰符）
                // 且到 Shift 按下至少过了 50ms（防抖）
                // → 用户是单独按了 Shift（快速按下+释放）→ 切换模式！
                log("Shift toggle after \(gap * 1000)ms gap")
                toggleMode()
                shiftDownAt = 0
                // Shift 事件已透传，但切换模式后，当前按键需要按新模式处理
                // 继续往下走，不要 return
            } else {
                // 间隙太短，可能是按键抖动，忽略切换
                shiftDownAt = 0
            }
        }

        // ── 第三步：按当前模式分派 ──────────────────────────
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
    /// 唯一返回 `true` 的情况是当 fuzzy 模式有未提交的输入时，
    /// 需要先清空（通过 `commitComposition` 提交）再切换。
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
                currentInput.append(firstChar)
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
    /// 切换时自动清理未提交的输入，隐藏候选窗，
    /// 并通过 marked text 显示模式指示器。
    private func toggleMode() {
        // 清理当前状态
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
                currentInput.append(char)
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
