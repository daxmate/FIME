import Cocoa
import InputMethodKit

// MARK: - 输入法控制器

/// FIME 输入法核心控制器
///
/// `FIMEController` 继承自 `IMKInputController`，是 FIME 输入法的核心。
/// 负责处理所有键盘事件、管理输入状态、控制候选窗显示。
///
/// ## 按键映射
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
/// - 不使用 `IMKCandidates` 框架（存在 `selectCandidate` 无法高亮其他候选的 bug）
/// - 使用自定义 `FIMEPanel`（NSPanel）渲染候选列表，支持高亮和鼠标点击
/// - 每次按键通过 `handle(_:client:)` 接收，返回 `true` 表示已消费该事件
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
    /// 关闭候选窗以清理屏幕状态。
    /// - Parameter sender: 停用源（通常为 nil）
    override func deactivateServer(_ sender: Any!) {
        super.deactivateServer(sender)
        panel.dismiss()
        log("deactivateServer")
    }

    // MARK: - 键盘事件处理

    /// 处理键盘按下事件
    ///
    /// 这是输入法的核心方法，所有按键事件都先经过这里。
    /// 返回 `true` 表示事件已被消费，`false` 表示让系统或应用处理。
    ///
    /// 事件处理流程：
    /// 1. 先按 keyCode 检查特殊键（Backspace、方向键、Escape 等）
    /// 2. 再按 characters 检查字符键（字母、空格、数字）
    /// 3. 最后 fallthrough 到 `default: return false`
    ///
    /// - Parameters:
    ///   - event: 键盘事件
    ///   - sender: 文本输入客户端（遵从 `IMKTextInput` 协议）
    /// - Returns: `true` 表示事件已消费，`false` 表示未处理
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let clt = sender as? any IMKTextInput else {
            log("handle: NOT IMKTextInput")
            return false
        }

        // ── Backspace ──────────────────────────────────────────
        // 删除上一个输入的字符。如果 currentInput 变空则隐藏候选窗。
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
        // 在候选列表中移动选中高亮。
        // ↓ 和 → 为下一个，↑ 和 ← 为上一个，边界保护。
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

            // 字母输入：追加到 currentInput，更新候选和 inline 预览
            if firstChar.isLetter {
                currentInput.append(firstChar)
                selectedIndex = 0
                updateMarkedText(clt: clt)
                log("setMarkedText='\(currentInput)'")
                showCandidates(clt: clt)
                return true
            }

            // Space：如果有候选则提交选中候选 + 空格，否则插入空格
            if firstChar == " " {
                if !currentInput.isEmpty {
                    return commitSelected(clt: clt, space: true)
                } else {
                    clt.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
                    log("insertText space")
                }
                return true
            }

            // 1–8：直接选中并提交第 N 个候选（无需先导航再确认）
            if firstChar >= "1" && firstChar <= "8" {
                guard !currentInput.isEmpty else { return false }
                return commitNth(Int(String(firstChar))! - 1, clt: clt)
            }
        }

        // ── 特殊功能键（keyCode 匹配） ─────────────────────────
        switch event.keyCode {
        case 53: // Escape — 清空所有输入，隐藏候选窗
            guard !currentInput.isEmpty else { return false }
            clt.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            currentInput = ""
            selectedIndex = 0
            panel.dismiss()
            log("clear on esc")
            return true

        case 36: // Return — 输出原始输入文本（不选候选，即不接受预测）
            guard !currentInput.isEmpty else { return false }
            clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
            log("commitRaw: '\(currentInput)'")
            currentInput = ""
            selectedIndex = 0
            panel.dismiss()
            return true

        case 48: // Tab — 向下循环候选（到底回到第一个）
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

    /// IMK 框架的 fallback 输入方法
    ///
    /// 当 `handle(_:client:)` 返回 `false` 且系统确定该事件为文本输入时调用。
    /// 一般不会触发，留作安全网。
    ///
    /// - Parameters:
    ///   - string: 输入的文本
    ///   - sender: 文本输入客户端
    /// - Returns: `true` 表示已处理
    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        log("inputText fallback: '\(string ?? "nil")'")
        guard let clt = sender as? any IMKTextInput, let string = string else { return false }
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
    /// 在文本光标处显示 `输入词 ▸ 选中候选` 格式的暂未提交文本，
    /// 让用户在不看候选窗的情况下也能知道当前选中了哪个候选。
    ///
    /// 示例：输入 "pls"，选中第一个候选时显示 `pls ▸ please`
    ///
    /// - Parameter clt: 文本输入客户端
    private func updateMarkedText(clt: any IMKTextInput) {
        let cands = engine.candidates(for: currentInput)
        let display: String
        if let word = cands[safe: selectedIndex] {
            display = "\(currentInput) ▸ \(word)"
        } else {
            display = currentInput
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
