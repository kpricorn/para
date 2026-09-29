import AppKit

/// Non-activating floating panel that hosts the window grid, so triggering the
/// switcher never steals focus from the app you are switching away from.
final class SwitcherPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SwitcherView: NSView {
    struct Metrics {
        var columns: Int
        var rows: Int
        var cell: CGSize
        var size: CGSize
    }

    private static let padding: CGFloat = 18

    private var items: [WindowInfo] = []
    private var itemViews: [ItemView] = []
    private var metrics = Metrics(columns: 1, rows: 1, cell: .zero, size: .zero)

    var selectedIndex: Int = 0 {
        didSet { updateSelection(previous: oldValue) }
    }

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    // MARK: - Content

    func configure(items: [WindowInfo], maxSize: CGSize) -> CGSize {
        self.items = items
        metrics = Self.metrics(count: items.count, maxSize: maxSize)

        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = items.map { window in
            let view = ItemView()
            view.configure(with: window)
            addSubview(view)
            return view
        }

        frame = NSRect(origin: .zero, size: metrics.size)
        layoutItems()
        updateSelection(previous: nil)
        return metrics.size
    }

    private func layoutItems() {
        for (index, view) in itemViews.enumerated() {
            let column = index % metrics.columns
            let row = index / metrics.columns
            view.frame = NSRect(
                x: Self.padding + CGFloat(column) * metrics.cell.width,
                y: Self.padding + CGFloat(row) * metrics.cell.height,
                width: metrics.cell.width,
                height: metrics.cell.height
            )
        }
    }

    override func layout() {
        super.layout()
        layoutItems()
    }

    private func updateSelection(previous: Int?) {
        if let previous, itemViews.indices.contains(previous) {
            itemViews[previous].isSelected = false
        }
        for (index, view) in itemViews.enumerated() where view.isSelected != (index == selectedIndex) {
            view.isSelected = index == selectedIndex
        }
    }

    static func metrics(count: Int, maxSize: CGSize) -> Metrics {
        let count = max(count, 1)
        var cell = CGSize(width: 152, height: 162)
        let minWidth: CGFloat = 96

        func fit() -> (columns: Int, rows: Int) {
            let available = max(maxSize.width - padding * 2, cell.width)
            let columns = max(1, min(count, Int(available / cell.width)))
            let rows = Int(ceil(Double(count) / Double(columns)))
            return (columns, rows)
        }

        var (columns, rows) = fit()
        while CGFloat(rows) * cell.height + padding * 2 > maxSize.height, cell.width > minWidth {
            cell.width -= 8
            cell.height -= 8.5
            (columns, rows) = fit()
        }

        return Metrics(
            columns: columns,
            rows: rows,
            cell: cell,
            size: CGSize(
                width: CGFloat(columns) * cell.width + padding * 2,
                height: CGFloat(rows) * cell.height + padding * 2
            )
        )
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onHover?(index)
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onClick?(index)
    }

    private func index(at point: NSPoint) -> Int? {
        itemViews.firstIndex { $0.frame.contains(point) }
    }
}

private final class ItemView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeView = NSImageView()

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        badgeView.imageScaling = .scaleProportionallyUpOrDown
        badgeView.contentTintColor = .secondaryLabelColor
        addSubview(badgeView)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 2
        addSubview(subtitleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(with window: WindowInfo) {
        iconView.image = window.icon
        // Every item belongs to the same app, so the window title is what tells them apart.
        titleLabel.stringValue = window.displayTitle
        subtitleLabel.stringValue = window.isOnScreen || window.isMinimized ? "" : "Other Space"
        badgeView.isHidden = !window.isMinimized
        badgeView.image = window.isMinimized
            ? NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Minimized")
            : nil
        toolTip = "\(window.appName) — \(window.displayTitle)"
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let iconSize = min(bounds.width - inset * 4, 72)
        iconView.frame = NSRect(
            x: (bounds.width - iconSize) / 2,
            y: inset + 8,
            width: iconSize,
            height: iconSize
        )
        badgeView.frame = NSRect(x: iconView.frame.maxX - 16, y: iconView.frame.maxY - 16, width: 16, height: 16)
        titleLabel.frame = NSRect(
            x: inset,
            y: iconView.frame.maxY + 8,
            width: bounds.width - inset * 2,
            height: 15
        )
        subtitleLabel.frame = NSRect(
            x: inset,
            y: titleLabel.frame.maxY + 2,
            width: bounds.width - inset * 2,
            height: 28
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
