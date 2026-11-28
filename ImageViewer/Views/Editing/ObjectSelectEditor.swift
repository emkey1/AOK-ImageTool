import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// Select Object: click objects to select them (Vision), paint to add what a click missed or take away what it
/// shouldn't have, on the picture as it is on screen; then cut the selection out, copy or save it, or adjust
/// it on its own. Opened on a picture that's cut out already, or on an object Adjust Objects is adjusting, it
/// starts from that selection, to touch it up.
struct ObjectSelectEditor: View {
    /// Opened from Adjust Objects, to adjust what's selected (its main button, and all it offers).
    var toAdjust = false
    @Environment(ViewerModel.self) private var model
    /// The picture as shown (up to 2048 pixels), and the edits it's shown with (without the cutout this
    /// changes).
    @State private var picture: CGImage?
    @State private var shown = EditState.identity
    @State private var selection: ObjectSelection?
    /// The picture with the selection shown on it (nil: nothing selected), and the scale its line was drawn for.
    @State private var display: CGImage?
    @State private var displayScale: CGFloat = 1
    @State private var displayTask: Task<Void, Never>?
    @State private var look = Prefs.selectionLook
    @State private var brush = Prefs.selectionBrush
    /// The stroke being painted (normalized in the picture, top-left origin), its width (normalized to the
    /// picture's width) and whether it takes away; and the one just painted, shown until the selection with it is.
    @State private var stroke: [CGPoint] = []
    @State private var strokeWidth: CGFloat = 0
    @State private var strokeSubtracts = false
    @State private var painted: [CGPoint] = []
    @State private var hover: CGPoint?
    @State private var busy = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    /// It opened on a selection there already was (what's cut out, an adjusted object's): `editing` is that
    /// object, when it's one of Adjust Objects'.
    @State private var startedSelected = false
    @State private var editing: AdjustTarget?
    /// Zoom, relative to the picture fitting the view (1), and how far it's moved (points).
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var zoomStart: CGFloat?
    @State private var viewport: CGSize = .zero
    @State private var scrollMonitor: Any?

    static let maxZoom: CGFloat = 8
    private static let addColor = Color(red: 0.25, green: 0.6, blue: 1)
    private static let takeColor = Color(red: 1, green: 0.3, blue: 0.4)

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color(white: 0.07)
                    if let picture {
                        let rect = shownRect(fitted: Self.fittedRect(picture, in: geo.size))
                        if look == .alone, display != nil {
                            CheckerboardFill()
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }
                        Image(decorative: display ?? picture, scale: 1)
                            .resizable()
                            .interpolation(zoom > 1.5 ? .medium : .high)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        strokeOverlay(in: rect)
                        if let selection, look != .alone {
                            ForEach(Array(selection.marks.enumerated()), id: \.offset) { _, mark in
                                marker(mark, in: rect)
                            }
                        }
                        if let hover, !busy, rect.contains(hover) {
                            Circle()
                                .strokeBorder(.white, lineWidth: 1.5)
                                .shadow(color: .black.opacity(0.6), radius: 1)
                                .frame(width: brush, height: brush)
                                .position(hover)
                                .allowsHitTesting(false)
                        }
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(paintGesture(in: rect))
                            .simultaneousGesture(pinchGesture)
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                // (The Guide's screenshots set where the pointer is themselves.)
                                guard DebugHooks.scene == nil else { return }
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
        .task { await open() }
        .onAppear {
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
            displayTask?.cancel()
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCommit)) { note in
            guard note.object as AnyObject? === model, !busy, selection?.isEmpty == false else { return }
            toAdjust ? adjust() : cutOut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCancel)) { note in
            guard note.object as AnyObject? === model else { return }
            // Esc stops a search for what's under a click; otherwise it closes the tool.
            if busy { task?.cancel() } else { cancel() }
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
        .onReceive(NotificationCenter.default.publisher(for: .toolZoom)) { note in
            guard note.object as AnyObject? === model, let step = note.userInfo?["step"] as? Int else { return }
            step == 0 ? setZoom(1, about: nil) : setZoom(zoom * (step > 0 ? 1.5 : 1 / 1.5), about: hover)
        }
    }

    // MARK: Opening

    /// The picture as it's shown, and what's selected to begin with: what's cut out now (the whole picture is
    /// shown, to select in), or the adjusted object whose selection this changes.
    private func open() async {
        // (The image may still be loading, just after moving to it.)
        for _ in 0..<200 where model.decoded?.url != model.currentURL { try? await Task.sleep(for: .milliseconds(50)) }
        guard let d = model.decoded, d.url == model.currentURL else { return }
        var e = model.currentEdits
        try? await MaskStore.shared.prepare(e, for: d)
        var initial: CIImage?
        if toAdjust {
            editing = model.selectionEdit
            initial = editing.flatMap { SelectionStore.load($0.mask) }
        } else if let cutout = e.cutout {
            initial = MaskStore.shared.mask(for: cutout, url: d.url)
            if initial != nil { e.removeCutout() }
        }
        shown = e
        guard let output = await EditRenderer.shared.render(d, edits: e, maxDimension: 2048, stage: .full)?.image else {
            message = "The picture couldn't be shown."
            return
        }
        var start = ObjectSelection(width: output.width, height: output.height)
        if let initial {
            let over = EditRenderer.shared.shownMask(initial, shownWith: e, size: d.pixelSize)
            let w = output.width, h = output.height
            let bytes = await Task.detached(priority: .userInitiated) { ObjectSelection.bytes(of: over, width: w, height: h) }.value
            start = ObjectSelection(width: w, height: h, mask: bytes)
            startedSelected = !start.isEmpty
        }
        picture = output
        selection = start
        refresh()
        if DebugHooks.scene != nil { showSceneForGuide() }
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
        let rect = shownRect(fitted: fitted)
        let newZoom = min(max(z, 1), Self.maxZoom)
        let p = point ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let n = CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
        let w = fitted.width * newZoom, h = fitted.height * newZoom
        let offset = CGSize(width: p.x - n.x * w - (fitted.midX - w / 2), height: p.y - n.y * h - (fitted.midY - h / 2))
        zoom = newZoom
        pan = Self.clamped(offset, fitted: fitted, zoom: newZoom, view: viewport)
        // (The line around the selection is drawn for the zoom: once that's changed enough, it's drawn again.)
        let scale = pixelsPerPoint
        if display != nil, scale < displayScale / 1.4 || scale > displayScale * 1.4 { refresh() }
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

    /// How many of the picture's pixels make a point on screen, as it's zoomed now.
    private var pixelsPerPoint: CGFloat {
        guard let picture, viewport.width > 0 else { return 1 }
        let fitted = Self.fittedRect(picture, in: viewport)
        return fitted.width > 0 ? CGFloat(picture.width) / (fitted.width * zoom) : 1
    }

    private func path(_ points: [CGPoint], in rect: CGRect) -> Path {
        Path { path in
            let points = points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            if points.count == 1 {
                path.move(to: points[0])
                path.addLine(to: points[0])
            } else {
                path.addLines(points)
            }
        }
    }

    /// The stroke being painted (and the last one, until the selection shows it): blue where it adds, red where
    /// it takes away.
    @ViewBuilder
    private func strokeOverlay(in rect: CGRect) -> some View {
        let points = stroke.isEmpty ? painted : stroke
        if !points.isEmpty {
            path(points, in: rect)
                .stroke((strokeSubtracts ? Self.takeColor : Self.addColor).opacity(0.55),
                        style: StrokeStyle(lineWidth: strokeWidth * rect.width, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
        }
    }

    private func marker(_ mark: ObjectSelection.Mark, in rect: CGRect) -> some View {
        Image(systemName: mark.added ? "plus" : "minus")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(mark.added ? Color.green : Color.red, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .shadow(radius: 2)
            .position(x: rect.minX + mark.point.x * rect.width, y: rect.minY + (1 - mark.point.y) * rect.height)
            .allowsHitTesting(false)
    }

    private func paintGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !busy, picture != nil else { return }
                hover = value.location
                let p = CGPoint(x: (value.location.x - rect.minX) / rect.width, y: (value.location.y - rect.minY) / rect.height)
                if stroke.isEmpty {
                    message = nil
                    painted = []
                    strokeWidth = brush / rect.width
                    strokeSubtracts = NSEvent.modifierFlags.contains(.option)
                }
                stroke.append(p)
            }
            .onEnded { value in
                guard !busy, !stroke.isEmpty else { return }
                let travel = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                if travel < 3, stroke.count < 4, let p = stroke.first {
                    stroke = []
                    // (A click beside the picture, in the margin around it, isn't on anything.)
                    guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                    click(at: p, subtract: strokeSubtracts)
                } else {
                    paintStroke()
                }
            }
    }

    // MARK: Bar

    private var hintText: String {
        if let message { return message }
        if busy { return "Finding what's there…" }
        guard let selection, !selection.isEmpty else {
            return (toAdjust ? "Click the object to adjust, or paint over it." : "Click an object to select it, or paint over it.")
                + " Pinch or ⌘-scroll to zoom in."
        }
        if look == .alone { return "What's selected, on its own. Switch to Dimmed or Tinted to paint in what's missing." }
        if startedSelected, !selection.canUndo {
            return (editing != nil ? "This is what's being adjusted." : "This is what's cut out now.")
                + " Paint over what's missing to add it; ⌥-paint takes away. Clicking finds whole objects."
        }
        return "Selected. Paint over what's missing to add it, or click it; with ⌥, they take away. ⌘Z steps back."
    }

    private var hint: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Text(hintText)
                .font(.callout)
                .lineLimit(2)
            if busy {
                Button("Stop") { task?.cancel() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassBackground(in: .capsule)
    }

    private var nothingSelected: Bool { selection?.isEmpty ?? true }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker("Show", selection: Binding(get: { look }, set: { setLook($0) })) {
                    ForEach(ObjectSelection.Look.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .help("How the selection shows: the rest of the picture dimmed, the selection tinted, or the selection on its own, as cutting it out leaves it")
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
                Slider(value: Binding(get: { brush }, set: { setBrush($0) }), in: 4...160) { Text("Brush") }
                    .frame(width: 140)
                    .help("Brush size ([ and ] change it). Paint to add to the selection; hold ⌥ to take away.")
            }
            HStack(spacing: 10) {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(busy || selection?.canUndo != true)
                    .help("Take back the last click or stroke (⌘Z)")
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(busy || selection?.canRedo != true)
                    .help("Redo (⇧⌘Z)")
                Button("Clear") { clear() }
                    .disabled(busy || nothingSelected)
                    .help("Select nothing, to start again")
                Spacer()
                if toAdjust {
                    Button("Cancel") { cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button(editing != nil ? "Done" : "Adjust") { adjust() }
                        .prominentButtonStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || nothingSelected)
                        .help(editing != nil ? "Adjust what's selected now in place of what was"
                                             : "Adjust the selection's light, color and detail on its own, in the Adjust panel")
                } else {
                    Button("Copy") { copy() }
                        .disabled(busy || nothingSelected)
                    Button("Save as PNG…") { save() }
                        .disabled(busy || nothingSelected)
                    Button("Adjust") { adjust() }
                        .disabled(busy || nothingSelected)
                        .help("Adjust the selection's light, color and detail on its own (Adjust Objects)")
                    Button("Cancel") { cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button("Cut Out") { cutOut() }
                        .prominentButtonStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || nothingSelected)
                        .help("Keep only the selection (non-destructive)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Selecting

    /// The picture with the selection on it, drawn again (off the main thread; the latest wins).
    private func refresh() {
        displayTask?.cancel()
        guard let picture, let selection, !selection.isEmpty, let mask = selection.image else {
            display = nil
            painted = []
            return
        }
        let look = look, scale = pixelsPerPoint
        displayTask = Task {
            let image = await Task.detached(priority: .userInitiated) {
                ObjectSelection.shown(picture, mask: mask, look: look, pixelsPerPoint: scale)
            }.value
            guard !Task.isCancelled else { return }
            display = image
            displayScale = scale
            painted = []
        }
    }

    private func setLook(_ value: ObjectSelection.Look) {
        look = value
        // (Alone is for checking, not for selecting in: the tool opens next time as it was before that.)
        if value != .alone { Prefs.set(value.rawValue, PrefKey.selectionLook) }
        refresh()
    }

    private func setBrush(_ value: Double) {
        brush = min(max(value, 4), 160)
        Prefs.set(brush, PrefKey.selectionBrush)
    }

    /// A click at `p` (normalized, top-left origin): the object found there added to the selection, or with
    /// `subtract` left out of it. On macOS 27 the clicks are worked out together, each refining what the ones
    /// before found; earlier, each finds the object under it.
    private func click(at p: CGPoint, subtract: Bool) {
        guard let picture, let before = selection else { return }
        let point = CGPoint(x: p.x, y: 1 - p.y)   // Vision: lower-left origin
        let w = before.width, h = before.height
        busy = true
        message = nil
        task = Task {
            defer { busy = false }
            func bytes(_ mask: CIImage) async -> [UInt8] {
                await Task.detached(priority: .userInitiated) { ObjectSelection.bytes(of: mask, width: w, height: h) }.value
            }
            // The clicks together (one to leave out needs one to select first, to refine).
            if #available(macOS 27, *), !subtract || !before.included.isEmpty {
                let included = before.included + (subtract ? [] : [point]), excluded = before.excluded + (subtract ? [point] : [])
                if let found = try? await VisionServices.objectMask(for: picture, included: included, excluded: excluded) {
                    let result = await bytes(found)
                    guard !Task.isCancelled, var s = selection else { return }
                    s.refine(result, adding: point, exclude: subtract)
                    selection = s
                    refresh()
                    return
                }
            }
            // Otherwise the object found there on its own, added or taken away.
            guard !Task.isCancelled else { return }
            var object: CIImage?
            if #available(macOS 27, *) { object = try? await VisionServices.objectMask(for: picture, included: [point], excluded: []) }
            if object == nil { object = try? await VisionServices.instanceMask(for: picture, at: point) }
            guard !Task.isCancelled else { return }
            guard let object else {
                message = "Nothing was found there. Paint over it instead."
                return
            }
            let result = await bytes(object)
            guard !Task.isCancelled, var s = selection else { return }
            if s.take(result, subtract: subtract, at: point) {
                selection = s
                refresh()
            } else {
                message = subtract ? "What's there isn't selected." : "That's selected already. Paint over what's missing to add it."
            }
        }
    }

    /// What was just painted, added to the selection or (with ⌥) taken from it.
    private func paintStroke() {
        guard var s = selection else { return stroke = [] }
        let w = CGFloat(s.width), h = CGFloat(s.height)
        let points = stroke.map { CGPoint(x: $0.x * w, y: $0.y * h) }
        painted = stroke
        stroke = []
        if s.paint(points, diameter: strokeWidth * w, subtract: strokeSubtracts) {
            selection = s
            refresh()
        } else {
            painted = []
            if strokeSubtracts { message = "Nothing is selected there to take away." }
        }
    }

    private func undo() {
        guard !busy, var s = selection, s.undo() else { return }
        selection = s
        message = nil
        refresh()
    }

    private func redo() {
        guard !busy, var s = selection, s.redo() else { return }
        selection = s
        message = nil
        refresh()
    }

    private func clear() {
        guard var s = selection else { return }
        s.clear()
        selection = s
        message = nil
        refresh()
    }

    private func cancel() {
        toAdjust ? model.cancelSelectingToAdjust() : (model.activeTool = nil)
    }

    // MARK: What's done with it

    /// The selection on the image's own pixels (where a cutout and an adjusted object live, whatever the
    /// picture's turned, straightened or cropped to).
    private func sourceMask(_ d: DecodedImage) -> CIImage? {
        guard let selection, !selection.isEmpty, let mask = selection.image else { return nil }
        return EditRenderer.shared.sourceMask(mask, shownWith: shown, size: d.pixelSize)
    }

    private func cutOut() {
        guard let d = model.decoded, let mask = sourceMask(d) else { return }
        // (Opened on what's cut out and left as it was: nothing to do.)
        if startedSelected, selection?.canUndo != true { return model.activeTool = nil }
        let id = MaskStore.shared.keepObjectMask(mask, size: d.pixelSize)
        model.updateEdits("Cut Out Object") { $0.cutout = .object(id) }
        model.activeTool = nil
    }

    /// Adjust: the selection becomes the object Adjust Objects adjusts (or, changing the selection of one it's
    /// adjusting already, takes the place of that one's).
    private func adjust() {
        guard let d = model.decoded, let mask = sourceMask(d) else { return }
        do {
            if let editing {
                if selection?.canUndo == true {
                    try model.replaceSelection(of: editing, with: mask, size: d.pixelSize)
                } else {
                    model.cancelSelectingToAdjust()
                }
            } else {
                try model.adjustSelection(mask, of: d.url, size: d.pixelSize)
            }
        } catch {
            message = "The selection couldn't be kept: \(error.localizedDescription)"
        }
    }

    /// The picture as shown, at full size (what Copy and Save as PNG cut the selection from).
    private func shownPicture(_ d: DecodedImage) async throws -> CGImage {
        guard let picture = await EditRenderer.shared.render(d, edits: shown, maxDimension: nil, stage: .full)?.image else {
            throw VisionError.noSubject
        }
        return picture
    }

    private func copy() {
        guard let mask = selection?.image, let d = model.decoded else { return }
        Task {
            do {
                try await model.intelligence.copyCutout(of: shownPicture(d), mask: mask)
                model.showToast("Copied object", systemImage: "doc.on.clipboard")
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let mask = selection?.image, let d = model.decoded else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = d.url.deletingPathExtension().lastPathComponent + " (Object).png"
        panel.directoryURL = d.url.deletingLastPathComponent()
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let data = try await model.intelligence.cutoutPNG(of: shownPicture(d), mask: mask)
                    try data.write(to: url)
                    if url.deletingLastPathComponent().standardizedFileURL == model.folderURL, let item = FolderScanner.item(for: url) {
                        model.insertItem(item, select: false)
                    }
                    model.showToast("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle")
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        if let window = model.window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    // MARK: The Guide's screenshots

    /// `-debugScene select`: the fox clicked (as a click selects it), the brush beside it; `select-alone`: shown
    /// on its own; `select-touchup`: an ear painted out, as a click might have missed it, and half painted back.
    private func showSceneForGuide() {
        guard let scene = DebugHooks.scene, scene.hasPrefix("select"), scene != "select-adjust", let picture else { return }
        if scene == "select-alone" { look = .alone }
        click(at: CGPoint(x: 0.74, y: 0.42), subtract: false)
        Task {
            for _ in 0..<200 where busy { try? await Task.sleep(for: .milliseconds(100)) }
            guard viewport.width > 0 else { return }
            let rect = shownRect(fitted: Self.fittedRect(picture, in: viewport))
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
            hover = at(0.6, 0.5)
            guard scene == "select-touchup", var s = selection else { return }
            let w = CGFloat(s.width), h = CGFloat(s.height)
            s.paint([CGPoint(x: 0.6 * w, y: 0.1 * h), CGPoint(x: 0.68 * w, y: 0.22 * h)], diameter: 0.07 * w, subtract: true)
            selection = s
            refresh()
            strokeWidth = 0.05
            strokeSubtracts = false
            stroke = [CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.62, y: 0.13), CGPoint(x: 0.64, y: 0.16)]
            hover = at(0.64, 0.16)
            setBrush(0.05 * rect.width)
        }
    }
}
