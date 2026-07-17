import Cocoa
import AppKit

/// 自定义候选窗面板 — 替代有 bug 的 IMKCandidates
final class FIMEPanel: NSPanel {
    private let cellHeight: CGFloat = 22
    private let cellPadding: CGFloat = 6
    private let maxVisible: Int = 8

    private var candidates: [String] = []
    private var highlightedIndex: Int = 0
    private var onSelect: ((Int) -> Void)?

    /// 初始化
    init() {
        let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        super.init(contentRect: frame, styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        level = .init(Int(CGShieldingWindowLevel()))
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        ignoresMouseEvents = false
        contentView = CandidateView(frame: frame)
    }

    /// 更新候选列表和高亮
    func update(candidates: [String], highlighted: Int, onSelect: @escaping (Int) -> Void) {
        self.candidates = candidates
        self.highlightedIndex = highlighted
        self.onSelect = onSelect

        guard !candidates.isEmpty else {
            dismiss()
            return
        }

        // 计算尺寸
        let maxW: CGFloat = candidates.reduce(50) { max($0, CGFloat($1.count) * 9 + 30) }
        let viewH = min(CGFloat(candidates.count), CGFloat(maxVisible)) * cellHeight + cellPadding * 2
        let viewW = maxW + cellPadding * 2 + 6

        let viewRect = NSRect(x: 0, y: 0, width: viewW, height: viewH)
        setFrame(NSRect(origin: frame.origin, size: viewRect.size), display: false)

        if let cv = contentView as? CandidateView {
            cv.frame = viewRect
            cv.candidates = candidates
            cv.highlightedIndex = highlighted
            cv.onSelect = { [weak self] idx in
                self?.onSelect?(idx)
            }
            cv.needsDisplay = true
        }
    }

    /// 仅更新高亮（不改变候选列表）
    func updateHighlight(_ index: Int) {
        highlightedIndex = index
        (contentView as? CandidateView)?.highlightedIndex = index
        contentView?.needsDisplay = true
    }

    /// 在光标附近显示
    func showNear(_ rect: NSRect) {
        guard let cv = contentView as? CandidateView, !cv.candidates.isEmpty else { return }
        let panelH = cv.frame.height
        let panelW = cv.frame.width
        var x = rect.minX
        var y = rect.minY - panelH - 2
        if y < 0 {
            y = rect.maxY + 2
        }
        // 确保不超出屏幕
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            if x + panelW > sf.maxX { x = sf.maxX - panelW }
            if y < sf.minY { y = sf.minY }
        }
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
    }
}

// MARK: - 候选列表视图

private final class CandidateView: NSView {
    var candidates: [String] = []
    var highlightedIndex: Int = 0
    var onSelect: ((Int) -> Void)?
    private let cellHeight: CGFloat = 22
    private let cellPad: CGFloat = 6

    override func draw(_ dirtyRect: NSRect) {
        guard !candidates.isEmpty else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 背景
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(bounds)

        // 圆角裁剪
        let path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                          cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.clip()

        for (i, word) in candidates.enumerated() {
            let y = bounds.height - CGFloat(i + 1) * cellHeight
            let cellRect = NSRect(x: cellPad, y: y, width: bounds.width - cellPad * 2, height: cellHeight)

            if i == highlightedIndex {
                // 高亮行
                let hlRect = NSRect(x: 2, y: y + 1, width: bounds.width - 4, height: cellHeight - 2)
                let hlPath = CGPath(roundedRect: hlRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                ctx.addPath(hlPath)
                ctx.fillPath()

                // 白色文字
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.white,
                ]
                let label = "\(i + 1). "
                let full = label + word
                (full as NSString).draw(at: NSPoint(x: cellRect.minX + 4, y: cellRect.minY + 3),
                                        withAttributes: attrs)
            } else {
                // 普通行
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                ]
                let label = "\(i + 1). "
                let full = label + word
                (full as NSString).draw(at: NSPoint(x: cellRect.minX + 4, y: cellRect.minY + 3),
                                        withAttributes: attrs)

                // 可选：分隔线
                if i < candidates.count - 1 {
                    ctx.setStrokeColor(NSColor.separatorColor.cgColor)
                    ctx.setLineWidth(0.5)
                    ctx.move(to: NSPoint(x: cellPad + 4, y: cellRect.minY))
                    ctx.addLine(to: NSPoint(x: bounds.width - cellPad - 4, y: cellRect.minY))
                    ctx.strokePath()
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let y = bounds.height - loc.y
        let idx = Int(y / cellHeight)
        if idx >= 0 && idx < candidates.count {
            onSelect?(idx)
        }
    }
}
