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

    /// Width of the preview area of a tile, used to size captures.
    var previewPointWidth: CGFloat { metrics.cell.width - ItemView.previewInset * 2 }

    // MARK: - Content

    func configure(items: [WindowInfo], maxSize: CGSize, previews: Bool = false) -> CGSize {
        self.items = items
        metrics = Self.metrics(count: items.count, maxSize: maxSize, previews: previews)

        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = items.map { window in
            let view = ItemView()
            view.showsPreviewLayout = previews
            view.configure(with: window)
            if previews { view.preview = WindowPreviews.cached(window.windowID) }
            addSubview(view)
            return view
        }

        frame = NSRect(origin: .zero, size: metrics.size)
        layoutItems()
        updateSelection(previous: nil)
        return metrics.size
    }

    func setPreview(_ image: NSImage, for windowID: CGWindowID, animated: Bool = true) {
        for (index, item) in items.enumerated() where item.windowID == windowID {
            itemViews[index].showPreview(image, animated: animated)
        }
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

    static func metrics(count: Int, maxSize: CGSize, previews: Bool = false) -> Metrics {
        let count = max(count, 1)
        var cell = previews ? CGSize(width: 256, height: 212) : CGSize(width: 152, height: 162)
        let minWidth: CGFloat = previews ? 150 : 96
        let aspect = cell.height / cell.width

        func fit() -> (columns: Int, rows: Int) {
            let available = max(maxSize.width - padding * 2, cell.width)
            let columns = max(1, min(count, Int(available / cell.width)))
            let rows = Int(ceil(Double(count) / Double(columns)))
            return (columns, rows)
        }

        var (columns, rows) = fit()
        while CGFloat(rows) * cell.height + padding * 2 > maxSize.height, cell.width > minWidth {
            cell.width -= 8
            cell.height = (cell.width * aspect).rounded()
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
    static let previewInset: CGFloat = 12

    private let previewView = NSImageView()
    /// Window-shaped stand-in shown until the first capture arrives, so the tile
    /// layout does not jump when the screenshot appears.
    private let placeholderView = NSView()
    private var windowSize: CGSize = .zero
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeView = NSImageView()

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    /// Large tiles with a window thumbnail and a small app icon.
    var showsPreviewLayout = false {
        didSet {
            updatePlaceholderVisibility()
            needsLayout = true
        }
    }

    var preview: NSImage? {
        didSet {
            previewView.image = preview
            previewView.isHidden = preview == nil
            previewView.alphaValue = 1
            updatePlaceholderVisibility()
            needsLayout = true
        }
    }

    /// Sets the thumbnail, fading it in over the placeholder when it is the first one.
    func showPreview(_ image: NSImage, animated: Bool) {
        let isFirst = preview == nil
        preview = image
        guard animated, isFirst, showsPreviewLayout else { return }

        placeholderView.isHidden = false
        layoutSubtreeIfNeeded()
        previewView.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            previewView.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.updatePlaceholderVisibility()
        })
    }

    private func updatePlaceholderVisibility() {
        placeholderView.isHidden = !showsPreviewLayout || preview != nil
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        placeholderView.wantsLayer = true
        placeholderView.layer?.cornerRadius = 6
        placeholderView.layer?.borderWidth = 1
        placeholderView.isHidden = true
        addSubview(placeholderView)

        previewView.imageScaling = .scaleProportionallyDown
        previewView.imageAlignment = .alignCenter
        previewView.isHidden = true
        previewView.wantsLayer = true
        previewView.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            return shadow
        }()
        addSubview(previewView)

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
        windowSize = window.size
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
        showsPreviewLayout ? layoutPreview() : layoutIcon()
    }

    private func layoutIcon() {
        let inset: CGFloat = 8
        let iconSize = min(bounds.width - inset * 4, 72)
        iconView.frame = NSRect(
            x: (bounds.width - iconSize) / 2,
            y: inset + 8,
            width: iconSize,
            height: iconSize
        )
        badgeView.frame = NSRect(x: iconView.frame.maxX - 16, y: iconView.frame.maxY - 16, width: 16, height: 16)
        layoutLabels(below: iconView.frame.maxY + 8)
    }

    private func layoutPreview() {
        let inset = Self.previewInset
        let area = NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: bounds.height - inset - 58)

        // Until a capture exists, use the window's own size (or a typical 16:10 shape)
        // so the placeholder occupies the same frame the screenshot will.
        let fallback = windowSize.width > 1 && windowSize.height > 1 ? windowSize : CGSize(width: 1600, height: 1000)
        let content = preview.flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0.size : nil } ?? fallback
        let fit = min(1, area.width / content.width, area.height / content.height)
        let contentFrame = NSRect(
            x: area.midX - content.width * fit / 2,
            y: area.midY - content.height * fit / 2,
            width: content.width * fit,
            height: content.height * fit
        )
        previewView.frame = contentFrame
        if preview == nil {
            placeholderView.frame = contentFrame
            effectiveAppearance.performAsCurrentDrawingAppearance {
                placeholderView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
                placeholderView.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            }
        }

        let iconSize: CGFloat = 36
        iconView.frame = NSRect(
            x: area.midX - iconSize / 2,
            y: area.maxY - iconSize * 0.6,
            width: iconSize,
            height: iconSize
        )
        badgeView.frame = NSRect(x: iconView.frame.maxX - 12, y: iconView.frame.maxY - 14, width: 16, height: 16)
        layoutLabels(below: area.maxY + 24)
    }

    private func layoutLabels(below y: CGFloat) {
        let inset: CGFloat = 8
        titleLabel.frame = NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: 15)
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
