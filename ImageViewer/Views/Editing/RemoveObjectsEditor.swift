import CoreImage
import SwiftUI

/// What one removal takes away: a mask in the image's own pixel space (white = remove), and how far past it
/// to fill.
private struct RemovalMark: @unchecked Sendable {
    let mask: CIImage
    let grow: CGFloat
}

/// Progress of the removal being made, updated from the background.
@MainActor @Observable
private final class RemovalProgress {
    var value: Double?
}

/// Remove Objects: paint over something, click it or circle it, and it's removed, filled in from what's around
/// it. Each removal is a step of its own (⌘Z takes it back, Try Again fills it differently); Done saves the
/// result as a copy, or as an edit.
struct RemoveObjectsEditor: View {
    @Environment(ViewerModel.self) private var model
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
    /// What Generate paints in place of what's marked.
    @State private var promptText = ""

    private static let markColor = Color(red: 1, green: 0.3, blue: 0.4)

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color(white: 0.07)
                    if let shown = showOriginal ? original : picture {
                        let size = CGSize(width: shown.width, height: shown.height)
                        let fitted = fitRect(size, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 30, dy: 30))
                        Image(decorative: shown, scale: 1)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX, y: fitted.midY)
                        markOverlay(in: fitted)
                        if let hover, !busy, !showOriginal, fitted.contains(hover) {
                            Circle()
                                .strokeBorder(.white, lineWidth: 1.5)
                                .shadow(color: .black.opacity(0.6), radius: 1)
                                .frame(width: brush, height: brush)
                                .position(hover)
                                .allowsHitTesting(false)
                        }
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(paintGesture(in: fitted))
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                if case .active(let p) = phase { hover = p } else { hover = nil }
                            }
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    hint.position(x: geo.size.width / 2, y: 20)
                }
            }
            controls
        }
        .onAppear {
            start = model.currentEdits
            if !method.isAvailable { method = .match }
            Task { await render(initial: true) }
        }
        .onDisappear { task?.cancel() }
        .onChange(of: ModelDownloads.shared.installCount) {
            eraseInstalled = RemovalModel.isInstalled
            if eraseInstalled && eraseWhenInstalled {
                eraseWhenInstalled = false
                setMethod(.erase)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCommit)) { note in
            if note.object as AnyObject? === model, !busy { finish() }
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

    @ViewBuilder
    private func markOverlay(in fitted: CGRect) -> some View {
        if !stroke.isEmpty {
            Path { path in
                let points = stroke.map { CGPoint(x: fitted.minX + $0.x * fitted.width, y: fitted.minY + $0.y * fitted.height) }
                if points.count == 1 {
                    path.move(to: points[0])
                    path.addLine(to: points[0])
                } else {
                    path.addLines(points)
                }
            }
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
                if stroke.isEmpty {
                    outline = nil
                    message = nil
                    strokeWidth = brush / fitted.width
                }
                stroke.append(CGPoint(x: (value.location.x - fitted.minX) / fitted.width, y: (value.location.y - fitted.minY) / fitted.height))
            }
            .onEnded { value in
                guard !busy, !stroke.isEmpty else { return }
                let travel = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                if travel < 3, stroke.count < 4, let p = stroke.first {
                    stroke = []
                    removeObject(at: p)
                } else {
                    removeStroke()
                }
            }
    }

    // MARK: Bar

    private var hintText: String {
        if let message { return message }
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
            return "Paint over what to remove, or click it. Circle something to remove all of it."
                + (eraseInstalled || !GenerativeModel.isSupported ? "" : " (Using Match Photo: for Erase, the best fill, click Get the Model for Erase… below.)")
        }
        return "Removed. Paint or click to remove more; Try Again fills it differently, ⌘Z takes it back."
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
                Picker("Fill", selection: Binding(get: { method }, set: { setMethod($0) })) {
                    ForEach(RemovalMethod.allCases) { m in
                        Text(m.title).tag(m)
                            .selectionDisabled(!m.isAvailable)
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
                Spacer()
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
                Button("Try Again") { tryAgain() }
                    .disabled(busy || removals.isEmpty)
                    .help("Remove the last one again, filled differently (with the Fill chosen now)")
                Toggle(isOn: $showOriginal) { Label("Original", systemImage: "eye") }
                    .toggleStyle(.button)
                    .disabled(busy || removals.isEmpty)
                    .help("Compare with the picture before these removals")
                Spacer()
                Button("Cancel") { model.activeTool = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { finish() }
                    .prominentButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Actions

    private func setMethod(_ m: RemovalMethod) {
        guard m.isAvailable else { return }
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
        guard let output = await EditRenderer.shared.render(d, edits: e, maxDimension: 2048, stage: .full) else { return }
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
                found = found.transformed(by: CGAffineTransform(translationX: -found.extent.minX, y: -found.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: size.width / found.extent.width, y: size.height / found.extent.height))
                outline = Self.highlight(found, size: size)
                guard let d = model.decoded, let bounds = VisionServices.maskBounds(found, imageSize: size) else {
                    throw VisionError.noSelection
                }
                // Objects' outlines are tight: grow them past their edges (and a little shadow).
                let scale = d.pixelSize.width / size.width
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

    /// Makes a removal and adds it (`replacingLast`: in place of the last one, for Try Again).
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
                let removal = try await withTaskCancellationHandler {
                    try await ObjectRemover.remove(d, after: earlier, mask: mark.mask, grow: mark.grow, method: method, seed: seed,
                                                   prompt: prompt, progress: { fraction in
                        Task { @MainActor in if relay.value != nil { relay.value = fraction } }
                        return flag.isSet
                    })
                } onCancel: {
                    flag.set()
                }
                guard !Task.isCancelled else { return }
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
        Task { await render() }
    }

    private func redo() {
        guard !busy, let last = undone.popLast() else { return }
        removals.append(last.removal)
        marks.append(last.mark)
        message = nil
        Task { await render() }
    }

    private func finish() {
        task?.cancel()
        if let url = model.currentURL, let d = model.decoded, !removals.isEmpty {
            model.finishRemovingObjects(removals, url: url, decoded: d)
        }
        model.activeTool = nil
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

    /// A clicked object's outline, tinted, for showing over it while it's removed.
    private static func highlight(_ mask: CIImage, size: CGSize) -> CGImage? {
        let rect = CGRect(origin: .zero, size: size)
        let tint = CIImage(color: CIColor(red: 1, green: 0.3, blue: 0.4, alpha: 0.5)).cropped(to: rect)
        let shown = tint.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
            kCIInputMaskImageKey: mask,
        ])
        return ImageDecoder.ciContext.createCGImage(shown, from: rect)
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
