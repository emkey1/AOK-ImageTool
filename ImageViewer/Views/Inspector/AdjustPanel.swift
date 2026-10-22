import SwiftUI

struct AdjustPanel: View {
    @Environment(ViewerModel.self) private var model
    @State private var dragStart: EditState?
    @State private var presetPreviews: [FilterPreset: CGImage] = [:]

    var body: some View {
        let e = model.currentEdits
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                quickActions(e)

                PanelSection(title: "Light", systemImage: "sun.max") {
                    slider("Exposure", \.exposure, -2...2, format: { String(format: "%+.2f EV", $0) })
                    slider("Brightness", \.brightness, -1...1)
                    slider("Contrast", \.contrast, -1...1)
                    slider("Highlights", \.highlights, -1...1)
                    slider("Shadows", \.shadows, -1...1)
                }

                PanelSection(title: "Color", systemImage: "paintpalette") {
                    slider("Saturation", \.saturation, -1...1)
                    slider("Vibrance", \.vibrance, -1...1)
                    slider("Warmth", \.temperature, -1...1)
                    slider("Tint", \.tint, -1...1)
                }

                PanelSection(title: "Detail", systemImage: "camera.filters") {
                    slider("Sharpness", \.sharpness, 0...1)
                    slider("Noise Reduction", \.noiseReduction, 0...1)
                    slider("Vignette", \.vignette, 0...1)
                }

                PanelSection(title: "Filters", systemImage: "camera.filters") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 10) {
                        ForEach(FilterPreset.allCases) { preset in
                            PresetTile(preset: preset, image: presetPreviews[preset], selected: e.filter == preset) {
                                model.updateEdits("Filter") {
                                    $0.filter = preset
                                    $0.filterIntensity = 1
                                }
                            }
                        }
                    }
                    if e.filter != .none {
                        slider("Intensity", \.filterIntensity, 0...1, format: { "\(Int($0 * 100))%" }, resetValue: 1)
                    }
                }

                copiesSection

                HStack {
                    Button("Reset Adjustments") { model.resetAdjustments() }
                        .disabled(!e.hasAdjustments)
                    Spacer()
                    Button("Revert All") { model.revertEdits() }
                        .disabled(e.isIdentity)
                }
                .controlSize(.small)

                HStack {
                    Button {
                        model.save()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .prominentButtonStyle()
                    .disabled(e.isIdentity)
                    Button {
                        model.requestExport()
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle()
                }
                .controlSize(.large)
            }
            .padding(14)
        }
        .disabled(model.decoded == nil || model.activeTool != nil)
        .task(id: previewKey) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let d = model.decoded else { return }
            var base = model.currentEdits
            base.filter = .none
            base.crop = nil
            base.vignette = 0
            let previews = await Task.detached(priority: .utility) {
                EditRenderer.shared.presetPreviews(d, edits: base, size: 150)
            }.value
            guard !Task.isCancelled else { return }
            presetPreviews = previews
        }
    }

    private var previewKey: Int {
        var h = Hasher()
        h.combine(model.decoded.map(ObjectIdentifier.init))
        var e = model.currentEdits
        e.filter = .none
        e.filterIntensity = 1
        h.combine(try? JSONEncoder().encode(e))
        return h.finalize()
    }

    @ViewBuilder
    private func quickActions(_ e: EditState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.toggleAutoEnhance()
                } label: {
                    Label("Auto", systemImage: e.autoEnhance ? "wand.and.stars" : "wand.and.stars.inverse")
                        .frame(maxWidth: .infinity)
                }
                .tint(e.autoEnhance ? .accentColor : nil)
                .glassButtonStyle()
                .help("Auto enhance")

                Button {
                    model.activeTool = .crop
                } label: {
                    Label("Crop", systemImage: "crop.rotate").frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .help("Crop & straighten (C)")
            }
            HStack(spacing: 6) {
                iconButton("rotate.left", help: "Rotate left") { model.rotate(clockwise: false) }
                iconButton("rotate.right", help: "Rotate right") { model.rotate(clockwise: true) }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal") { model.flip(horizontal: true) }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertical") { model.flip(horizontal: false) }
                Spacer()
                Toggle(isOn: Binding(get: { model.showOriginal }, set: { model.showOriginal = $0 })) {
                    Image(systemName: model.showOriginal ? "eye.fill" : "eye").frame(width: 22, height: 18)
                }
                .toggleStyle(.button)
                .disabled(e.isIdentity)
                .help("Show original (\\)")
            }
            .controlSize(.regular)
        }
    }

    /// Copies saved next to the original (and stacked on it), rather than edits to it.
    private var copiesSection: some View {
        PanelSection(title: "Copies", systemImage: "square.stack") {
            Text("Saved next to the original and stacked on top of it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Black & White…") { model.showBlackAndWhite = true }
                if GenerativeModel.isSupported {
                    Button("Colorize") { model.colorizeCurrent() }
                }
                if SuperResolution.isSupported {
                    Menu("Upscale") {
                        ForEach(SuperResolution.offeredScales, id: \.self) { scale in
                            Button("\(scale)×") { model.upscaleCurrent(by: scale) }
                        }
                    }
                    .fixedSize()
                }
            }
            .controlSize(.small)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .help(help)
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<EditState, Double>, _ range: ClosedRange<Double>,
                        format: @escaping (Double) -> String = { String(format: "%+.0f", $0 * 100) },
                        resetValue: Double = 0) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.currentEdits[keyPath: keyPath] },
                set: { v in model.previewEdits { $0[keyPath: keyPath] = v } }
            ),
            range: range,
            format: format,
            isDefault: abs(model.currentEdits[keyPath: keyPath] - resetValue) < 0.0001,
            onEditingChanged: { editing in
                if editing {
                    dragStart = model.currentEdits
                } else if let start = dragStart {
                    model.commitEdits(from: start, actionName: title)
                    dragStart = nil
                }
            },
            reset: { model.updateEdits("Reset \(title)") { $0[keyPath: keyPath] = resetValue } }
        )
    }
}

struct AdjustmentSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let isDefault: Bool
    let onEditingChanged: (Bool) -> Void
    let reset: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            HStack {
                Text(title)
                Spacer()
                Text(isDefault ? "—" : format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(isDefault ? .tertiary : .secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: reset)
            .help("Double-click to reset")
            Slider(value: value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
        }
    }
}

struct PresetTile: View {
    let preset: FilterPreset
    let image: CGImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 80, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(preset.title)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
