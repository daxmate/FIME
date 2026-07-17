import Cocoa
import AppKit

// MARK: - 自定义候选窗面板

/// 自定义候选窗面板 — 替代 macOS 内置的 IMKCandidates
///
/// 为什么不用 IMKCandidates？
/// macOS 的 `IMKCandidates` 存在一个已知 bug：
/// 程序化调用 `selectCandidateWithIdentifier:` 时，返回值总是 `true`，
/// 但实际选中的始终是第一个候选（`candidateStringIdentifier:` 总是返回 0）。
/// 因此 FIME 使用自定义 `NSPanel` 来渲染候选列表，实现完整的高亮和点击支持。
///
/// ## 功能
/// - 候选列表显示（带序号，如 "1. please"）
/// - 当前选中的候选以蓝色高亮显示
/// - 鼠标点击选择候选
/// - 自动定位到文本光标附近
/// - 支持最多 8 个候选
///
/// ## 使用方式
/// ```swift
/// let panel = FIMEPanel()
/// panel.update(candidates: ["please", "plans"], highlighted: 0) { idx in
///     print("selected: \(idx)")
/// }
/// panel.showNear(caretRect)
/// ```
final class FIMEPanel: NSPanel {
    /// 每个候选行的高度（像素）
    private let cellHeight: CGFloat = 22

    /// 面板内边距（像素）
    private let cellPadding: CGFloat = 6

    /// 面板可见的最大候选数（超出则滚动）
    private let maxVisible: Int = 8

    /// 当前候选词列表
    private var candidates: [String] = []

    /// 当前高亮的候选索引（从 0 开始）
    private var highlightedIndex: Int = 0

    /// 候选被点击时的回调，参数为被点击的候选索引
    private var onSelect: ((Int) -> Void)?

    // MARK: - 初始化

    /// 创建候选窗面板
    ///
    /// 使用 `nonactivatingPanel` 样式（不会夺走当前应用的焦点），
    /// 背景透明以支持圆角裁剪，窗口层级设为屏蔽层（CGShieldingWindowLevel）
    /// 确保候选窗显示在所有内容之上。
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 公开方法

    /// 显示短暂的模式切换提示
    ///
    /// 当用户通过 Shift 切换输入模式时，在光标附近短暂显示
    /// 当前模式名称（如 `[FIME]` 或 `[ABC]`），800ms 后自动消失。
    ///
    /// - Parameters:
    ///   - name: 模式名称（如 "FIME"、"ABC"）
    ///   - rect: 光标在屏幕坐标下的矩形
    func showModeIndicator(_ name: String, near rect: NSRect) {
        // 创建临时提示视图
        let toastLabel = NSTextField(labelWithString: "[\(name)]")
        toastLabel.font = NSFont.boldSystemFont(ofSize: 15)
        toastLabel.textColor = NSColor.white
        toastLabel.alignment = .center
        toastLabel.sizeToFit()

        let pad: CGFloat = 12
        let tw = toastLabel.frame.width + pad * 2
        let th = toastLabel.frame.height + pad
        let toastRect = NSRect(x: 0, y: 0, width: tw, height: th)

        let toastView = NSView(frame: toastRect)
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 6
        toastView.layer?.masksToBounds = true
        toastView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        toastLabel.frame.origin = NSPoint(x: pad, y: (th - toastLabel.frame.height) / 2)
        toastView.addSubview(toastLabel)

        // 计算位置
        let panelW = tw
        var x = rect.minX
        var y = rect.minY - th - 2
        if y < 0 { y = rect.maxY + 2 }
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            if x + panelW > sf.maxX { x = sf.maxX - panelW }
            if y < sf.minY { y = sf.minY }
        }

        // 创建临时面板
        let toastPanel = NSPanel(
            contentRect: toastRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        toastPanel.level = .init(Int(CGShieldingWindowLevel()))
        toastPanel.hasShadow = true
        toastPanel.backgroundColor = .clear
        toastPanel.isOpaque = false
        toastPanel.titleVisibility = .hidden
        toastPanel.titlebarAppearsTransparent = true
        toastPanel.isMovable = false
        toastPanel.contentView = toastView
        toastPanel.setFrameOrigin(NSPoint(x: x, y: y))
        toastPanel.orderFront(nil)

        // 800ms 后自动关闭
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            toastPanel.orderOut(nil)
        }
    }

    /// 更新候选列表并刷新显示
    ///
    /// 根据候选词数量计算面板尺寸，设置内联视图的候选数据和点击回调。
    /// 如果候选列表为空则自动隐藏面板。
    ///
    /// - Parameters:
    ///   - candidates: 候选词字符串数组
    ///   - highlighted: 当前高亮的索引
    ///   - onSelect: 候选被点击时的回调闭包
    func update(candidates: [String], highlighted: Int, onSelect: @escaping (Int) -> Void) {
        self.candidates = candidates
        self.highlightedIndex = highlighted
        self.onSelect = onSelect

        guard !candidates.isEmpty else {
            dismiss()
            return
        }

        // 计算面板宽度：取最长词的宽度 + 边距
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

    /// 仅更新高亮索引（不改变候选列表）
    ///
    /// 当用户用上下箭头或 Tab 切换候选时调用此方法，
    /// 比 `update(candidates:highlighted:onSelect:)` 更轻量，
    /// 因为它不需要重新计算布局。
    ///
    /// - Parameter index: 新的高亮索引
    func updateHighlight(_ index: Int) {
        highlightedIndex = index
        (contentView as? CandidateView)?.highlightedIndex = index
        contentView?.needsDisplay = true
    }

    /// 在文本光标附近显示候选窗
    ///
    /// 将面板定位到光标矩形下方 2px 处；
    /// 如果下方空间不足则显示在光标上方。
    /// 同时确保面板不超出屏幕可见区域。
    ///
    /// - Parameter rect: 文本光标在屏幕坐标下的矩形
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

    /// 隐藏候选窗
    func dismiss() {
        orderOut(nil)
    }
}

// MARK: - 候选列表视图

/// 候选列表的内联渲染视图
///
/// 使用 CoreGraphics 直接绘制候选列表，支持：
/// - 圆角背景裁剪
/// - 选中行蓝色高亮（使用 `controlAccentColor`）
/// - 行间分隔线
/// - 行号标签（1. 2. 3. ...）
/// - 鼠标点击响应
private final class CandidateView: NSView {
    /// 候选词列表
    var candidates: [String] = []

    /// 当前高亮行索引（从 0 开始）
    var highlightedIndex: Int = 0

    /// 候选被点击时的回调
    var onSelect: ((Int) -> Void)?

    /// 每行高度（像素）
    private let cellHeight: CGFloat = 22

    /// 行内边距（像素）
    private let cellPad: CGFloat = 6

    // MARK: - 绘制

    /// 绘制候选列表
    ///
    /// 绘制流程：
    /// 1. 填充窗口背景色
    /// 2. 用圆角路径裁剪绘制区域
    /// 3. 逐行绘制每个候选：
    ///    - 高亮行：蓝色圆角背景 + 白色文字
    ///    - 普通行：标准文字颜色 + 可选分隔线
    ///
    /// 每行格式：`序号. 单词`，如 `1. please`
    override func draw(_ dirtyRect: NSRect) {
        guard !candidates.isEmpty else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // ── 背景填充 ──
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(bounds)

        // ── 圆角裁剪 ──
        let path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                          cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.clip()

        // ── 逐行绘制 ──
        for (i, word) in candidates.enumerated() {
            let y = bounds.height - CGFloat(i + 1) * cellHeight
            let cellRect = NSRect(x: cellPad, y: y, width: bounds.width - cellPad * 2, height: cellHeight)

            if i == highlightedIndex {
                // 高亮行：蓝色圆角背景 + 白色文字
                let hlRect = NSRect(x: 2, y: y + 1, width: bounds.width - 4, height: cellHeight - 2)
                let hlPath = CGPath(roundedRect: hlRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                ctx.addPath(hlPath)
                ctx.fillPath()

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.white,
                ]
                let full = "\(i + 1). \(word)"
                (full as NSString).draw(at: NSPoint(x: cellRect.minX + 4, y: cellRect.minY + 3),
                                        withAttributes: attrs)
            } else {
                // 普通行：标准颜色
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                ]
                let full = "\(i + 1). \(word)"
                (full as NSString).draw(at: NSPoint(x: cellRect.minX + 4, y: cellRect.minY + 3),
                                        withAttributes: attrs)

                // 候选之间的分隔线
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

    // MARK: - 鼠标事件

    /// 处理鼠标点击事件
    ///
    /// 将点击坐标映射到候选行索引，如果点击在有效行范围内则触发回调。
    ///
    /// - Parameter event: 鼠标按下事件
    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let y = bounds.height - loc.y
        let idx = Int(y / cellHeight)
        if idx >= 0 && idx < candidates.count {
            onSelect?(idx)
        }
    }
}
