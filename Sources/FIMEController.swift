import Cocoa
import InputMethodKit

@objc(FIMEController)
final class FIMEController: IMKInputController {

    private let engine: WordEngine
    private var currentInput = ""
    private var selectedIndex = 0
    private let panel: FIMEPanel

    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        let db = WordDatabase()
        self.engine = WordEngine(database: db)
        self.panel = FIMEPanel()
        super.init(server: server, delegate: delegate, client: client)
        log("init OK")
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        log("activateServer: client=\(client() != nil)")
    }

    override func deactivateServer(_ sender: Any!) {
        super.deactivateServer(sender)
        panel.dismiss()
        log("deactivateServer")
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let clt = sender as? any IMKTextInput else {
            log("handle: NOT IMKTextInput")
            return false
        }

        // ── Backspace ── 删除上一个字符
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

        // ── Up / Down / Left / Right ── 在候选词之间导航
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

        if let chars = event.characters, let firstChar = chars.first {
            log("handle: char='\(firstChar)' kc=\(event.keyCode)")

            // 字母输入
            if firstChar.isLetter {
                currentInput.append(firstChar)
                selectedIndex = 0
                updateMarkedText(clt: clt)
                log("setMarkedText='\(currentInput)'")
                showCandidates(clt: clt)
                return true
            }

            // Space — 提交选中候选 + 空格
            if firstChar == " " {
                if !currentInput.isEmpty {
                    return commitSelected(clt: clt, space: true)
                } else {
                    clt.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
                    log("insertText space")
                }
                return true
            }

            // 1–8 — 直接选中并提交第 N 个候选
            if firstChar >= "1" && firstChar <= "8" {
                guard !currentInput.isEmpty else { return false }
                return commitNth(Int(String(firstChar))! - 1, clt: clt)
            }
        }

        switch event.keyCode {
        case 53: // Escape
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

    override func commitComposition(_ sender: Any!) {
        guard let clt = self.client(), !currentInput.isEmpty else { return }
        clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
        currentInput = ""
        selectedIndex = 0
        panel.dismiss()
    }

    override func hidePalettes() {
        panel.dismiss()
        super.hidePalettes()
    }

    // MARK: - 提交

    /// 提交 `selectedIndex` 对应的候选词（仅 Space 用）
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

    /// 提交第 N 个候选
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

    // MARK: - 显示

    /// inline 显示 `输入词 ▸ 当前选中`
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
    private func showCandidates(clt: any IMKTextInput) {
        let cands = engine.candidates(for: currentInput)
        if cands.isEmpty {
            panel.dismiss()
            return
        }

        // 获取光标位置
        var caretRect = NSRect.zero
        _ = clt.attributes(forCharacterIndex: 0, lineHeightRectangle: &caretRect)

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

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
