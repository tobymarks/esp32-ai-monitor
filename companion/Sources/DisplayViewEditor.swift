/**
 * Native counterpart of the Windows ViewManager: select a window, then assign
 * a source by clicking a palette button or dropping it on a tile/the preview.
 * Editing selection is deliberately independent of the window on the ESP.
 */
import Cocoa

struct DisplayViewEditorItem: Equatable {
    let content: String
    let title: String
    let glyph: String
    let symbol: String
}

final class DisplayViewEditor: NSView {
    var onAssign: ((Int, String) -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: ((Int) -> Void)?
    var onShow: ((Int) -> Void)?

    private(set) var selectedIndex = 0
    private var contents: [String] = []
    private var items: [DisplayViewEditorItem] = []
    private var activeIndex = 0
    private var mode = "manual"
    private let grid = DisplayViewEditorGrid(frame: .zero)
    private let palette = NSStackView()
    private let preview = DisplayViewDropSurface()
    private let editTitle = NSTextField(labelWithString: "")
    private let previewGlyph = NSTextField(labelWithString: "")
    private let previewTitle = NSTextField(wrappingLabelWithString: "")
    private let previewDetail = NSTextField(labelWithString: "")
    private let showButton = NSButton()
    private let addButton = NSButton()
    private var tiles: [DisplayViewTile] = []
    private var statusLabels: [NSTextField] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        addButton.title = L("views.add")
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addWindow)
        showButton.title = L("views.show")
        showButton.bezelStyle = .rounded
        showButton.target = self
        showButton.action = #selector(showWindow)

        editTitle.font = NSFont.appFont(.headline)
        editTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewGlyph.font = NSFont.appFont(.largeTitle)
        previewGlyph.textColor = .controlAccentColor
        previewTitle.font = NSFont.appFont(.title2, weight: .semibold)
        previewTitle.alignment = .center
        previewDetail.font = NSFont.appFont(.subheadline)
        previewDetail.textColor = .secondaryLabelColor
        let previewContent = NSStackView(views: [previewGlyph, previewTitle, previewDetail])
        previewContent.orientation = .vertical
        previewContent.alignment = .centerX
        previewContent.spacing = 10
        previewContent.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(previewContent)
        NSLayoutConstraint.activate([
            preview.heightAnchor.constraint(equalToConstant: 180),
            previewContent.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            previewContent.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            previewContent.widthAnchor.constraint(equalTo: preview.widthAnchor, constant: -32),
            previewTitle.widthAnchor.constraint(equalTo: previewContent.widthAnchor),
        ])
        configureDrop(preview)

        let editHeading = NSStackView(views: [editTitle, showButton])
        editHeading.orientation = .horizontal
        editHeading.alignment = .centerY
        editHeading.spacing = 12
        let dropHint = hint("views.drop.hint")
        let workspace = verticalStack([grid, addButton, editHeading, preview, dropHint], spacing: 12)
        let workspacePanel = panel(workspace)
        NSLayoutConstraint.activate([
            grid.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            dropHint.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            preview.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            workspacePanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])

        let paletteTitle = NSTextField(labelWithString: L("views.blocks"))
        paletteTitle.font = NSFont.appFont(.headline)
        palette.orientation = .vertical
        palette.alignment = .leading
        palette.spacing = 6
        let paletteHint = hint("views.blocks.hint")
        let paletteContent = verticalStack([paletteTitle, paletteHint, palette], spacing: 10)
        let palettePanel = panel(paletteContent)
        palettePanel.widthAnchor.constraint(equalToConstant: 210).isActive = true
        palette.widthAnchor.constraint(equalTo: paletteContent.widthAnchor).isActive = true
        paletteHint.widthAnchor.constraint(equalTo: paletteContent.widthAnchor).isActive = true

        let layout = NSStackView(views: [workspacePanel, palettePanel])
        layout.orientation = .horizontal
        layout.alignment = .top
        layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(contents: [String], items: [DisplayViewEditorItem], active: Int, mode: String) {
        let changed = self.contents != contents || self.items != items
        let paletteChanged = self.items != items
        self.contents = contents
        self.items = items
        activeIndex = active
        self.mode = mode
        selectedIndex = min(selectedIndex, max(0, contents.count - 1))
        if changed { rebuildTiles() }
        if paletteChanged { rebuildPalette() }
        addButton.isEnabled = contents.count < Settings.maxDisplayViews
        refreshSelection()
    }

    func selectWindow(_ index: Int) {
        guard contents.indices.contains(index) else { return }
        let moveFocus = (window?.firstResponder as? NSView)?.isDescendant(of: grid) == true
        selectedIndex = index
        refreshSelection()
        if moveFocus, tiles.indices.contains(index) { window?.makeFirstResponder(tiles[index]) }
    }

    private func item(for content: String) -> DisplayViewEditorItem {
        items.first { $0.content == content }
            ?? DisplayViewEditorItem(content: content, title: content, glyph: "◇", symbol: "puzzlepiece.extension")
    }

    private func rebuildTiles() {
        let restoreFocus = (window?.firstResponder as? NSView)?.isDescendant(of: grid) == true
        tiles.removeAll()
        statusLabels.removeAll()
        var cards: [NSView] = []
        for (index, content) in contents.enumerated() {
            let item = item(for: content)
            let tile = DisplayViewTile(title: item.title, glyph: item.glyph)
            tile.tag = index
            tile.target = self
            tile.action = #selector(selectTile(_:))
            tile.setAccessibilityLabel("\(L("views.window", index + 1)): \(item.title)")
            tile.setAccessibilityHelp(L("views.select.hint"))
            tile.heightAnchor.constraint(equalToConstant: 88).isActive = true
            tile.acceptContent = { [weak self] content in self?.canAssign(content) ?? false }
            tile.onDrop = { [weak self] content in self?.onAssign?(index, content) }
            tiles.append(tile)

            let caption = NSTextField(labelWithString: L("views.window", index + 1))
            caption.font = NSFont.appFont(.subheadline)
            let status = NSTextField(labelWithString: "")
            status.font = NSFont.appFont(.caption1)
            status.textColor = .secondaryLabelColor
            statusLabels.append(status)
            var footer: [NSView] = [status]
            if index > 0 {
                let remove = NSButton(title: L("views.remove"), target: self, action: #selector(removeWindow(_:)))
                if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) {
                    remove.image = image
                    remove.imagePosition = .imageOnly
                }
                remove.bezelStyle = .inline
                remove.controlSize = .small
                remove.tag = index
                remove.toolTip = L("views.remove.a11y", index + 1)
                remove.setAccessibilityLabel(L("views.remove.a11y", index + 1))
                footer.append(remove)
            }
            let footerRow = NSStackView(views: footer)
            footerRow.orientation = .horizontal
            footerRow.spacing = 6
            let card = verticalStack([tile, caption, footerRow], spacing: 4)
            card.alignment = .centerX
            tile.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
            // The wrapping grid owns frames; the stack lays out the card's controls.
            card.translatesAutoresizingMaskIntoConstraints = true
            cards.append(card)
        }
        grid.setCards(cards)
        if restoreFocus, tiles.indices.contains(selectedIndex) { window?.makeFirstResponder(tiles[selectedIndex]) }
    }

    private func rebuildPalette() {
        palette.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let button = DisplayViewContentButton(item: item)
            button.target = self
            button.action = #selector(assignFromPalette(_:))
            button.toolTip = item.title
            button.setAccessibilityHelp(L("views.blocks.hint"))
            palette.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: palette.widthAnchor).isActive = true
        }
    }

    private func refreshSelection() {
        for (index, tile) in tiles.enumerated() {
            tile.isSelected = index == selectedIndex
            let shown = mode != "automatic" && index == activeIndex
            statusLabels[index].stringValue = shown ? L("views.active") : index == 0 ? L("views.fixed") : ""
        }
        guard contents.indices.contains(selectedIndex) else { return }
        let item = item(for: contents[selectedIndex])
        editTitle.stringValue = L("views.edit", selectedIndex + 1)
        previewGlyph.stringValue = item.glyph
        previewTitle.stringValue = item.title
        previewDetail.stringValue = contents[selectedIndex] == Settings.clockView
            ? DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            : L("views.preview.source")
        showButton.isHidden = mode == "automatic"
        showButton.isEnabled = selectedIndex != activeIndex
        showButton.setAccessibilityLabel(L("views.show.a11y", selectedIndex + 1))
    }

    private func canAssign(_ content: String) -> Bool {
        items.contains { $0.content == content }
    }

    private func configureDrop(_ surface: DisplayViewDropSurface) {
        surface.acceptContent = { [weak self] content in self?.canAssign(content) ?? false }
        surface.onDrop = { [weak self] content in
            guard let self else { return }
            self.onAssign?(self.selectedIndex, content)
        }
    }

    @objc private func selectTile(_ sender: NSButton) { selectWindow(sender.tag) }
    @objc private func addWindow() { onAdd?() }
    @objc private func removeWindow(_ sender: NSButton) { onRemove?(sender.tag) }
    @objc private func showWindow() { onShow?(selectedIndex) }
    @objc private func assignFromPalette(_ sender: DisplayViewContentButton) {
        onAssign?(selectedIndex, sender.content)
    }

    private func hint(_ key: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L(key))
        label.font = NSFont.appFont(.subheadline)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func panel(_ content: NSView) -> NSView {
        let panel = DisplayViewDropSurface(acceptsDrops: false)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
        ])
        return panel
    }
}

/// Tiles wrap as the settings window is resized; all eight windows remain reachable
/// through the Display page's existing vertical scroll view.
private final class DisplayViewEditorGrid: NSView {
    private var cards: [NSView] = []
    private let spacing: CGFloat = 8
    private let rowHeight: CGFloat = 138
    override var isFlipped: Bool { true }
    private var columns: Int { max(1, Int((max(bounds.width, 112) + spacing) / (112 + spacing))) }
    override var intrinsicContentSize: NSSize {
        let rows = (cards.count + columns - 1) / columns
        return NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows) * (rowHeight + spacing) - (rows > 0 ? spacing : 0))
    }

    func setCards(_ cards: [NSView]) {
        self.cards.forEach { $0.removeFromSuperview() }
        self.cards = cards
        cards.forEach { addSubview($0) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        guard oldSize != newSize else { return }
        if oldSize.width != newSize.width { invalidateIntrinsicContentSize() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let count = columns
        let width = (bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count)
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(x: CGFloat(index % count) * (width + spacing),
                                y: CGFloat(index / count) * (rowHeight + spacing),
                                width: width, height: rowHeight)
        }
    }
}

private let displayViewContentType = NSPasteboard.PasteboardType("org.aimonitor.display-view-content")

/// Only our own palette can supply a window content. External text/files are ignored.
private func displayViewDropContent(_ sender: NSDraggingInfo,
                                    accepting: ((String) -> Bool)?) -> String? {
    guard sender.draggingSource is DisplayViewContentButton,
          sender.draggingSourceOperationMask.contains(.copy),
          let content = sender.draggingPasteboard.string(forType: displayViewContentType),
          accepting?(content) == true else { return nil }
    return content
}

final class DisplayViewContentButton: NSButton, NSDraggingSource {
    let content: String

    init(item: DisplayViewEditorItem) {
        content = item.content
        super.init(frame: .zero)
        title = item.title
        image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        contentTintColor = .labelColor
        bezelStyle = .rounded
        cell?.lineBreakMode = .byTruncatingTail
        setAccessibilityLabel(item.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // NSButton's mouseDown tracks until mouse-up itself, so detect the drag
    // before handing a plain click to the normal target/action path.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        let start = event.locationInWindow
        window.makeFirstResponder(self)
        highlight(true)
        defer { highlight(false) }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) {
                    performClick(nil)
                }
                return
            }
            guard hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 6 else { continue }
            let writer = NSPasteboardItem()
            writer.setString(content, forType: displayViewContentType)
            let drag = NSDraggingItem(pasteboardWriter: writer)
            let dragImage = NSImage(size: bounds.size)
            if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: bitmap)
                dragImage.addRepresentation(bitmap)
            }
            drag.setDraggingFrame(bounds, contents: dragImage)
            beginDraggingSession(with: [drag], event: event, source: self)
            return
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

final class DisplayViewDropSurface: NSView {
    var acceptContent: ((String) -> Bool)?
    var onDrop: ((String) -> Void)?
    private var dropHighlighted = false { didSet { needsDisplay = true } }

    init(acceptsDrops: Bool = true) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if acceptsDrops { registerForDraggedTypes([displayViewContentType]) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (dropHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = dropHighlighted ? 2 : 1
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlighted = displayViewDropContent(sender, accepting: acceptContent) != nil
        return dropHighlighted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        displayViewDropContent(sender, accepting: acceptContent) != nil
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        guard let content = displayViewDropContent(sender, accepting: acceptContent) else { return false }
        onDrop?(content)
        return true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlighted = false }
}

private final class DisplayViewTile: NSButton {
    var acceptContent: ((String) -> Bool)?
    var onDrop: ((String) -> Void)?
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
            setAccessibilitySelected(isSelected)
        }
    }
    private var dropHighlighted = false { didSet { needsDisplay = true } }
    private let glyph: String
    override var isFlipped: Bool { true }

    init(title: String, glyph: String) {
        self.glyph = glyph
        super.init(frame: .zero)
        self.title = title
        toolTip = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        registerForDraggedTypes([displayViewContentType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        (isSelected || (cell?.isHighlighted ?? false) ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                                    : NSColor.windowBackgroundColor).setFill()
        path.fill()
        (isSelected || dropHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isSelected || dropHighlighted ? 2 : 1
        path.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (glyph as NSString).draw(in: NSRect(x: 8, y: 12, width: bounds.width - 16, height: 28),
                                withAttributes: [.font: NSFont.appFont(.title1), .foregroundColor: NSColor.controlAccentColor,
                                                 .paragraphStyle: paragraph])
        (title as NSString).draw(in: NSRect(x: 8, y: bounds.height - 34, width: bounds.width - 16, height: 22),
                                withAttributes: [.font: NSFont.appFont(.body, weight: .semibold),
                                                 .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            focus.lineWidth = 2
            focus.stroke()
        }
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlighted = displayViewDropContent(sender, accepting: acceptContent) != nil
        return dropHighlighted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        displayViewDropContent(sender, accepting: acceptContent) != nil
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        guard let content = displayViewDropContent(sender, accepting: acceptContent) else { return false }
        onDrop?(content)
        return true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlighted = false }
}
