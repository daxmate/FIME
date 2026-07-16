import Cocoa
import InputMethodKit

@objc(FIMEController)
final class FIMEController: IMKInputController {

    private let engine: WordEngine
    private var currentInput = ""
    private let candidatesWindow: IMKCandidates

    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        let db = WordDatabase()
        self.engine = WordEngine(database: db)
        self.candidatesWindow = IMKCandidates(
            server: server,
            panelType: kIMKSingleColumnScrollingCandidatePanel
        )
        super.init(server: server, delegate: delegate, client: client)
        log("init OK")
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        log("activateServer: client=\(client() != nil)")
    }

    override func deactivateServer(_ sender: Any!) {
        super.deactivateServer(sender)
        log("deactivateServer")
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else {
            return false
        }
        guard let clt = sender as? any IMKTextInput else {
            log("handle: NOT IMKTextInput")
            return false
        }

        if let chars = event.characters, let firstChar = chars.first {
            log("handle: char='\(firstChar)' kc=\(event.keyCode)")

            if firstChar.isLetter {
                currentInput.append(firstChar)
                clt.setMarkedText(
                    currentInput,
                    selectionRange: NSRange(location: currentInput.count, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                log("setMarkedText='\(currentInput)'")
                refreshCandidates()
                return true
            }

            if firstChar == " " {
                if !currentInput.isEmpty {
                    return commitTop(clt: clt, space: true)
                } else {
                    clt.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
                    log("insertText space")
                }
                return true
            }
        }

        switch event.keyCode {
        case 53:
            guard !currentInput.isEmpty else { return false }
            clt.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            currentInput = ""
            candidatesWindow.hide()
            log("clear on esc")
            return true
        case 36, 48:
            guard !currentInput.isEmpty else { return false }
            return commitTop(clt: clt)
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
        refreshCandidates()
        return true
    }

    override func commitComposition(_ sender: Any!) {
        guard let clt = self.client(), !currentInput.isEmpty else { return }
        clt.insertText(currentInput, replacementRange: NSRange(location: NSNotFound, length: 0))
        currentInput = ""
        refreshCandidates()
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        engine.candidates(for: currentInput)
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let clt = self.client() else { return }
        let word = candidateString.string
        log("candidateSelected: '\(word)'")
        engine.select(word)
        clt.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))
        currentInput = ""
        refreshCandidates()
    }

    private func commitTop(clt: any IMKTextInput, space: Bool = false) -> Bool {
        let cands = engine.candidates(for: currentInput)
        let output: String
        if let first = cands.first {
            engine.select(first)
            output = space ? first + " " : first
        } else {
            output = space ? currentInput + " " : currentInput
        }
        clt.insertText(output, replacementRange: NSRange(location: NSNotFound, length: 0))
        log("commitTop: '\(output)'")
        currentInput = ""
        refreshCandidates()
        return true
    }

    private func refreshCandidates() {
        if currentInput.isEmpty {
            candidatesWindow.hide()
        } else {
            candidatesWindow.update()
            candidatesWindow.show()
        }
    }
}
