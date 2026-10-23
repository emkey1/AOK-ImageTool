import SwiftUI
import Vision

/// Image ▸ Fix Blur…: what kind of blur to take out (and whether to restore faces), previewed on a detail at
/// full size, for a sharpened copy saved next to the original (or, with copies off, in its place).
struct FixBlurSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options = BlurFixer.Options.last
    /// The detail shown, at full size (or smaller, for a face bigger than the preview), before and after.
    @State private var before: CGImage?
    @State private var after: CGImage?
    @State private var previewing = false
    @State private var previewTask: Task<Void, Never>?
    @State private var blurInstalled = BlurFixer.blurModelsInstalled
    @State private var facesInstalled = BlurFixer.faceModel.isInstalled

    private var effective: BlurFixer.Options { options.available }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Fix Blur", systemImage: "camera.metering.center.weighted").font(.title2.weight(.bold))
            Text(Prefs.makesCopy(.fixBlur) ? "Saves a sharpened copy next to the original, stacked on top of it." : "Sharpens the image itself (Settings ▸ Editing ▸ Copies).")
                .foregroundStyle(.secondary)
            modelsNeeded
            HStack(spacing: 10) {
                pane("Before", before)
                if effective.doesSomething {
                    pane("After", after, working: previewing)
                } else {
                    pane("After", nil, message: blurInstalled || facesInstalled
                         ? "Choose a kind of blur or Restore Faces."
                         : "Download a model above to see the result here.")
                }
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
                .disabled(before == nil || !effective.doesSomething)
            }
        }
        .padding(20)
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task(id: model.decoded?.url) { await loadDetail() }
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

    private func pane(_ title: String, _ image: CGImage?, working: Bool = false, message: String? = nil) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(6)
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
        return CGSize(width: min(max(700, height * 1.1), window.width * 0.9), height: height)
    }

    /// The detail to preview: around the biggest face, else the middle, at full size.
    private func loadDetail() async {
        guard let d = model.decoded, d.url == model.currentURL else { return }
        let e = model.currentEdits
        before = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            try? await MaskStore.shared.prepare(e, for: d)
            let renderer = EditRenderer.shared
            let image = renderer.makeImage(d, edits: e, maxDimension: nil, stage: .full)
            let ext = image.extent
            var center = CGPoint(x: ext.midX, y: ext.midY)
            var side: CGFloat = 448
            let scale = min(1, 1024 / max(ext.width, ext.height))
            if let small = renderer.context.createCGImage(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                                                         from: CGRect(x: 0, y: 0, width: (ext.width * scale).rounded(.down),
                                                                      height: (ext.height * scale).rounded(.down))),
               let face = ((try? await DetectFaceRectanglesRequest().perform(on: small)) ?? [])
                   .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                let box = face.boundingBox.toImageCoordinates(ext.size, origin: .lowerLeft)
                center = CGPoint(x: box.midX, y: box.midY)
                side = max(side, max(box.width, box.height) * 1.8)
            }
            side = min(side, ext.width, ext.height)
            let rect = CGRect(x: min(max(center.x - side / 2, ext.minX), ext.maxX - side),
                              y: min(max(center.y - side / 2, ext.minY), ext.maxY - side), width: side, height: side).integral
            return renderer.createCGImage(image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)),
                                          like: d)
        }.value
        updatePreview()
    }

    private func updatePreview() {
        guard let before else { return }
        let options = effective
        previewTask?.cancel()
        guard options.doesSomething else {
            previewing = false
            return
        }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            previewing = true
            defer { if !Task.isCancelled { previewing = false } }
            let made = try? await BlurFixer.fix(before, options)
            if !Task.isCancelled, let made { after = made }
        }
    }
}
