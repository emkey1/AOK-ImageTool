import AppKit
import VisionKit

/// Owns the AppKit canvas: zoom/pan, display updates, animation playback and Live Text.
final class CanvasController: NSObject {
    let container = CanvasContainerView()
    let scrollView = CanvasScrollView()
    let documentView = CanvasDocumentView()
    private(set) var overlay: ImageAnalysisOverlayView?
    weak var model: ViewerModel?

    private(set) var display: DisplayImage?
    private(set) var isFitMode = true
    private var analysisTask: Task<Void, Never>?
    private var analyzedContentKey: Int?
    private var animation: AnimationHandle?
    private var animatingURL: URL?
    private let analyzer = ImageAnalyzer()
    private var observers: [NSObjectProtocol] = []
    private var lastContainerSize: CGSize = .zero

    // Trackpad-swipe / wheel navigation state
    private var swipeAccumulator: CGFloat = 0
    private var swipeConsumed = false
    private var lastWheelNavigation = Date.distantPast

    var checkerboard = true
    var pixelated = false
    /// Fit enlarges images smaller than the window instead of stopping at 100%.
    var enlargeSmallImages = false {
        didSet { if oldValue != enlargeSmallImages, isFitMode { fit() } }
    }
    var liveTextEnabled = true {
        didSet {
            guard oldValue != liveTextEnabled else { return }
            overlay?.isHidden = !liveTextEnabled
            if liveTextEnabled, let display { scheduleAnalysis(for: display, force: true) }
        }
    }

    static let zoomSteps: [CGFloat] = [
        0.02, 0.03, 0.05, 0.0625, 0.08, 0.1, 0.125, 0.167, 0.25, 0.333, 0.5, 0.667, 0.75,
        1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64,
    ]

    override init() {
        super.init()
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = documentView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.005
        scrollView.maxMagnification = 64
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // The insets are worked out here (see `updateInsets`): AppKit's own, in a SwiftUI window, leave room for
        // the toolbar even when the canvas is already below it, pushing a fitted picture down under the filmstrip.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.controller = self
        documentView.controller = self
        container.controller = self

        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        if ImageAnalyzer.isSupported {
            let ov = ImageAnalysisOverlayView()
            ov.delegate = self
            ov.preferredInteractionTypes = .automatic
            ov.frame = container.bounds
            ov.autoresizingMask = [.width, .height]
            container.addSubview(ov)
            overlay = ov
        }

        clip.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isFitMode = false
                self?.viewportChanged()
            }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        animation?.stop()
        analysisTask?.cancel()
    }

    var backingScale: CGFloat { container.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Zoom expressed in image pixels per screen pixel (1 = 100%, "actual pixels").
    var pixelScale: CGFloat { scrollView.magnification * backingScale }

    var canPan: Bool {
        guard display != nil else { return false }
        let visible = scrollView.contentView.bounds.size
        let doc = documentView.frame.size
        return doc.width > visible.width + 1 || doc.height > visible.height + 1
    }

    // MARK: - Display

    func show(_ new: DisplayImage?, transition: Bool) {
        let old = display
        display = new
        guard let new else {
            stopAnimation()
            documentView.setImage(nil, hdr: false, checkerboard: false, pixelated: false)
            overlay?.analysis = nil
            analyzedContentKey = nil
            return
        }

        let urlChanged = old?.url != new.url
        let sizeChanged = old?.logicalSize != new.logicalSize
        if !new.animate || urlChanged { stopAnimation() }
        if transition && urlChanged { documentView.fadeNextChange() }

        documentView.setImage(new.image, hdr: new.isHDR, checkerboard: checkerboard && new.hasAlpha, pixelated: pixelated)

        if urlChanged || sizeChanged || old == nil {
            let keepZoom = urlChanged && old != nil && !isFitMode && (model?.lockZoom ?? false)
            let relativeCenter = keepZoom ? currentRelativeCenter() : nil
            let magnification = scrollView.magnification
            documentView.frame = CGRect(origin: .zero, size: new.logicalSize)
            if keepZoom, let relativeCenter {
                scrollView.magnification = magnification
                scroll(toRelativeCenter: relativeCenter)
                viewportChanged()
            } else {
                fit()
            }
        }

        if new.animate, animatingURL != new.url { startAnimation(new.url) }

        if new.contentKey != analyzedContentKey {
            overlay?.analysis = nil
            scheduleAnalysis(for: new, force: false)
        }
        overlay?.setContentsRectNeedsUpdate()
        container.window?.invalidateCursorRects(for: documentView)
    }

    func refreshAppearance() {
        guard let display else { return }
        documentView.setImage(display.image, hdr: display.isHDR, checkerboard: checkerboard && display.hasAlpha, pixelated: pixelated)
    }

    private func startAnimation(_ url: URL) {
        stopAnimation()
        animatingURL = url
        animation = AnimationHandle.start(url: url) { [weak self] frame in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.animatingURL == url else { return }
                    self.documentView.setFrame(frame)
                }
            }
        }
    }

    private func stopAnimation() {
        animation?.stop()
        animation = nil
        animatingURL = nil
    }

    // MARK: - Zoom

    func fit() {
        isFitMode = true
        guard let size = display?.logicalSize, size.width > 0, size.height > 0 else { return }
        let insets = scrollView.contentInsets
        let available = CGSize(width: scrollView.frame.width - insets.left - insets.right,
                               height: scrollView.frame.height - insets.top - insets.bottom)
        guard available.width > 0, available.height > 0 else { return }
        var mag = min(available.width / size.width, available.height / size.height)
        if !enlargeSmallImages { mag = min(mag, 1 / backingScale) }
        scrollView.setMagnification(mag, centeredAt: NSPoint(x: size.width / 2, y: size.height / 2))
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        viewportChanged()
    }

    func zoom(toPixelScale target: CGFloat, at point: NSPoint? = nil) {
        guard display != nil else { return }
        isFitMode = false
        let mag = min(max(target / backingScale, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.setMagnification(mag, centeredAt: point ?? visibleCenter)
        viewportChanged()
    }

    func zoom(byFactor factor: CGFloat, at point: NSPoint) {
        guard display != nil else { return }
        isFitMode = false
        let mag = min(max(scrollView.magnification * factor, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.setMagnification(mag, centeredAt: point)
        viewportChanged()
    }

    func zoomIn() {
        let current = pixelScale
        zoom(toPixelScale: Self.zoomSteps.first { $0 > current * 1.01 } ?? Self.zoomSteps.last!)
    }

    func zoomOut() {
        let current = pixelScale
        zoom(toPixelScale: Self.zoomSteps.last { $0 < current * 0.99 } ?? Self.zoomSteps.first!)
    }

    func actualSize() {
        zoom(toPixelScale: 1)
    }

    func toggleZoom(at point: NSPoint?) {
        if isFitMode || pixelScale < 0.99 {
            zoom(toPixelScale: isFitMode && abs(pixelScale - 1) < 0.01 ? 2 : 1, at: point)
        } else {
            fit()
        }
    }

    func userDidZoom() {
        isFitMode = false
    }

    private var visibleCenter: NSPoint {
        let b = scrollView.contentView.bounds
        return NSPoint(x: b.midX, y: b.midY)
    }

    private func currentRelativeCenter() -> CGPoint? {
        let size = documentView.frame.size
        guard size.width > 0, size.height > 0 else { return nil }
        let c = visibleCenter
        return CGPoint(x: c.x / size.width, y: c.y / size.height)
    }

    private func scroll(toRelativeCenter rel: CGPoint) {
        let clip = scrollView.contentView
        let size = documentView.frame.size
        let b = clip.bounds
        let origin = NSPoint(x: rel.x * size.width - b.width / 2, y: rel.y * size.height - b.height / 2)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: b.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func containerDidLayout() {
        let size = container.bounds.size
        let insetsChanged = updateInsets()
        guard size != lastContainerSize || insetsChanged else { return }
        lastContainerSize = size
        if isFitMode {
            fit()
        } else {
            let clip = scrollView.contentView
            clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
            scrollView.reflectScrolledClipView(clip)
            viewportChanged()
        }
    }

    /// Keeps the picture out from under the window's toolbar where the canvas reaches beneath it (and only
    /// there), so a fitted picture is all in view. Returns whether the insets changed.
    @discardableResult
    func updateInsets() -> Bool {
        var top: CGFloat = 0
        if let window = container.window {
            let inWindow = container.convert(container.bounds, to: nil)
            top = max(0, inWindow.maxY - window.contentLayoutRect.maxY).rounded()
        }
        guard scrollView.contentInsets.top != top || scrollView.contentInsets.bottom != 0 else { return false }
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        return true
    }

    private func viewportChanged() {
        overlay?.setContentsRectNeedsUpdate()
        model?.zoomDidChange(percent: Double(pixelScale * 100), isFit: isFitMode)
        container.window?.invalidateCursorRects(for: documentView)
    }

    // MARK: - Swipe / wheel navigation when the whole image is visible

    func handleNavigationScroll(_ event: NSEvent) -> Bool {
        guard let model, display != nil, !canPan else { return false }
        if event.hasPreciseScrollingDeltas {
            if event.phase == .began {
                swipeAccumulator = 0
                swipeConsumed = false
            }
            if event.momentumPhase != [] { return swipeConsumed || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) }
            swipeAccumulator += event.scrollingDeltaX
            if !swipeConsumed, abs(swipeAccumulator) > 60, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
                swipeConsumed = true
                if swipeAccumulator > 0 { model.previous() } else { model.next() }
            }
            return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeConsumed
        }
        // Classic mouse wheel: one notch = one image.
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0, Date().timeIntervalSince(lastWheelNavigation) > 0.12 else { return true }
        lastWheelNavigation = Date()
        if delta > 0 { model.previous() } else { model.next() }
        return true
    }

    // MARK: - Live Text / Visual Look Up

    private func scheduleAnalysis(for display: DisplayImage, force: Bool) {
        analysisTask?.cancel()
        guard let overlay, liveTextEnabled, !display.isPlaceholder else { return }
        if !force && display.contentKey == analyzedContentKey { return }
        let image = display.image
        let key = display.contentKey
        analysisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            let config = ImageAnalyzer.Configuration([.text, .visualLookUp, .machineReadableCode])
            // (Its own plain copy: see VisionServices.plainCopy. Text stays readable at 4096 px.)
            let copy = await VisionServices.plainCopy(image, maxDimension: 4096)
            guard !Task.isCancelled,
                  let analysis = try? await self.analyzer.analyze(copy, orientation: .up, configuration: config) else { return }
            guard !Task.isCancelled, self.display?.contentKey == key else { return }
            self.analyzedContentKey = key
            overlay.analysis = analysis
            overlay.preferredInteractionTypes = .automatic
            overlay.setContentsRectNeedsUpdate()
            self.model?.liveTextDidUpdate(hasText: analysis.hasResults(for: .text))
        }
    }

    func setLiveTextHighlighted(_ highlighted: Bool) {
        overlay?.selectableItemsHighlighted = highlighted
    }

    var liveTextText: String? {
        guard let text = overlay?.text, !text.isEmpty else { return nil }
        return text
    }

    var selectedLiveText: String? {
        guard let overlay, overlay.hasActiveTextSelection else { return nil }
        return overlay.selectedText
    }
}

extension CanvasController: ImageAnalysisOverlayViewDelegate {
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        let bounds = overlayView.bounds
        guard display != nil, bounds.width > 0, bounds.height > 0 else { return .zero }
        let r = overlayView.convert(documentView.bounds, from: documentView)
        var y = r.minY / bounds.height
        if !overlayView.isFlipped { y = 1 - r.maxY / bounds.height }
        return CGRect(x: r.minX / bounds.width, y: y, width: r.width / bounds.width, height: r.height / bounds.height)
    }
}
