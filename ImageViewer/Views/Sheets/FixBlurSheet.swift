import SwiftUI
import Vision

/// Image ▸ Fix Blur…: what kind of blur to take out (and whether to restore faces), previewed on a spot of the
/// picture at full size, which can be moved anywhere in it, for a sharpened copy saved next to the original (or,
/// with copies off, in its place).
struct FixBlurSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options = BlurFixer.Options.last
    /// The whole picture with its edits, and a small copy of it.
    @State private var picture: CGImage?
    @State private var overview: CGImage?
    /// Where the spot shown is (pixels, top-left origin; not rounded, so slow scrolling adds up), and how big: full
    /// size, or smaller for a face bigger than the preview.
    @State private var spotOrigin = CGPoint.zero
    @State private var spotSide: CGFloat = 0
    /// The last result and the spot it's for: when the spot moves, it moves with the picture until the next is made.
    @State private var after: CGImage?
    @State private var afterSpot = CGRect.zero
    @State private var previewing = false
    /// The panes, in the sheet (top-left origin), and the side of the picture in each.
    @State private var panesFrame = CGRect.zero
    @State private var paneSide: CGFloat = 300
    /// Where the spot was when the current drag began.
    @State private var dragStart: CGPoint?
    @State private var scrollMonitor: Any?
    @State private var previewTask: Task<Void, Never>?
    @State private var blurInstalled = BlurFixer.blurModelsInstalled
    @State private var facesInstalled = BlurFixer.faceModel.isInstalled

    private var effective: BlurFixer.Options { options.available }
    /// In whole pixels.
    private var spot: CGRect { CGRect(x: spotOrigin.x.rounded(), y: spotOrigin.y.rounded(), width: spotSide, height: spotSide) }
    private var before: CGImage? { spotSide > 0 ? picture?.cropping(to: spot) : nil }
    /// There's more of the picture than the spot shows.
    private var canMove: Bool { picture.map { CGFloat($0.width) > spotSide || CGFloat($0.height) > spotSide } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Fix Blur", systemImage: "camera.metering.center.weighted").font(.title2.weight(.bold))
            Text(Prefs.makesCopy(.fixBlur) ? "Saves a sharpened copy next to the original, stacked on top of it." : "Sharpens the image itself (Settings ▸ Editing ▸ Copies).")
                .foregroundStyle(.secondary)
            modelsNeeded
            HStack(alignment: .top, spacing: 10) {
                HStack(spacing: 10) {
                    pane("Before", before)
                    if effective.doesSomething {
                        pane("After", before, result: after, working: previewing || afterSpot != spot)
                    } else {
                        pane("After", nil, message: blurInstalled || facesInstalled
                             ? "Choose a kind of blur or Restore Faces."
                             : "Download a model above to see the result here.")
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panesFrame = $0 }
                if canMove, let picture, let overview { navigator(overview, of: picture) }
            }
            .frame(minHeight: 260, maxHeight: .infinity)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Blur").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Picker("Blur", selection: $options.blur) {
                                ForEach(BlurFixer.Blur.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 330)
                            .disabled(!blurInstalled)
                            if !blurInstalled { needsModel }
                        }
                        Text(blurHelp).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Strength").foregroundStyle(.secondary)
                    strength($options.blurStrength)
                        .disabled(!blurInstalled || options.blur == .none)
                }
                GridRow {
                    Text("Faces").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle("Restore faces", isOn: $options.faces)
                                .disabled(!facesInstalled)
                            if !facesInstalled { needsModel }
                        }
                        Text("Redraws blurry faces with \(BlurFixer.facesModelName): clearer eyes, mouths and hair. It makes up detail, so check that people still look like themselves; on a sharp face it mostly smooths the skin.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text("Strength").foregroundStyle(.secondary)
                    strength($options.faceStrength)
                        .disabled(!facesInstalled || !options.faces)
                }
            }
            HStack {
                Text("Runs on this Mac; a large photo takes up to a minute.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(Prefs.makesCopy(.fixBlur) ? "Save Copy" : "Sharpen") {
                    BlurFixer.Options.last = options
                    model.fixBlurCurrent(options)
                    dismiss()
                }
                .prominentButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(picture == nil || !effective.doesSomething)
            }
        }
        .padding(20)
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task(id: model.decoded?.url) { await loadPicture() }
        .onAppear {
            // Two-finger scrolling (or the wheel) over the pictures moves around in them.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
                guard let window = event.window, window === model.window?.attachedSheet, let height = window.contentView?.bounds.height,
                      panesFrame.contains(CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)) else { return event }
                let speed = (event.hasPreciseScrollingDeltas ? 1 : 8) * spotSide / max(paneSide, 1)
                moveSpot(to: CGPoint(x: spotOrigin.x - event.scrollingDeltaX * speed, y: spotOrigin.y - event.scrollingDeltaY * speed))
                return nil
            }
        }
        .onDisappear {
            previewTask?.cancel()
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
        .onChange(of: options) { updatePreview() }
        .onChange(of: ModelDownloads.shared.installCount) {
            blurInstalled = BlurFixer.blurModelsInstalled
            facesInstalled = BlurFixer.faceModel.isInstalled
            updatePreview()
        }
    }

    private var blurHelp: String {
        switch options.blur {
        case .focus: "For soft, slightly out-of-focus pictures, and scans of prints. Uses \(BlurFixer.blurModelName)."
        case .shake: "For pictures smeared by a moving camera. Uses \(BlurFixer.blurModelName)."
        case .none: "Only faces are restored."
        }
    }

    /// The spot (`image`), with `result` where it belongs in it (see `afterSpot`). Where an After pane has no result
    /// yet, the picture is dimmed: it isn't sharpened there.
    private func pane(_ title: String, _ image: CGImage?, result: CGImage? = nil, working: Bool = false, message: String? = nil) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
                    .onGeometryChange(for: CGFloat.self) { min($0.size.width, $0.size.height) - 12 } action: { paneSide = max($0, 1) }
                if let image {
                    let scale = paneSide / max(spotSide, 1)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: paneSide, height: paneSide)
                            .opacity(working ? 0.45 : 1)
                        if let result {
                            Image(decorative: result, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: afterSpot.width * scale, height: afterSpot.height * scale)
                                .offset(x: (afterSpot.minX - spot.minX) * scale, y: (afterSpot.minY - spot.minY) * scale)
                        }
                    }
                    .frame(width: paneSide, height: paneSide)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(moveDrag(scale: scale), isEnabled: canMove)
                    .pointerStyle(canMove ? (dragStart == nil ? .grabIdle : .grabActive) : .default)
                }
                if let message {
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                } else if image == nil || working {
                    ProgressView()
                }
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Dragging a pane drags the picture in it.
    private func moveDrag(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? spotOrigin
                dragStart = start
                moveSpot(to: CGPoint(x: start.x - drag.translation.width / scale, y: start.y - drag.translation.height / scale))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// The whole picture, showing where the spot is in it: clicking or dragging on it takes the spot there.
    private func navigator(_ overview: CGImage, of picture: CGImage) -> some View {
        let box: CGFloat = 120
        let scale = box / CGFloat(max(picture.width, picture.height))
        return VStack(spacing: 6) {
            Image(decorative: overview, scale: 1)
                .resizable()
                .frame(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
                .overlay(alignment: .topLeading) {
                    Rectangle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .shadow(radius: 1)
                        .frame(width: max(spot.width * scale, 6), height: max(spot.height * scale, 6))
                        .offset(x: spot.minX * scale, y: spot.minY * scale)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    moveSpot(to: CGPoint(x: drag.location.x / scale - spotSide / 2, y: drag.location.y / scale - spotSide / 2))
                })
            Text("Drag or scroll the pictures to look around, or click here.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: box)
    }

    /// Moves the spot, keeping it in the picture. The result for the new spot is made once it stops moving.
    private func moveSpot(to origin: CGPoint) {
        guard let picture else { return }
        let shown = spot
        spotOrigin = CGPoint(x: min(max(origin.x, 0), CGFloat(picture.width) - spotSide),
                             y: min(max(origin.y, 0), CGFloat(picture.height) - spotSide))
        if spot != shown { updatePreview() }
    }

    private func strength(_ value: Binding<Double>) -> some View {
        HStack {
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .frame(maxWidth: 330)
    }

    private var needsModel: some View {
        Label("Needs its model (above)", systemImage: "arrow.down.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The models that aren't installed, with their downloads, at the top: nothing works without them.
    @ViewBuilder
    private var modelsNeeded: some View {
        let missing = [DownloadableModel.fixBlur, .restoreFaces].filter { $0.id == DownloadableModel.fixBlur.id ? !blurInstalled : !facesInstalled }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(missing.count == 2 ? "Fix Blur needs its models" : "One of Fix Blur's models isn't installed", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                Text("They run on this Mac, and each is a one-time download (also in Settings ▸ Editing).")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(missing) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.id == DownloadableModel.fixBlur.id ? "Out of Focus and Camera Shake" : "Restore Faces").fontWeight(.semibold)
                            Text("\(m.modelName), \(m.formattedSize), \(m.licenseName) license").font(.caption).foregroundStyle(.secondary)
                            if let failure = ModelDownloads.shared.failure[m.id] {
                                Text(failure).font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        download(m)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
        }
    }

    @ViewBuilder
    private func download(_ m: DownloadableModel) -> some View {
        let downloads = ModelDownloads.shared
        switch downloads.status[m.id] {
        case .downloading(let fraction)?:
            ProgressView(value: fraction).frame(width: 110)
            Text("\(Int(fraction * 100))%").monospacedDigit().font(.caption).frame(width: 34, alignment: .trailing)
            Button("Cancel") { downloads.cancel(m) }.controlSize(.small)
        case .installing?:
            ProgressView().controlSize(.small)
            Text("Installing…").font(.caption).foregroundStyle(.secondary)
        case nil:
            Button("Download (\(m.formattedSize))") { downloads.start(m) }
        }
    }

    /// Most of the window's height.
    private var sheetSize: CGSize {
        let window = model.window?.contentLayoutRect.size ?? CGSize(width: 1280, height: 840)
        let height = max(560, window.height * 0.8)
        return CGSize(width: min(max(820, height * 1.25), window.width * 0.9), height: height)
    }

    /// What the sheet starts with.
    private struct Loaded: @unchecked Sendable {
        let picture: CGImage
        let overview: CGImage?
        let center: CGPoint
        let side: CGFloat
    }

    /// The picture, and the spot to start at: around the biggest face, else the middle, at full size.
    private func loadPicture() async {
        guard let d = model.decoded, d.url == model.currentURL else { return }
        let e = model.currentEdits
        let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            try? await MaskStore.shared.prepare(e, for: d)
            let renderer = EditRenderer.shared
            guard let picture = renderer.renderSync(d, edits: e, maxDimension: nil)?.image else { return nil }
            let size = CGSize(width: picture.width, height: picture.height)
            var center = CGPoint(x: size.width / 2, y: size.height / 2)
            var side: CGFloat = 448
            let small = VisionServices.downscaledSync(picture, maxDimension: 1024)
            if let face = ((try? await DetectFaceRectanglesRequest().perform(on: small)) ?? [])
                .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                let box = face.boundingBox.toImageCoordinates(size, origin: .upperLeft)
                center = CGPoint(x: box.midX, y: box.midY)
                side = max(side, max(box.width, box.height) * 1.8)
            }
            return Loaded(picture: picture, overview: small, center: center, side: min(side, size.width, size.height).rounded(.down))
        }.value
        guard let loaded else { return }
        picture = loaded.picture
        overview = loaded.overview
        spotSide = loaded.side
        spotOrigin = .zero
        moveSpot(to: CGPoint(x: loaded.center.x - loaded.side / 2, y: loaded.center.y - loaded.side / 2))
        updatePreview()
    }

    private func updatePreview() {
        guard picture != nil else { return }
        let options = effective
        let previous = previewTask
        previous?.cancel()
        guard options.doesSomething else {
            previewing = false
            return
        }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // (One at a time: a run stops between the model's tiles, not during one.)
            await previous?.value
            guard !Task.isCancelled, let before else { return }
            previewing = true
            defer { if !Task.isCancelled { previewing = false } }
            let at = spot
            let made = try? await BlurFixer.fix(before, options) { _ in Task.isCancelled }
            if !Task.isCancelled, let made {
                after = made
                afterSpot = at
            }
        }
    }
}
