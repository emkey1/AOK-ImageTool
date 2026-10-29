import SwiftUI

enum AspectPreset: String, CaseIterable, Identifiable {
    case freeform, original, square, r16x9, r4x3, r3x2, r5x4, r7x5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeform: "Freeform"
        case .original: "Original"
        case .square: "Square"
        case .r16x9: "16:9"
        case .r4x3: "4:3"
        case .r3x2: "3:2"
        case .r5x4: "5:4"
        case .r7x5: "7:5"
        }
    }

    /// Width / height in pixels, nil when unconstrained.
    func ratio(imageSize: CGSize, portrait: Bool) -> CGFloat? {
        let r: CGFloat? = switch self {
        case .freeform: nil
        case .original: imageSize.width / max(imageSize.height, 1)
        case .square: 1
        case .r16x9: 16 / 9
        case .r4x3: 4 / 3
        case .r3x2: 3 / 2
        case .r5x4: 5 / 4
        case .r7x5: 7 / 5
        }
        guard let r else { return nil }
        if self == .original || self == .square { return r }
        return portrait ? 1 / r : r
    }
}

/// A low-resolution Extend fill shown while the frame is adjusted: a quick content-aware one, or (for
/// Generate) the generated one, which Done then keeps.
private struct PreviewFill {
    let canvas: CGRect
    let image: CGImage
    /// Method, prompt and seed it was made with.
    let key: String
    let generated: Bool
    /// For a scanned print, the picture inside its border: the photo shows only there, the fill elsewhere.
    var content: CGRect?
}

/// Progress of the generated preview, updated from the background.
@MainActor @Observable
private final class GenerationProgress {
    var value: Double?
}

struct CropEditor: View {
    @Environment(ViewerModel.self) private var model
    @State private var working = EditState()
    @State private var base: CGImage?
    @State private var baseRevision = 0
    @State private var aspect: AspectPreset = .freeform
    @State private var portrait = false
    @State private var renderTask: Task<Void, Never>?
    @State private var busy = false
    @State private var extending = false
    @State private var preview: PreviewFill?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewing = false
    @State private var generation = GenerationProgress()
    @State private var promptText = ""
    /// Apple Intelligence's description of the photo's setting, which Generate continues when nothing's typed.
    @State private var settingText: String?
    @State private var applied = false
    @State private var modelInstalled = GenerativeModel.isInstalled
    /// The model is downloading for Generate, which is chosen once it's installed.
    @State private var generateWhenInstalled = false

    private static let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// How far Extend can reach past each edge, as a fraction of the image.
    static let extendReach: CGFloat = 0.35

    /// Where the crop may go: the image, or (extending) the image plus the reach around it.
    private var bounds: CGRect {
        extending ? Self.fullRect.insetBy(dx: -Self.extendReach, dy: -Self.extendReach) : Self.fullRect
    }

    private var imageSize: CGSize {
        base.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1, height: 1)
    }

    /// Normalized-space aspect (nw / nh) for the current preset.
    private var normalizedAspect: CGFloat? {
        guard let r = aspect.ratio(imageSize: imageSize, portrait: portrait) else { return nil }
        return r * imageSize.height / max(imageSize.width, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color(white: 0.07)
                    if let base {
                        let b = bounds
                        let boundsFrame = fitRect(CGSize(width: imageSize.width * b.width, height: imageSize.height * b.height),
                                                  in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 36, dy: 36))
                        let fitted = CGRect(x: boundsFrame.minX - b.minX * boundsFrame.width / b.width,
                                            y: boundsFrame.minY - b.minY * boundsFrame.height / b.height,
                                            width: boundsFrame.width / b.width,
                                            height: boundsFrame.height / b.height)
                        let crop = working.crop ?? Self.fullRect
                        if extending, working.cropExtendsBeyondImage {
                            // Not yet filled: a checkerboard, with the preview fill on top once it's ready.
                            let cropFrame = Self.viewRect(crop, in: fitted)
                            CheckerboardFill()
                                .frame(width: cropFrame.width, height: cropFrame.height)
                                .position(x: cropFrame.midX, y: cropFrame.midY)
                            if let preview, preview.key == previewKey, preview.canvas.insetBy(dx: -0.002, dy: -0.002).contains(crop) {
                                let pf = Self.viewRect(preview.canvas, in: fitted)
                                Image(decorative: preview.image, scale: 1)
                                    .resizable()
                                    .frame(width: pf.width, height: pf.height)
                                    .position(x: pf.midX, y: pf.midY)
                            }
                        }
                        Image(decorative: base, scale: 1)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .mask { pictureMask(size: fitted.size) }
                            .position(x: fitted.midX, y: fitted.midY)
                        CropOverlay(crop: Binding(get: { working.crop ?? Self.fullRect }, set: { working.crop = $0 }),
                                    frame: fitted, bounds: b, dimFrame: boundsFrame, aspect: normalizedAspect)
                        if extending {
                            extendHint
                                .position(x: geo.size.width / 2, y: 20)
                        }
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
            }
            controls
        }
        .onAppear {
            working = model.currentEdits
            extending = working.cropExtendsBeyondImage
            promptText = working.extendPrompt ?? ""
            render()
            if let method = model.pendingExtend {
                model.pendingExtend = nil
                setExtending(true)
                setMethod(method)
            }
            if DebugHooks.extendOnLaunch {
                setExtending(true)
                aspect = .r16x9
                if DebugHooks.generateOnLaunch { setMethod(.generate) }
            }
        }
        .onChange(of: working.crop) { schedulePreview() }
        .onChange(of: ModelDownloads.shared.installCount) {
            modelInstalled = GenerativeModel.isInstalled
            if modelInstalled && generateWhenInstalled {
                generateWhenInstalled = false
                setMethod(.generate)
            }
        }
        .onDisappear {
            // A generation Done is waiting for keeps running (the final fill joins it).
            if !applied { previewTask?.cancel() }
        }
        .onChange(of: baseRevision) {
            preview = nil
            schedulePreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCommit)) { note in
            if note.object as AnyObject? === model { apply() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCancel)) { note in
            if note.object as AnyObject? === model { model.activeTool = nil }
        }
    }

    /// Over a shown fill that replaces a print's border, only the picture inside the border is drawn.
    @ViewBuilder
    private func pictureMask(size: CGSize) -> some View {
        if extending, working.cropExtendsBeyondImage, let preview, preview.key == previewKey, let c = preview.content {
            Rectangle()
                .frame(width: c.width * size.width, height: c.height * size.height)
                .position(x: c.midX * size.width, y: c.midY * size.height)
        } else {
            Rectangle()
        }
    }

    static func viewRect(_ r: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + r.minX * fitted.width, y: fitted.minY + r.minY * fitted.height,
               width: r.width * fitted.width, height: r.height * fitted.height)
    }

    private var isGenerating: Bool {
        working.effectiveExtendMethod == .generate && modelInstalled
    }

    private var previewKey: String {
        "\(working.effectiveExtendMethod.rawValue)|\(working.extendPrompt ?? "")|\(working.extendSeed ?? 1)"
    }

    private var hintText: String {
        guard working.cropExtendsBeyondImage else { return "Drag the frame's edges past the photo, or choose an Aspect such as 16:9, to extend it." }
        if isGenerating {
            if let p = generation.value { return "Generating the new area on this Mac… \(Int(p * 100))%" }
            if preview?.generated == true { return "Generated on this Mac. Done keeps it and sharpens the detail." }
            return "The new area will be generated on this Mac."
        }
        return "The new area is filled in from the photo itself. Preview — Done makes the final fill."
    }

    private var extendHint: some View {
        HStack(spacing: 8) {
            if previewing { ProgressView().controlSize(.small) }
            Text(hintText)
                .font(.callout)
                .monospacedDigit()
                .allowsHitTesting(false)
            if working.cropExtendsBeyondImage, preview != nil, !previewing {
                Button("Try Again", action: tryAgain)
                    .controlSize(.small)
                    .help("Fill the new area differently")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassBackground(in: .capsule)
    }

    private func tryAgain() {
        commitPrompt(preview: false)
        working.extendSeed = UInt64.random(in: 1...UInt64.max)
        schedulePreview(immediate: true)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "level")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { working.straighten }, set: { working.straighten = $0; render() }), in: -45...45) {
                    Text("Straighten")
                } onEditingChanged: { editing in
                    if !editing { render() }
                }
                .frame(minWidth: 220)
                Text(String(format: "%+.1f°", working.straighten))
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
                    .onTapGesture(count: 2) {
                        working.straighten = 0
                        render()
                    }
                    .help("Double-click to reset")
                Button("Auto") { autoStraighten() }
                    .disabled(busy)
                    .help("Level the horizon with Vision")
            }
            HStack(spacing: 10) {
                Picker("Aspect", selection: $aspect) {
                    ForEach(AspectPreset.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 170)
                .onChange(of: aspect) { applyAspect() }
                .help(extending ? "Extend the photo to this shape" : "Crop to this shape")
                Button {
                    portrait.toggle()
                    applyAspect()
                } label: {
                    Image(systemName: portrait ? "rectangle.portrait" : "rectangle")
                }
                .help("Swap orientation")
                .disabled(aspect == .freeform || aspect == .original || aspect == .square)

                Divider().frame(height: 18)
                Button { geometryChange { $0.rotate(clockwise: false) } } label: { Image(systemName: "rotate.left") }
                    .help("Rotate left")
                Button { geometryChange { $0.flip(horizontal: true) } } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip horizontal")
                Button("Smart Crop") { smartCrop() }
                    .disabled(busy || extending)
                    .help("Frame the subject with Vision saliency")

                Divider().frame(height: 18)
                Toggle(isOn: Binding(get: { extending }, set: { setExtending($0) })) {
                    Label("Extend", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .toggleStyle(.button)
                .disabled(!model.canExtend)
                .help(model.canExtend
                      ? "Drag the frame past the photo's edges and fill in more of the scene"
                      : "Extend needs a photo without see-through areas")
                if busy { ProgressView().controlSize(.small) }

                Spacer()
                Button("Reset") {
                    working.resetGeometry()
                    aspect = .freeform
                    extending = false
                    render()
                }
                Button("Cancel") { model.activeTool = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { apply() }
                    .prominentButtonStyle()
                    .keyboardShortcut(.defaultAction)
            }
            if extending { extendControls }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var extendControls: some View {
        HStack(spacing: 10) {
            Picker("Fill", selection: Binding(get: { working.effectiveExtendMethod }, set: { setMethod($0) })) {
                ForEach(ExtendMethod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .help(modelInstalled
                  ? "Match Photo continues the photo's own texture; Generate draws new content with an on-device model"
                  : "Generate needs the generative fill model, a one-time download")
            if working.effectiveExtendMethod == .generate {
                TextField(settingText.map { "Continuing: \($0)" } ?? "Describe what to add (optional)", text: $promptText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200, maxWidth: 420)
                    .onSubmit { commitPrompt() }
                    .help(settingText.map { "Apple Intelligence described the setting as “\($0)”, and Generate continues that. Type to ask for something else." }
                          ?? "For example “sandy beach and blue sky”. Leave empty to continue the scene.")
            }
            Button("Try Again", action: tryAgain)
            .disabled(!working.cropExtendsBeyondImage)
            .help("Fill the new area differently")
            Spacer()
            if !modelInstalled && GenerativeModel.isSupported {
                Button("Get the Model for Generate…") {
                    generateWhenInstalled = true
                    model.offerDownload(.generativeFill) {}
                }
                .controlSize(.small)
                .help("Generate draws new content with \(GenerativeModel.displayName), which runs on this Mac (a one-time download)")
            }
        }
    }

    // MARK: Actions

    private func setMethod(_ method: ExtendMethod) {
        // Generate before its model is installed: offered for download, and chosen once it's in.
        if method == .generate && !modelInstalled {
            generateWhenInstalled = true
            model.offerDownload(.generativeFill) {}
            return
        }
        Prefs.set(method.rawValue, PrefKey.extendMethod)
        working.extendMethod = method == .match ? nil : method
        if method == .generate { commitPrompt(preview: false) }
        schedulePreview(immediate: true)
    }

    private func commitPrompt(preview: Bool = true) {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = text.isEmpty || working.effectiveExtendMethod != .generate ? nil : text
        guard working.extendPrompt != value else { return }
        working.extendPrompt = value
        if preview { schedulePreview(immediate: true) }
    }

    private func geometryChange(_ change: (inout EditState) -> Void) {
        change(&working)
        render()
    }

    private func render() {
        guard let d = model.decoded else { return }
        let edits = working
        renderTask?.cancel()
        renderTask = Task {
            guard let output = await EditRenderer.shared.render(d, edits: edits, maxDimension: 1600, stage: .beforeCrop) else { return }
            guard !Task.isCancelled else { return }
            base = output.image
            baseRevision += 1
        }
    }

    private func setExtending(_ on: Bool) {
        extending = on
        if on {
            if working.extendSeed == nil { working.extendSeed = UInt64.random(in: 1...UInt64.max) }
            // A new extension starts with the fill chosen last time (Generate, once its model is installed).
            if !working.cropExtendsBeyondImage, working.extendMethod == nil, Prefs.preferredExtendMethod == .generate {
                working.extendMethod = .generate
            }
            if aspect != .freeform { applyAspect() }
        } else {
            // Back inside the photo.
            if let c = working.crop {
                let inside = c.intersection(Self.fullRect)
                working.crop = inside.isNull || inside.width < 0.03 || inside.height < 0.03 ? nil : inside
            }
            preview = nil
        }
    }

    private func apply() {
        commitPrompt(preview: false)
        var result = working
        if let c = result.crop, abs(c.minX) < 0.002, abs(c.minY) < 0.002, abs(c.width - 1) < 0.002, abs(c.height - 1) < 0.002 {
            result.crop = nil
        }
        if !result.cropExtendsBeyondImage {
            result.extendFill = nil
            result.extendMethod = nil
            result.extendPrompt = nil
        }
        if abs(result.straighten) < 0.05 { result.straighten = 0 }
        let previous = model.currentEdits
        // Extend making a copy: the original stays as it was; the extended picture is saved beside it.
        if result.cropExtendsBeyondImage, Prefs.makesCopy(.extend), let url = model.currentURL, let d = model.decoded, d.url == url {
            applied = true   // (a generation the preview started keeps going: the copy's fill joins it)
            model.saveExtendedCopy(url: url, decoded: d, edits: result)
            model.activeTool = nil
            return
        }
        if let url = model.currentURL, result != previous {
            // The final fill is made in the background (see ViewerModel.refillExtensionIfNeeded).
            applied = true
            model.applyEdits(result, to: url, undoName: result.cropExtendsBeyondImage ? "Extend" : "Crop & Straighten", previous: previous)
        }
        model.activeTool = nil
    }

    private func applyAspect() {
        guard let a = normalizedAspect else { return }
        if extending {
            // The smallest frame of this shape that holds the whole photo: widen (or heighten) it by filling in.
            var w: CGFloat = a >= 1 ? a : 1, h: CGFloat = a >= 1 ? 1 : 1 / a
            let s = min(1, bounds.width / w, bounds.height / h)
            w *= s
            h *= s
            working.crop = CGRect(x: 0.5 - w / 2, y: 0.5 - h / 2, width: w, height: h)
            return
        }
        // Largest rect of this aspect, centered on the current crop's center.
        let current = working.crop ?? Self.fullRect
        var w: CGFloat = 1, h: CGFloat = 1
        if a > 1 { h = 1 / a } else { w = a }
        var rect = CGRect(x: current.midX - w / 2, y: current.midY - h / 2, width: w, height: h)
        rect.origin.x = min(max(rect.minX, 0), 1 - rect.width)
        rect.origin.y = min(max(rect.minY, 0), 1 - rect.height)
        working.crop = rect
    }

    /// Recomputes the preview fill once the frame stops moving: the quick content-aware one right away,
    /// then (for Generate) the generated one, which the final fill reuses.
    private func schedulePreview(immediate: Bool = false) {
        previewTask?.cancel()
        guard extending, working.cropExtendsBeyondImage, let base, let crop = working.crop else {
            previewing = false
            generation.value = nil
            return
        }
        let key = previewKey
        let generate = isGenerating
        if let preview, preview.key == key, preview.generated == generate,
           preview.canvas.insetBy(dx: -0.002, dy: -0.002).contains(crop) { return }
        let seed = working.extendSeed ?? 1
        let edits = working
        let decoded = model.decoded
        let progress = generation
        previewTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            previewing = true
            defer {
                if !Task.isCancelled {
                    previewing = false
                    progress.value = nil
                }
            }
            // Generate shows only its own result (a copied preview first would look like a bad result).
            if !generate, let quick = try? await ExtendRenderer.previewFill(base: base, crop: crop, seed: seed) {
                guard !Task.isCancelled else { return }
                preview = PreviewFill(canvas: crop, image: quick.image, key: key, generated: false, content: quick.content)
            }
            guard generate, let decoded, !Task.isCancelled else { return }
            if !immediate {
                // Generating takes a while; wait for the frame to settle.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
            }
            progress.value = 0
            if (edits.extendPrompt ?? "").isEmpty {
                let setting = await ExtendRenderer.settingDescription(decoded, edits: edits)
                guard !Task.isCancelled else { return }
                settingText = setting
            }
            do {
                let result = try await ExtendRenderer.previewGenerativeFill(decoded, edits: edits, crop: crop) { fraction in
                    Task { @MainActor in if progress.value != nil { progress.value = fraction } }
                }
                guard !Task.isCancelled else { return }
                preview = PreviewFill(canvas: result.canvas, image: result.image, key: key, generated: true, content: result.content)
            } catch {
                guard !Task.isCancelled else { return }
                if case ExtendError.cancelled = error { return }
                model.showToast("Couldn't generate: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func autoStraighten() {
        guard let d = model.decoded else { return }
        var e = working
        e.straighten = 0
        e.crop = nil
        busy = true
        Task {
            if let proxy = await EditRenderer.shared.render(d, edits: e, maxDimension: 1024, stage: .beforeCrop)?.image,
               let angle = await VisionServices.straightenAngle(proxy) {
                if abs(angle) < 0.15 {
                    working.straighten = 0
                    model.showToast("Already level", systemImage: "level")
                } else {
                    working.straighten = min(max(angle, -45), 45)
                }
                render()
            } else {
                model.showToast("No clear horizon or upright lines to level by", systemImage: "level")
            }
            busy = false
        }
    }

    private func smartCrop() {
        guard let base else { return }
        busy = true
        Task {
            if let salient = await VisionServices.salientRegion(base),
               let rect = IntelligenceModel.cropRect(around: salient, imageSize: CGSize(width: base.width, height: base.height)) {
                working.crop = rect
            } else {
                model.showToast("This image is already well framed", systemImage: "crop")
            }
            busy = false
        }
    }
}

func fitRect(_ size: CGSize, in bounds: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
}

/// Marks area that's in the frame but not filled yet.
struct CheckerboardFill: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.32)))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : tile
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)), with: .color(Color(white: 0.22)))
                    x += tile * 2
                }
                y += tile
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}

/// Draggable crop rectangle with corner/edge handles, rule-of-thirds guides and dimmed surroundings.
struct CropOverlay: View {
    @Binding var crop: CGRect          // normalized, top-left origin
    let frame: CGRect                  // image frame in view coordinates
    var bounds = CGRect(x: 0, y: 0, width: 1, height: 1)   // where the crop may go (past 0...1 = Extend)
    var dimFrame: CGRect?              // area dimmed outside the crop (default: the image)
    let aspect: CGFloat?               // normalized width / height, nil = free

    @State private var start: CGRect?

    private static let minSize: CGFloat = 0.03

    enum Handle: CaseIterable, Identifiable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var id: Self { self }
        var left: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var right: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var top: Bool { [.topLeft, .top, .topRight].contains(self) }
        var bottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
        var isCorner: Bool { (left || right) && (top || bottom) }
    }

    private var viewRect: CGRect {
        CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
               width: crop.width * frame.width, height: crop.height * frame.height)
    }

    var body: some View {
        let r = viewRect
        ZStack {
            Path { p in
                p.addRect((dimFrame ?? frame).union(r))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3
                    let y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.7)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .contentShape(Rectangle())
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .gesture(moveGesture)
                .onHover { inside in inside ? NSCursor.openHand.push() : NSCursor.pop() }

            ForEach(Handle.allCases) { handle in
                handleView(handle)
                    .position(position(of: handle, in: r))
                    .gesture(resizeGesture(handle))
            }
        }
    }

    private func handleView(_ handle: Handle) -> some View {
        Group {
            if handle.isCorner {
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 14, height: 14)
            } else {
                Capsule().fill(.white).frame(width: handle.top || handle.bottom ? 26 : 6, height: handle.top || handle.bottom ? 6 : 26)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }

    private func position(of handle: Handle, in r: CGRect) -> CGPoint {
        let x = handle.left ? r.minX : handle.right ? r.maxX : r.midX
        let y = handle.top ? r.minY : handle.bottom ? r.maxY : r.midY
        return CGPoint(x: x, y: y)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if start == nil { start = crop }
                guard let s = start else { return }
                var r = s
                r.origin.x = min(max(s.minX + value.translation.width / frame.width, bounds.minX), bounds.maxX - s.width)
                r.origin.y = min(max(s.minY + value.translation.height / frame.height, bounds.minY), bounds.maxY - s.height)
                crop = r
            }
            .onEnded { _ in start = nil }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if start == nil { start = crop }
                guard let s = start else { return }
                crop = resized(s, handle: handle, dx: value.translation.width / frame.width, dy: value.translation.height / frame.height)
            }
            .onEnded { _ in start = nil }
    }

    private func resized(_ s: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let m = Self.minSize
        let b = bounds
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        if handle.left { minX = min(max(b.minX, s.minX + dx), maxX - m) }
        if handle.right { maxX = max(min(b.maxX, s.maxX + dx), minX + m) }
        if handle.top { minY = min(max(b.minY, s.minY + dy), maxY - m) }
        if handle.bottom { maxY = max(min(b.maxY, s.maxY + dy), minY + m) }
        guard let a = aspect else { return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }

        // Constrain to the aspect ratio, anchored on the opposite side/corner.
        var w = maxX - minX, h = maxY - minY
        if handle.isCorner || handle.left || handle.right { h = w / a } else { w = h * a }
        let anchorX: CGFloat = handle.left ? s.maxX : handle.right ? s.minX : s.midX
        let anchorY: CGFloat = handle.top ? s.maxY : handle.bottom ? s.minY : s.midY
        // Largest size that still fits inside the bounds from this anchor.
        let maxW: CGFloat = handle.left ? anchorX - b.minX : handle.right ? b.maxX - anchorX : 2 * min(anchorX - b.minX, b.maxX - anchorX)
        let maxH: CGFloat = handle.top ? anchorY - b.minY : handle.bottom ? b.maxY - anchorY : 2 * min(anchorY - b.minY, b.maxY - anchorY)
        let scale = min(1, maxW / max(w, 0.0001), maxH / max(h, 0.0001))
        w *= scale
        h *= scale
        let x = handle.left ? anchorX - w : handle.right ? anchorX : anchorX - w / 2
        let y = handle.top ? anchorY - h : handle.bottom ? anchorY : anchorY - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
