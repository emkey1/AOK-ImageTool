import CoreImage
import SwiftUI

/// What one removal takes away: a mask in the image's own pixel space (white = remove), and how far past it
/// to fill. A change (Change Objects) also keeps what was selected and the objects it was selected in, as shown
/// (`selection`, `shownReach`) and in the image's pixels (`reach`), and what it was changed to.
private struct RemovalMark: @unchecked Sendable {
    let mask: CIImage
    let grow: CGFloat
    var selection: CIImage? = nil
    var shownReach: CIImage? = nil
    var reach: CIImage? = nil
    var change: ChangeRequest? = nil
    /// A Clone & Heal stroke: what's painted is copied from this far away (image pixels, Core Image's y up).
    var clone: CloneStep? = nil
}

private struct CloneStep {
    let offset: CGVector
    let heal: Bool
}

/// Progress of the removal being made, updated from the background.
@MainActor @Observable
private final class RemovalProgress {
    var value: Double?
}

/// Remove Objects: paint over something, click it or circle it, and it's removed, filled in from what's around
/// it. Each removal is a step of its own (⌘Z takes it back, Try Again fills it differently); Done saves the
/// result as a copy, or as an edit.
///
/// Change Objects is the same tool for changing things instead: click or paint what to change (a shirt), say
/// what it should be (“blue”, “a red plaid shirt”), and a color is changed in place, keeping its shading, or
/// anything else is painted there by the generative model.
///
/// Clone & Heal paints with the picture itself: ⌥-click where to copy from, then paint where it goes; Heal blends
/// it into the color and light there.
struct RemoveObjectsEditor: View {
    enum Mode { case remove, change, clone }

    @Environment(ViewerModel.self) private var model
    let mode: Mode
    /// The edits the image had when the tool opened; this session's removals go on top.
    @State private var start = EditState()
    @State private var removals: [Removal] = []
    @State private var marks: [RemovalMark] = []
    @State private var undone: [(removal: Removal, mark: RemovalMark)] = []
    /// The image as it looks now (turned and adjusted, uncropped), and before this session's removals.
    @State private var picture: CGImage?
    @State private var original: CGImage?
    @State private var showOriginal = false
    /// The stroke being painted (normalized in the picture, top-left origin) and its width (normalized to the
    /// picture's width); kept on screen while it's removed.
    @State private var stroke: [CGPoint] = []
    @State private var strokeWidth: CGFloat = 0
    /// A clicked object's outline, shown while it's removed.
    @State private var outline: CGImage?
    @State private var hover: CGPoint?
    @State private var brush = Prefs.removalBrush
    @State private var method = Prefs.preferredRemovalMethod
    @State private var progress = RemovalProgress()
    @State private var busy = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    @State private var eraseInstalled = RemovalModel.isInstalled
    @State private var eraseWhenInstalled = false
    @State private var generateWhenInstalled = false
    /// What Generate paints in place of what's marked.
    @State private var promptText = ""
    /// Zoom, relative to the picture fitting the view (1), and how far it's moved (points).
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var zoomStart: CGFloat?
    @State private var viewport: CGSize = .zero
    @State private var scrollMonitor: Any?
    @State private var renderGeneration = 0
    /// A render is under way for the strength slider; `renderAgain`: it moved since, so one more follows.
    @State private var rendering = false
    @State private var renderAgain = false

    // Change Objects
    /// What's selected to change (white), the picture's size, and how it's shown: tinted, until it's changed.
    @State private var selection: CIImage?
    @State private var selectionShown: CGImage?
    /// The objects the selection was made in (all of a person clicked, the area painted): a color change also
    /// changes its color where it shows through, as between strands of hair.
    @State private var reach: CIImage?
    /// The last change was made from `selection`: changing again makes it over, clicking starts a new selection.
    @State private var selectionApplied = false
    @State private var changeText = ""
    @State private var appliedText = ""
    /// Clicks and strokes select only what's the color there (a shirt, not the person wearing it).
    @State private var onlyThatColor = true
    /// How much the last change shows.
    @State private var strength: Double = 1
    @State private var generateInstalled = GenerativeModel.isInstalled
    /// What the tool is busy with, when it's not a removal.
    @State private var activity: String?

    // Clone & Heal
    /// Where to copy from (⌥-click; normalized in the picture, top-left origin), and, from the first stroke after
    /// it, how far that is from where it's painted (kept for the strokes after, as Photoshop's Aligned does).
    @State private var cloneSource: CGPoint?
    @State private var cloneOffset: CGSize?
    @State private var pickingSource = false
    @State private var heal = Prefs.cloneHeals

    init(mode: Mode = .remove) {
        self.mode = mode
    }

    private static let markColor = Color(red: 1, green: 0.3, blue: 0.4)
    static let maxZoom: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color(white: 0.07)
                    if let image = showOriginal ? original : picture {
                        let fitted = Self.fittedRect(image, in: geo.size)
                        let shown = shownRect(fitted: fitted)
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(zoom > 1.5 ? .medium : .high)
                            .frame(width: shown.width, height: shown.height)
                            .position(x: shown.midX, y: shown.midY)
                        if mode == .clone, !showOriginal, let offset = cloneOffset, !stroke.isEmpty {
                            clonePreview(image, offset: offset, in: shown)
                        }
                        markOverlay(in: shown)
                        if mode == .change, !selectionApplied, !showOriginal, let selectionShown {
                            Image(decorative: selectionShown, scale: 1)
                                .resizable()
                                .frame(width: shown.width, height: shown.height)
                                .position(x: shown.midX, y: shown.midY)
                                .allowsHitTesting(false)
                                .modifier(Pulsing(active: busy))
                        }
                        if mode == .clone, !busy, !showOriginal, let source = cloneMarker(in: shown) {
                            CloneMarker().position(source).allowsHitTesting(false)
                        }
                        if let hover, !busy, !showOriginal, shown.contains(hover) {
                            Circle()
                                .strokeBorder(.white, lineWidth: 1.5)
                                .shadow(color: .black.opacity(0.6), radius: 1)
                                .frame(width: brush, height: brush)
                                .position(hover)
                                .allowsHitTesting(false)
                        }
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(paintGesture(in: shown))
                            .simultaneousGesture(pinchGesture)
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                if case .active(let p) = phase { hover = p } else { hover = nil }
                            }
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    hint.position(x: geo.size.width / 2, y: 20)
                }
                .clipped()
                .onAppear { viewport = geo.size }
                .onChange(of: geo.size) {
                    viewport = geo.size
                    setZoom(zoom, about: nil)
                }
            }
            controls
        }
        .onAppear {
            start = model.currentEdits
            if !method.isAvailable { method = .match }
            Task { await render(initial: true) }
            // Two-finger scrolling (or the wheel) moves around a zoomed picture; with ⌘, it zooms.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
                guard event.window === model.window, let point = hover else { return event }
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
                if event.modifierFlags.contains(.command) {
                    setZoom(zoom * exp(event.scrollingDeltaY * scale * 0.01), about: point)
                } else {
                    move(by: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
                }
                return nil
            }
        }
        .onDisappear {
            task?.cancel()
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolZoom)) { note in
            guard note.object as AnyObject? === model, let step = note.userInfo?["step"] as? Int else { return }
            step == 0 ? setZoom(1, about: nil) : setZoom(zoom * (step > 0 ? 1.5 : 1 / 1.5), about: hover)
        }
        .onChange(of: ModelDownloads.shared.installCount) {
            eraseInstalled = RemovalModel.isInstalled
            generateInstalled = GenerativeModel.isInstalled
            if eraseInstalled && eraseWhenInstalled {
                eraseWhenInstalled = false
                setMethod(.erase)
            }
            if GenerativeModel.isInstalled && generateWhenInstalled {
                generateWhenInstalled = false
                setMethod(.generate)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCommit)) { note in
            guard note.object as AnyObject? === model, !busy else { return }
            // In Change Objects, Return makes the change described (when it's new); else it's Done.
            let text = changeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == .change, selection != nil, !text.isEmpty, !selectionApplied || text != appliedText {
                applyChange()
            } else {
                finish()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCancel)) { note in
            guard note.object as AnyObject? === model else { return }
            // Esc stops a removal that's being made; otherwise it closes the tool.
            if busy { task?.cancel() } else { model.activeTool = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolUndo)) { note in
            if note.object as AnyObject? === model { undo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolRedo)) { note in
            if note.object as AnyObject? === model { redo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolBrush)) { note in
            guard note.object as AnyObject? === model else { return }
            setBrush(brush * ((note.userInfo?["larger"] as? Bool) == true ? 1.25 : 0.8))
        }
    }

    // MARK: Canvas

    private static func fittedRect(_ image: CGImage, in size: CGSize) -> CGRect {
        fitRect(CGSize(width: image.width, height: image.height), in: CGRect(origin: .zero, size: size).insetBy(dx: 30, dy: 30))
    }

    /// Where the picture is drawn: fitted to the view, zoomed about its middle, moved by `pan`.
    private func shownRect(fitted: CGRect) -> CGRect {
        let w = fitted.width * zoom, h = fitted.height * zoom
        return CGRect(x: fitted.midX - w / 2 + pan.width, y: fitted.midY - h / 2 + pan.height, width: w, height: h)
    }

    /// `offset` limited so the picture doesn't leave the view: centered where it's smaller than the view,
    /// filling it where it's bigger.
    private static func clamped(_ offset: CGSize, fitted: CGRect, zoom: CGFloat, view: CGSize) -> CGSize {
        func axis(_ offset: CGFloat, size: CGFloat, mid: CGFloat, view: CGFloat) -> CGFloat {
            guard size > view else { return 0 }
            return min(max(offset, view - mid - size / 2), size / 2 - mid)
        }
        return CGSize(width: axis(offset.width, size: fitted.width * zoom, mid: fitted.midX, view: view.width),
                      height: axis(offset.height, size: fitted.height * zoom, mid: fitted.midY, view: view.height))
    }

    /// Zooms to `z` (1 = fit), keeping what's under `point` (the middle, if nil) where it is.
    private func setZoom(_ z: CGFloat, about point: CGPoint?) {
        guard let picture, viewport.width > 0 else { return }
        let fitted = Self.fittedRect(picture, in: viewport)
        let shown = shownRect(fitted: fitted)
        let newZoom = min(max(z, 1), Self.maxZoom)
        let p = point ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let n = CGPoint(x: (p.x - shown.minX) / shown.width, y: (p.y - shown.minY) / shown.height)
        let w = fitted.width * newZoom, h = fitted.height * newZoom
        let offset = CGSize(width: p.x - n.x * w - (fitted.midX - w / 2), height: p.y - n.y * h - (fitted.midY - h / 2))
        zoom = newZoom
        pan = Self.clamped(offset, fitted: fitted, zoom: newZoom, view: viewport)
    }

    private func move(by delta: CGSize) {
        guard let picture, zoom > 1 else { return }
        let fitted = Self.fittedRect(picture, in: viewport)
        pan = Self.clamped(CGSize(width: pan.width + delta.width, height: pan.height + delta.height), fitted: fitted, zoom: zoom, view: viewport)
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = zoom }
                setZoom((zoomStart ?? 1) * value.magnification, about: value.startLocation)
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// The stroke being painted, in the view.
    private func strokePath(in fitted: CGRect) -> Path {
        Path { path in
            let points = stroke.map { CGPoint(x: fitted.minX + $0.x * fitted.width, y: fitted.minY + $0.y * fitted.height) }
            if points.count == 1 {
                path.move(to: points[0])
                path.addLine(to: points[0])
            } else {
                path.addLines(points)
            }
        }
    }

    /// What Clone & Heal copies where it's being painted: the picture, moved by `offset`, seen through the stroke.
    private func clonePreview(_ image: CGImage, offset: CGSize, in shown: CGRect) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(zoom > 1.5 ? .medium : .high)
            .frame(width: shown.width, height: shown.height)
            .position(x: shown.midX - offset.width * shown.width, y: shown.midY - offset.height * shown.height)
            .mask {
                strokePath(in: shown)
                    .stroke(style: StrokeStyle(lineWidth: strokeWidth * shown.width, lineCap: .round, lineJoin: .round))
                    .blur(radius: strokeWidth * shown.width * 0.08)
            }
            .clipShape(Rectangle().path(in: shown))
            .allowsHitTesting(false)
    }

    /// Where Clone & Heal copies from, in the view: following the pointer once a stroke has set the offset.
    private func cloneMarker(in shown: CGRect) -> CGPoint? {
        if let offset = cloneOffset, let hover, shown.contains(hover) {
            return CGPoint(x: hover.x + offset.width * shown.width, y: hover.y + offset.height * shown.height)
        }
        guard cloneOffset == nil, let source = cloneSource else { return nil }
        return CGPoint(x: shown.minX + source.x * shown.width, y: shown.minY + source.y * shown.height)
    }

    @ViewBuilder
    private func markOverlay(in fitted: CGRect) -> some View {
        if !stroke.isEmpty, !(mode == .clone && cloneOffset != nil) {
            strokePath(in: fitted)
            .stroke(Self.markColor.opacity(0.55), style: StrokeStyle(lineWidth: strokeWidth * fitted.width, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
            .modifier(Pulsing(active: busy))
        }
        if let outline {
            Image(decorative: outline, scale: 1)
                .resizable()
                .frame(width: fitted.width, height: fitted.height)
                .position(x: fitted.midX, y: fitted.midY)
                .allowsHitTesting(false)
                .modifier(Pulsing(active: busy))
        }
    }

    private func paintGesture(in fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !busy, !showOriginal, picture != nil else { return }
                hover = value.location
                let p = CGPoint(x: (value.location.x - fitted.minX) / fitted.width, y: (value.location.y - fitted.minY) / fitted.height)
                // Clone & Heal: ⌥-click (or drag) sets where to copy from.
                if mode == .clone, pickingSource || (stroke.isEmpty && NSEvent.modifierFlags.contains(.option)) {
                    pickingSource = true
                    cloneSource = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
                    cloneOffset = nil
                    message = nil
                    return
                }
                if stroke.isEmpty {
                    outline = nil
                    message = nil
                    strokeWidth = brush / fitted.width
                    if mode == .clone, cloneOffset == nil, let source = cloneSource {
                        cloneOffset = CGSize(width: source.x - p.x, height: source.y - p.y)
                    }
                }
                stroke.append(p)
            }
            .onEnded { value in
                if pickingSource { return pickingSource = false }
                guard !busy, !stroke.isEmpty else { return }
                if mode == .clone { return cloneStroke() }
                let travel = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                let option = NSEvent.modifierFlags.contains(.option)
                if travel < 3, stroke.count < 4, let p = stroke.first {
                    stroke = []
                    // (A click beside the picture, in the margin around it, isn't on anything.)
                    guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                    mode == .change ? select(at: p, subtract: option) : removeObject(at: p)
                } else {
                    mode == .change ? selectStroke(subtract: option) : removeStroke()
                }
            }
    }

    // MARK: Bar

    private var hintText: String {
        if let message { return message }
        if mode == .change { return changeHint }
        if mode == .clone { return cloneHint }
        if busy {
            if let p = progress.value, p > 0 {
                return method == .generate ? "Generating on this Mac… \(Int(p * 100))%" : "Removing… \(Int(p * 100))%"
            }
            return outline == nil && stroke.isEmpty ? "Finding what's there…" : "Removing…"
        }
        if showOriginal { return "The original. Turn off Original to keep removing." }
        if method == .generate, promptText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Generate paints what you describe in place of what you mark. Describe it below first."
        }
        if removals.isEmpty {
            return "Paint over what to remove, or click it. Circle something to remove all of it. Pinch or ⌘-scroll to zoom in."
                + (eraseInstalled || !GenerativeModel.isSupported ? "" : " (Using Match Photo: for Erase, the best fill, click Get the Model for Erase… below.)")
        }
        return "Removed. Paint or click to remove more; Try Again fills it differently, ⌘Z takes it back."
    }

    private var cloneHint: String {
        if busy { return heal ? "Healing…" : "Copying…" }
        if showOriginal { return "The original. Turn off Original to keep going." }
        guard cloneSource != nil else {
            return "⌥-click where to copy from (clean skin, sky, grass), then paint where it should go. Pinch or ⌘-scroll to zoom in."
        }
        guard !removals.isEmpty else { return "Now paint where it should go: the + shows where it's copying from." }
        return (heal ? "Healed" : "Copied") + ". Keep painting, or ⌥-click to copy from somewhere else. ⌘Z takes back a stroke."
    }

    private var changeHint: String {
        if busy {
            if let p = progress.value, p > 0 { return "Generating on this Mac… \(Int(p * 100))%" }
            return activity ?? "Changing…"
        }
        if showOriginal { return "The original. Turn off Original to keep changing." }
        guard selection != nil else {
            return removals.isEmpty
                ? "Click what to change, such as a shirt, or paint over it. Then say below what it should be: “blue”, “dark green”, “a red plaid shirt”."
                : "Click or paint over something else to change it too. ⌘Z takes back a change."
        }
        if selectionApplied {
            let made = marks.last?.change.map { $0.color != nil ? "Recolored" : "Painted “\($0.description)”" } ?? "Changed"
            return "\(made). Say something else below and press Return to make it over, or click something else to change it too."
        }
        return "Selected. Click or paint to add to it (⌥ takes away), then say below what it should be and press Return."
    }

    private var hint: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Text(hintText)
                .font(.callout)
                .monospacedDigit()
                .lineLimit(2)
            if busy {
                Button("Stop") { task?.cancel() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassBackground(in: .capsule)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                switch mode {
                case .remove: removeControls
                case .change: changeControls
                case .clone: cloneControls
                }
                Spacer()
                Button { setZoom(zoom / 1.5, about: nil) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(zoom <= 1)
                    .help("Zoom out (⌘−)")
                Button(zoom <= 1.001 ? "Fit" : String(format: "%.1f×", zoom)) { setZoom(1, about: nil) }
                    .monospacedDigit()
                    .frame(minWidth: 46)
                    .help("Fit the picture in view (⌘0). Pinch, ⌘-scroll or ⌘+ to zoom in; scroll to move around.")
                Button { setZoom(zoom * 1.5, about: nil) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(zoom >= Self.maxZoom)
                    .help("Zoom in (⌘+)")
                Divider().frame(height: 18)
                Image(systemName: "paintbrush.pointed")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { brush }, set: { setBrush($0) }), in: 8...200) { Text("Brush") }
                    .frame(width: 140)
                    .help("Brush size ([ and ] change it)")
            }
            HStack(spacing: 10) {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(busy || removals.isEmpty)
                    .help("Undo the last removal (⌘Z)")
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(busy || undone.isEmpty)
                    .help("Redo (⇧⌘Z)")
                if mode == .change {
                    Button("Try Again") { tryAgain() }
                        .disabled(busy || marks.last?.change.map { $0.color != nil } ?? true)
                        .help("Paint the last change again, differently (a color comes out the same: say another color instead)")
                    Text("Strength")
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { strength }, set: { setStrength($0) }), in: 0...1) { Text("Strength") }
                        .labelsHidden()
                        .frame(width: 110)
                        .disabled(busy || removals.isEmpty)
                        .help("How much of the last change shows")
                } else if mode == .remove {
                    Button("Try Again") { tryAgain() }
                        .disabled(busy || removals.isEmpty)
                        .help("Remove the last one again, filled differently (with the Fill chosen now)")
                }
                Toggle(isOn: $showOriginal) { Label("Original", systemImage: "eye") }
                    .toggleStyle(.button)
                    .disabled(busy || removals.isEmpty)
                    .help(mode == .remove ? "Compare with the picture before these removals" : "Compare with the picture before these changes")
                if mode == .change {
                    Button("Deselect") { clearSelection() }
                        .disabled(busy || selection == nil)
                        .help("Clear the selection, to start a new one")
                }
                Spacer()
                Button("Cancel") { model.activeTool = nil }
                    .keyboardShortcut(.cancelAction)
                if mode == .change {
                    // (Return makes the change; Done saves.)
                    Button("Done") { finish() }
                        .disabled(busy)
                } else {
                    Button("Done") { finish() }
                        .prominentButtonStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var removeControls: some View {
        Picker("Fill", selection: Binding(get: { method }, set: { setMethod($0) })) {
            ForEach(RemovalMethod.allCases) { m in
                Text(m.title).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 300)
        .help("Erase paints in what was behind, with a model made for removing objects; Match Photo copies the photo's own texture (good for grass, sand, sky); Generate paints what you describe in its place, with \(GenerativeModel.displayName)")
        if method == .generate {
            TextField("Describe what to put there, such as “tall grass”", text: $promptText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 360)
                .help("Generate replaces what you mark with this. To just remove it, choose Erase.")
        }
        if !eraseInstalled && GenerativeModel.isSupported {
            Button("Get the Model for Erase…") {
                eraseWhenInstalled = true
                model.offerDownload(.removal) {}
            }
            .controlSize(.small)
            .help("Erase uses \(RemovalModel.displayName), which runs on this Mac (a one-time download of \(DownloadableModel.removal.formattedSize))")
        }
    }

    @ViewBuilder
    private var cloneControls: some View {
        Picker("Clone", selection: Binding(get: { heal }, set: { heal = $0; Prefs.setBool($0, PrefKey.cloneHeals) })) {
            Text("Heal").tag(true)
            Text("Copy").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 140)
        .help("Heal keeps the detail of what's copied but takes the color and light of where it goes, so it blends in; Copy copies it as it is")
        Text("⌥-click sets where to copy from")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var changeControls: some View {
        TextField("What should it be? Such as “blue” or “a red plaid shirt”", text: $changeText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220, maxWidth: 400)
            .onSubmit { applyChange() }
            .help("A color (“blue”, “dark green”, “navy”) is changed in place, keeping its shading; anything else (“a red plaid shirt”, “a leather jacket”) is painted there by \(GenerativeModel.displayName)")
        Button("Change") { applyChange() }
            .keyboardShortcut(.defaultAction)
            .disabled(busy || selection == nil || changeText.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Change what's selected (Return)")
        Toggle("Only That Color", isOn: $onlyThatColor)
            .toggleStyle(.checkbox)
            .help("Select only what's the color where you click or paint: a shirt, not the person wearing it. Turn it off to select whole objects, or exactly what you paint.")
        if !generateInstalled && GenerativeModel.isSupported {
            Button("Get the Model…") { model.offerDownload(.generativeFill) {} }
                .controlSize(.small)
                .help("Colors change without it. Anything else (a pattern, a different thing) is painted by \(GenerativeModel.displayName), on this Mac: a one-time download of \(DownloadableModel.generativeFill.formattedSize).")
        }
    }

    // MARK: Actions

    private func setMethod(_ m: RemovalMethod) {
        // A fill whose model isn't installed yet: offered for download, and chosen once it's in.
        guard m.isAvailable else {
            switch m {
            case .erase:
                eraseWhenInstalled = true
                model.offerDownload(.removal) {}
            case .generate:
                generateWhenInstalled = true
                model.offerDownload(.generativeFill) {}
            case .match:
                break
            }
            return
        }
        method = m
        Prefs.set(m.rawValue, PrefKey.removalMethod)
    }

    private func setBrush(_ value: Double) {
        brush = min(max(value, 8), 200)
        Prefs.set(brush, PrefKey.removalBrush)
    }

    /// The edits the tool shows: the image turned and adjusted as it is, but whole (no crop, straightening or
    /// document fix, whose areas a removal shouldn't depend on) and without a cutout.
    private var shownEdits: EditState {
        var e = start
        e.crop = nil
        e.straighten = 0
        e.perspective = nil
        e.extendFill = nil
        e.vignette = 0
        e.removeCutout()
        return e
    }

    private var allRemovals: [Removal] { (start.removals ?? []) + removals }

    private func render(initial: Bool = false) async {
        guard let d = model.decoded else { return }
        var e = shownEdits
        e.removals = allRemovals.isEmpty ? nil : allRemovals
        // (The latest wins, when the strength slider starts several.)
        renderGeneration += 1
        let generation = renderGeneration
        // (Up to 4096 px, so it's still sharp zoomed in.)
        guard let output = await EditRenderer.shared.render(d, edits: e, maxDimension: 4096, stage: .full),
              generation == renderGeneration else { return }
        picture = output.image
        if initial { original = output.image }
    }

    private func removeStroke() {
        guard let picture, let d = model.decoded else { return }
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        let points = stroke.map { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) }   // CG pixels, y up
        let diameter = strokeWidth * w
        let closed = Self.isLoop(points, diameter: diameter)
        guard let mask = Self.strokeMask(points, diameter: diameter, closed: closed, width: picture.width, height: picture.height) else { return }
        let longest = max(d.pixelSize.width, d.pixelSize.height)
        remove(RemovalMark(mask: sourceMask(CIImage(cgImage: mask)), grow: max(2, 0.003 * longest)))
    }

    private func removeObject(at p: CGPoint) {
        guard let picture, model.decoded != nil else { return }
        busy = true
        message = nil
        progress.value = nil
        let point = CGPoint(x: p.x, y: 1 - p.y)   // Vision: lower-left origin
        task = Task {
            do {
                var found: CIImage
                if #available(macOS 27, *), let refined = try? await VisionServices.objectMask(for: picture, included: [point], excluded: []) {
                    found = refined
                } else {
                    found = try await VisionServices.instanceMask(for: picture, at: point)
                }
                guard !Task.isCancelled else { return busy = false }
                let size = CGSize(width: picture.width, height: picture.height)
                found = Self.fitted(found, to: size)
                outline = Self.highlight(found, size: size)
                guard let d = model.decoded, let bounds = VisionServices.maskBounds(found, imageSize: size) else {
                    throw VisionError.noSelection
                }
                // Objects' outlines are tight: grow them past their edges (and a little shadow).
                // (The picture is turned as shown: compare long sides.)
                let scale = max(d.pixelSize.width, d.pixelSize.height) / max(size.width, size.height)
                let grow = 0.02 * max(bounds.width, bounds.height) * scale + 0.003 * max(d.pixelSize.width, d.pixelSize.height)
                busy = false
                remove(RemovalMark(mask: sourceMask(found), grow: grow))
            } catch {
                busy = false
                outline = nil
                message = "Nothing to remove was found there. Paint over it instead."
            }
        }
    }

    /// Makes a removal (or a change) and adds it (`replacingLast`: in place of the last one, for Try Again).
    private func remove(_ mark: RemovalMark, replacingLast: Bool = false) {
        guard let d = model.decoded, d.url == model.currentURL else { return }
        if !method.isAvailable { method = .match }
        var earlier = allRemovals
        if replacingLast, !earlier.isEmpty { earlier.removeLast() }
        let method = method
        let seed = UInt64.random(in: 1...UInt64.max)
        let flag = CancelFlag()
        let relay = progress
        let prompt = promptText
        busy = true
        message = nil
        relay.value = 0
        task = Task {
            defer {
                busy = false
                relay.value = nil
                stroke = []
                outline = nil
            }
            do {
                let progress: @Sendable (Double) -> Bool = { fraction in
                    Task { @MainActor in if relay.value != nil { relay.value = fraction } }
                    return flag.isSet
                }
                var removal = try await withTaskCancellationHandler {
                    if let clone = mark.clone {
                        return try await ObjectRemover.clone(d, after: earlier, mask: mark.mask, offset: clone.offset, heal: clone.heal)
                    }
                    switch mark.change {
                    case let change? where change.color != nil:
                        return try await ObjectRemover.recolor(d, after: earlier, mask: mark.mask, reach: mark.reach, color: change.color!)
                    case let change?:
                        return try await ObjectRemover.remove(d, after: earlier, mask: mark.mask, grow: mark.grow, method: .generate, seed: seed,
                                                              prompt: change.description, keepShape: true, tint: change.tint, progress: progress)
                    case nil:
                        return try await ObjectRemover.remove(d, after: earlier, mask: mark.mask, grow: mark.grow, method: method, seed: seed,
                                                              prompt: prompt, progress: progress)
                    }
                } onCancel: {
                    flag.set()
                }
                guard !Task.isCancelled else { return }
                if mark.change != nil {
                    // A new change shows fully; one made over keeps the strength chosen.
                    if !replacingLast { strength = 1 }
                    removal.opacity = strength < 0.999 ? strength : nil
                    if mark.selection != nil, mark.selection === selection { selectionApplied = true }
                }
                if replacingLast, !removals.isEmpty {
                    removals.removeLast()
                    marks.removeLast()
                }
                removals.append(removal)
                marks.append(mark)
                undone = []
                await render()
            } catch {
                if Task.isCancelled || (error as? RemovalError).map({ if case .cancelled = $0 { true } else { false } }) == true { return }
                message = error.localizedDescription
            }
        }
    }

    private func tryAgain() {
        guard let mark = marks.last, !busy else { return }
        remove(mark, replacingLast: true)
    }

    private func undo() {
        guard !busy, let removal = removals.popLast(), let mark = marks.popLast() else { return }
        undone.append((removal, mark))
        message = nil
        // A change taken back leaves what it changed selected, to change some other way.
        if let selected = mark.selection { show(selected, reach: mark.shownReach, applied: false) }
        strength = removals.last?.opacity ?? 1
        // (With nothing left to compare, Original turns off: it can't be turned off once disabled.)
        if removals.isEmpty { showOriginal = false }
        Task { await render() }
    }

    private func redo() {
        guard !busy, let last = undone.popLast() else { return }
        removals.append(last.removal)
        marks.append(last.mark)
        message = nil
        if let selected = last.mark.selection { show(selected, reach: last.mark.shownReach, applied: true) }
        strength = last.removal.opacity ?? 1
        Task { await render() }
    }

    private func finish() {
        task?.cancel()
        if let url = model.currentURL, let d = model.decoded, !removals.isEmpty {
            model.finishRemovingObjects(removals, url: url, decoded: d, operation: mode == .change ? .changeObjects : mode == .clone ? .cloneHeal : .removeObjects)
        }
        model.activeTool = nil
    }

    // MARK: Clone & Heal

    /// The stroke painted with what's at `cloneOffset` from it: healed in, or copied as it is.
    private func cloneStroke() {
        guard let picture, let d = model.decoded, d.url == model.currentURL else { return stroke = [] }
        guard let offset = cloneOffset, let first = stroke.first else {
            stroke = []
            return message = "⌥-click where to copy from first."
        }
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        let points = stroke.map { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) }   // CG pixels, y up
        let diameter = strokeWidth * w
        guard let painted = Self.strokeMask(points, diameter: diameter, closed: false, width: picture.width, height: picture.height) else {
            return stroke = []
        }
        // A soft-edged brush.
        let size = CGSize(width: w, height: h)
        let soft = CIImage(cgImage: painted, options: [.colorSpace: NSNull()]).clampedToExtent()
            .applyingGaussianBlur(sigma: max(1, diameter * 0.08)).cropped(to: CGRect(origin: .zero, size: size))
        // How far away it's copied from, in the image's own pixels (turned and flipped as it's shown).
        let to = CGPoint(x: first.x * w, y: (1 - first.y) * h)
        let from = CGPoint(x: (first.x + offset.width) * w, y: (1 - first.y - offset.height) * h)
        let a = ObjectRemover.sourcePoint(to, shownWith: start, shown: size, size: d.pixelSize)
        let b = ObjectRemover.sourcePoint(from, shownWith: start, shown: size, size: d.pixelSize)
        remove(RemovalMark(mask: sourceMask(soft), grow: 0, clone: CloneStep(offset: CGVector(dx: b.x - a.x, dy: b.y - a.y), heal: heal)))
    }

    // MARK: Change Objects

    /// Adds what's under `p` (normalized, top-left origin) to the selection (`subtract`: takes it away): the
    /// object found there, or with Only That Color, the part of it that's the color clicked. Where no object is
    /// found (the sky, a wall), Only That Color takes that color anywhere in the picture.
    private func select(at p: CGPoint, subtract: Bool) {
        guard let picture else { return }
        let byColor = onlyThatColor
        let size = CGSize(width: picture.width, height: picture.height)
        let point = CGPoint(x: p.x, y: 1 - p.y)   // Vision: lower-left origin
        busy = true
        activity = "Finding what's there…"
        message = nil
        task = Task {
            defer {
                busy = false
                activity = nil
            }
            var found: CIImage?
            if #available(macOS 27, *), let refined = try? await VisionServices.objectMask(for: picture, included: [point], excluded: []) {
                found = refined
            } else {
                found = try? await VisionServices.instanceMask(for: picture, at: point)
            }
            guard !Task.isCancelled else { return }
            do {
                if let object = found {
                    let mask = Self.fitted(object, to: size)
                    try add(byColor ? await Self.byColor(picture, mask: mask, seed: p) : mask, in: mask, subtract: subtract)
                } else if byColor {
                    let everywhere = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
                    try add(await Self.byColor(picture, mask: everywhere, seed: p), subtract: subtract)
                } else {
                    throw VisionError.noSelection
                }
            } catch {
                message = "Nothing was found there. Paint over it instead."
            }
        }
    }

    /// Adds what was painted to the selection (`subtract`: takes it away; a loop, everything inside it). With
    /// Only That Color, adding takes only what's the color most of the stroke covers.
    private func selectStroke(subtract: Bool) {
        guard let picture else { return }
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        let points = stroke.map { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) }   // CG pixels, y up
        let diameter = strokeWidth * w
        guard let painted = Self.strokeMask(points, diameter: diameter, closed: Self.isLoop(points, diameter: diameter),
                                            width: picture.width, height: picture.height) else { return stroke = [] }
        let byColor = onlyThatColor && !subtract
        busy = true
        activity = "Finding what's there…"
        message = nil
        task = Task {
            defer {
                busy = false
                activity = nil
                stroke = []
            }
            do {
                let mask = CIImage(cgImage: painted)
                try add(byColor ? await Self.byColor(picture, mask: mask, seed: nil) : mask, in: mask, subtract: subtract)
            } catch {
                message = "Nothing to change was found there."
            }
        }
    }

    /// `mask` (the picture's size), found in `object` (nil: itself), added to the selection, or taken from it.
    /// After a change, it starts a new one.
    private func add(_ mask: CIImage, in object: CIImage? = nil, subtract: Bool) throws {
        guard let picture else { return }
        let rect = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        func combined(_ old: CIImage?, _ new: CIImage) -> CIImage? {
            guard let old, !selectionApplied else { return subtract ? nil : new }
            return subtract
                ? old.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask.applyingFilter("CIColorInvert")])
                : new.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: old])
        }
        guard let selected = combined(selection, mask) else { return }
        guard let flat = ObjectRemover.flattened(selected, in: rect) else { throw VisionError.noSelection }
        guard VisionServices.maskBounds(flat, imageSize: rect.size) != nil else {
            clearSelection()
            if !subtract { throw VisionError.noSelection }
            return
        }
        show(flat, reach: combined(reach, object ?? mask).flatMap { ObjectRemover.flattened($0, in: rect) } ?? flat, applied: false)
    }

    private func show(_ selected: CIImage, reach within: CIImage?, applied: Bool) {
        selection = selected
        reach = within
        selectionApplied = applied
        selectionShown = Self.highlight(selected, size: selected.extent.size, edged: true)
    }

    private func clearSelection() {
        selection = nil
        reach = nil
        selectionShown = nil
        selectionApplied = false
    }

    /// Change (or Return): what's selected made what `changeText` says. Again on the same selection, the last
    /// change is made over.
    private func applyChange() {
        guard !busy else { return }
        let text = changeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selection else { return message = "Click or paint over what to change first." }
        guard !text.isEmpty else { return message = "Say what it should be first, such as “blue” or “a red plaid shirt”." }
        guard let d = model.decoded, d.url == model.currentURL else { return }
        let request = ChangeRequest.parse(text)
        guard request.color != nil || GenerativeModel.isInstalled else {
            return message = GenerativeModel.isSupported
                ? "“\(text)” is more than a color, so it's painted by \(GenerativeModel.displayName): click Get the Model… below. Or say just a color."
                : "Only colors can be changed on this Mac, such as “blue”."
        }
        appliedText = text
        let grow = max(2, 0.002 * max(d.pixelSize.width, d.pixelSize.height))
        remove(RemovalMark(mask: sourceMask(selection), grow: grow, selection: selection, shownReach: reach,
                           reach: reach.map(sourceMask), change: request),
               replacingLast: selectionApplied && !removals.isEmpty)
    }

    private func setStrength(_ value: Double) {
        strength = value
        guard !removals.isEmpty else { return }
        removals[removals.count - 1].opacity = value < 0.999 ? value : nil
        // (One render at a time while the slider moves, then one for where it stopped.)
        guard !rendering else { return renderAgain = true }
        rendering = true
        Task {
            repeat {
                renderAgain = false
                await render()
            } while renderAgain
            rendering = false
        }
    }

    /// The part of `mask` that's the color at `seed` (or most of it), worked out off the main thread.
    @concurrent
    nonisolated private static func byColor(_ picture: CGImage, mask: CIImage, seed: CGPoint?) async throws -> CIImage {
        try ObjectRemover.selectByColor(in: CIImage(cgImage: picture), mask: mask, seed: seed)
    }

    /// A mask Vision made, moved to the origin and scaled to `size`.
    private static func fitted(_ mask: CIImage, to size: CGSize) -> CIImage {
        mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / mask.extent.width, y: size.height / mask.extent.height))
    }

    // MARK: Marks

    private func sourceMask(_ mask: CIImage) -> CIImage {
        ObjectRemover.sourceMask(mask, shownWith: start, size: model.decoded?.pixelSize ?? mask.extent.size)
    }

    /// A stroke (`points` in pixels, y up) as a mask the picture's size; a loop also takes everything inside it.
    private static func strokeMask(_ points: [CGPoint], diameter: CGFloat, closed: Bool, width: Int, height: Int) -> CGImage? {
        guard let first = points.first,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let path = CGMutablePath()
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        if points.count == 1 { path.addLine(to: first) }
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(max(diameter, 1))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        if closed {
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(path)
            ctx.closePath()
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    /// A stroke that comes back around to where it started and encloses more than it paints: circling something.
    private static func isLoop(_ points: [CGPoint], diameter: CGFloat) -> Bool {
        guard points.count > 8, let first = points.first, let last = points.last else { return false }
        var length: CGFloat = 0
        var area: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            length += hypot(b.x - a.x, b.y - a.y)
            area += a.x * b.y - b.x * a.y
        }
        area += last.x * first.y - first.x * last.y
        let gap = hypot(last.x - first.x, last.y - first.y)
        return length > 6 * diameter && gap < max(1.5 * diameter, 0.12 * length) && abs(area) / 2 > length * diameter
    }

    /// A clicked object's outline, tinted, for showing over it while it's removed; `edged`, with a line around
    /// it, so a selection is clear on any color.
    private static func highlight(_ mask: CIImage, size: CGSize, edged: Bool = false) -> CGImage? {
        let rect = CGRect(origin: .zero, size: size)
        let tint = CIImage(color: CIColor(red: 1, green: 0.3, blue: 0.4, alpha: 0.5)).cropped(to: rect)
        var shown = tint.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
            kCIInputMaskImageKey: mask,
        ])
        if edged {
            let edge = mask.applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: max(1.5, max(size.width, size.height) / 900)])
            shown = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9)).cropped(to: rect).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: shown,
                kCIInputMaskImageKey: edge,
            ])
        }
        return ImageDecoder.ciContext.createCGImage(shown, from: rect)
    }
}

/// Where Clone & Heal copies from: a ring with a cross.
private struct CloneMarker: View {
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 1.5).frame(width: 18, height: 18)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 13))
                p.addLine(to: CGPoint(x: 26, y: 13))
                p.move(to: CGPoint(x: 13, y: 0))
                p.addLine(to: CGPoint(x: 13, y: 26))
            }
            .stroke(lineWidth: 1)
        }
        .frame(width: 26, height: 26)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 1)
    }
}

/// A gentle pulse while a mark is being removed.
private struct Pulsing: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.35 : 1)
            .animation(active ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = active }
            .onChange(of: active) { dim = active }
    }
}
