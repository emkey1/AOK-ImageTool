import AppKit
import QuartzCore

/// Hosts the scroll view and the Live Text overlay; paints the canvas background.
final class CanvasContainerView: NSView {
    weak var controller: CanvasController?

    var background: CanvasBackground = .dark {
        didSet { if oldValue != background { updateBackground() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        var color = NSColor.black.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = background.nsColor.cgColor
        }
        layer?.backgroundColor = color
    }

    override func layout() {
        super.layout()
        controller?.containerDidLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.containerDidLayout()
    }

    // (Where the canvas sits in the window decides how much of it is under the toolbar.)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.containerDidLayout()
    }

    // Events that land on the Live Text overlay but aren't consumed bubble up here; route them to the scroll view.
    override func scrollWheel(with event: NSEvent) {
        controller?.scrollView.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        controller?.scrollView.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        controller?.scrollView.smartMagnify(with: event)
    }
}

/// Keeps the document centered when it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let frame = doc.frame
        // Centered in what's in view: the bounds less the insets (the top one is at maxY; not flipped).
        let i = contentInsets
        let visibleWidth = rect.width - i.left - i.right, visibleHeight = rect.height - i.top - i.bottom
        if visibleWidth > frame.width { rect.origin.x = frame.midX - i.left - visibleWidth / 2 }
        if visibleHeight > frame.height {
            rect.origin.y = isFlipped ? frame.midY - i.top - visibleHeight / 2 : frame.midY - i.bottom - visibleHeight / 2
        }
        return rect
    }

    // Clicking the empty area around the image focuses the canvas (so arrow keys work again).
    override func mouseDown(with event: NSEvent) {
        guard let doc = documentView as? CanvasDocumentView else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(doc)
        if event.clickCount == 2 {
            doc.controller?.toggleZoom(at: doc.convert(event.locationInWindow, from: nil))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        documentView?.menu(for: event)
    }
}

final class CanvasScrollView: NSScrollView {
    weak var controller: CanvasController?

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return super.scrollWheel(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if !mods.isEmpty {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            let point = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
            controller.zoom(byFactor: exp(delta * 0.006), at: point)
            return
        }
        if controller.handleNavigationScroll(event) { return }
        super.scrollWheel(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        guard let controller, let doc = documentView else { return super.smartMagnify(with: event) }
        controller.toggleZoom(at: doc.convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        controller?.userDidZoom()
        super.magnify(with: event)
    }
}

/// The zoomable document. The image is a GPU-scaled `CALayer`, so zooming never re-rasterizes.
final class CanvasDocumentView: NSView {
    weak var controller: CanvasController?
    let imageLayer = CALayer()
    private var dragStart: NSPoint?
    private var originAtDragStart: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func setImage(_ image: CGImage?, hdr: Bool, checkerboard: Bool, pixelated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        if #available(macOS 26, *) {
            imageLayer.preferredDynamicRange = hdr ? .high : .standard
        } else {
            imageLayer.wantsExtendedDynamicRangeContent = hdr
        }
        imageLayer.magnificationFilter = pixelated ? .nearest : .linear
        layer?.backgroundColor = (checkerboard && image != nil) ? Self.checkerboardColor : nil
        CATransaction.commit()
    }

    func setFrame(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    func fadeNextChange() {
        let t = CATransition()
        t.type = .fade
        t.duration = 0.45
        imageLayer.add(t, forKey: "fade")
    }

    static let checkerboardColor: CGColor = {
        let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(white: 0.82, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.68, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }()

    // MARK: Mouse: click-drag to pan, double-click to toggle zoom.

    private var canPan: Bool { controller?.canPan ?? false }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            controller?.toggleZoom(at: convert(event.locationInWindow, from: nil))
            return
        }
        guard canPan, let clip = enclosingScrollView?.contentView else { return }
        dragStart = event.locationInWindow
        originAtDragStart = clip.bounds.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let mag = scroll.magnification
        var origin = originAtDragStart
        origin.x -= (event.locationInWindow.x - start.x) / mag
        origin.y -= (event.locationInWindow.y - start.y) / mag
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: constrained.origin)
        scroll.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil {
            NSCursor.pop()
            dragStart = nil
        }
    }

    override func resetCursorRects() {
        if canPan { addCursorRect(visibleRect, cursor: .openHand) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.model?.contextMenu()
    }

    // Edit ▸ Copy while the canvas is focused copies the (edited) image.
    @objc func copy(_ sender: Any?) {
        controller?.model?.copyImage()
    }
}

/// Plays animated GIF / APNG / WebP / HEICS via ImageIO's animation driver.
nonisolated final class AnimationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }

    static func start(url: URL, onFrame: @escaping @Sendable (CGImage) -> Void) -> AnimationHandle {
        let handle = AnimationHandle()
        CGAnimateImageAtURLWithBlock(url as CFURL, nil) { _, image, stop in
            if handle.isStopped {
                stop.pointee = true
                return
            }
            onFrame(image)
        }
        return handle
    }
}
