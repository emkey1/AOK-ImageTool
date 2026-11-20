import SwiftUI

struct AdjustPanel: View {
    @Environment(ViewerModel.self) private var model
    @State private var dragStart: EditState?
    @State private var presetPreviews: [FilterPreset: CGImage] = [:]
    /// The object being adjusted, the rest of the picture darkened (and which object it was made for).
    @State private var objectPreview: (id: UUID, image: CGImage)?
    @AppStorage(PrefKey.upscaledAnimationFormat) private var animationFormat = Animation.Container.gif.rawValue

    var body: some View {
        let e = model.currentEdits
        // Adjusting a selected object: only what it has its own of shows (the rest is the whole picture's).
        let object = model.currentAdjustTarget
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                quickActions(e)

                objectsSection(object)

                if object == nil {
                    straightenSection(e)
                }

                whiteBalanceSection(e, object: object)

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
                }

                PanelSection(title: "Detail", systemImage: "camera.filters") {
                    slider("Sharpness", \.sharpness, 0...1)
                    slider("Noise Reduction", \.noiseReduction, 0...1)
                    if object == nil {
                        slider("Vignette", \.vignette, 0...1)
                    }
                }

                if object == nil {
                    wholePictureSections(e)
                }

                HStack {
                    if let object {
                        Button("Reset Object") { resetObject(object) }
                            .disabled((e.localAdjustments?.first { $0.id == object.id }?.shown.isEmpty) ?? true)
                    } else {
                        Button("Reset Adjustments") { model.resetAdjustments() }
                            .disabled(!e.hasAdjustments)
                    }
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
        // (Also while the image is being saved over: an edit then would be lost when it's replaced.)
        .disabled(!model.canEdit)
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
        .task(id: objectPreviewKey) {
            guard let object = model.currentAdjustTarget else { return objectPreview = nil }
            try? await Task.sleep(for: .milliseconds(objectPreview?.id == object.id ? 300 : 0))
            guard !Task.isCancelled, let d = model.decoded, d.url == object.url else { return }
            let e = model.currentEdits
            let image = await Task.detached(priority: .userInitiated) {
                EditRenderer.shared.selectionPreview(d, edits: e, mask: object.mask, maxDimension: 480)
            }.value
            guard !Task.isCancelled, let image else { return }
            objectPreview = (object.id, image)
        }
    }

    /// The filters, the copies made from the picture: the whole picture's alone.
    @ViewBuilder
    private func wholePictureSections(_ e: EditState) -> some View {
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
    }

    /// What the object preview shows: the object, in the picture as it's edited (made again a moment after a change).
    private var objectPreviewKey: Int {
        var h = Hasher()
        h.combine(model.currentAdjustTarget?.id)
        h.combine(model.decoded.map(ObjectIdentifier.init))
        h.combine(try? JSONEncoder().encode(model.currentEdits))
        return h.finalize()
    }

    /// Objects: which one the sliders below change (or the whole picture), selecting another, and taking one's
    /// adjustments away.
    private func objectsSection(_ object: AdjustTarget?) -> some View {
        let objects = model.adjustableObjects
        return PanelSection(title: "Objects", systemImage: "person.crop.rectangle") {
            if objects.isEmpty {
                Text("Select an object to change its light, color and detail on its own, leaving the rest as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Adjusting", selection: Binding(
                    get: { object?.id },
                    set: { id in model.adjustTarget = objects.first { $0.id == id } }
                )) {
                    Text("Whole Picture").tag(UUID?.none)
                    ForEach(Array(objects.enumerated()), id: \.element.id) { index, o in
                        Text("Object \(index + 1)").tag(Optional(o.id))
                    }
                }
                .help("What the sliders below change")
            }
            if let object, let preview = objectPreview, preview.id == object.id {
                Image(decorative: preview.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help("The object being adjusted (the rest is darkened here only)")
            }
            HStack(spacing: 8) {
                Button {
                    model.viewMode = .viewer
                    model.activeTool = .selectToAdjust
                } label: {
                    Label("Select Object…", systemImage: "hand.point.up.left")
                }
                .help("Click an object in the picture to adjust it on its own")
                Spacer()
                if let object {
                    Button(role: .destructive) {
                        model.removeObjectAdjustments(object)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Take this object's own adjustments away")
                }
            }
            .controlSize(.small)
        }
    }

    /// Sets the object's own adjustments back to none (it stays selected, to adjust again).
    private func resetObject(_ object: AdjustTarget) {
        model.updateEdits("Reset Object") { e in
            for key in LocalAdjustment.keys { e.setLocalValue(key, 0, of: object.id, mask: object.mask) }
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
                    model.viewMode = .viewer
                    model.activeTool = .crop
                } label: {
                    Label("Crop", systemImage: "crop.rotate").frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .help("Crop & straighten (C)")

                Button {
                    model.beginCloneHeal()
                } label: {
                    Label("Heal", systemImage: "bandage").frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .disabled(!model.canRemoveObjects)
                .help("Clone & heal: paint with what's copied from elsewhere in the picture (⇧⌘H)")
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

    /// Straightening without opening the crop tool: the corners it turns out of the frame are cropped away
    /// (the pipeline crops to the largest upright rectangle of the same shape).
    private func straightenSection(_ e: EditState) -> some View {
        PanelSection(title: "Straighten", systemImage: "level") {
            slider("Angle", \.straighten, -45...45, format: { String(format: "%+.1f°", $0) }, undoName: "Straighten")
            HStack(spacing: 4) {
                nudge("−1°", by: -1, e)
                nudge("−0.1°", by: -0.1, e)
                Spacer()
                Button("Auto") { model.intelligence.autoStraighten() }
                    .help("Level the horizon, or upright lines such as walls and door frames")
                Spacer()
                nudge("+0.1°", by: 0.1, e)
                nudge("+1°", by: 1, e)
            }
            .controlSize(.small)
        }
    }

    /// White balance: the eyedropper, Auto, the light it was taken in, and Warmth and Tint (an object has only
    /// its own Warmth and Tint).
    private func whiteBalanceSection(_ e: EditState, object: AdjustTarget?) -> some View {
        PanelSection(title: "White Balance", systemImage: "thermometer.sun") {
            if object == nil {
                whiteBalanceTools
            }
            slider("Warmth", \.temperature, -1...1)
            slider("Tint", \.tint, -1...1)
        }
    }

    private var whiteBalanceTools: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { model.pickingWhiteBalance }, set: { model.pickingWhiteBalance = $0 })) {
                Label("Pick", systemImage: "eyedropper")
            }
            .toggleStyle(.button)
            .help("Click something in the photo that should be white or gray, and the color cast is taken out (Esc puts it away)")
            Button("Auto") { model.autoWhiteBalance() }
                .help("Take out the color cast, going by what in the photo looks like it should be neutral")
            Menu("Lit By") {
                Button("As Shot") { model.setWhiteBalance(nil) }
                Divider()
                ForEach(WhiteBalance.Light.allCases) { light in
                    Button(light.title) { model.setWhiteBalance(light) }
                }
            }
            .fixedSize()
            .help("Correct for the light the photo was taken in")
            Spacer()
        }
        .controlSize(.small)
    }

    /// Turns the picture by `step` degrees (clockwise for positive), as one undo step.
    private func nudge(_ title: String, by step: Double, _ e: EditState) -> some View {
        Button(title) {
            model.updateEdits("Straighten") { $0.straighten = min(max((($0.straighten + step) * 10).rounded() / 10, -45), 45) }
        }
        .monospacedDigit()
        .disabled(step < 0 ? e.straighten <= -45 : e.straighten >= 45)
        .help(step < 0 ? "Turn \(title.dropFirst()) counterclockwise" : "Turn \(title.dropFirst()) clockwise")
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
                    Button("Fix Blur…") { model.beginFixBlur() }
                        .disabled(!model.canFixBlur)
                }
                if SuperResolution.isSupported {
                    Menu("Upscale") {
                        ForEach(SuperResolution.offeredScales, id: \.self) { scale in
                            let estimate = model.animationUpscale(by: scale)
                            Button(UpscaleMenu.title(scale, estimate)) { model.upscaleCurrent(by: scale) }
                                .disabled(estimate?.allowed == false)
                        }
                        if model.decoded?.isAnimated == true {
                            Divider()
                            Picker("Save Animation As", selection: $animationFormat) {
                                ForEach(Animation.Container.allCases) { Text($0.title).tag($0.rawValue) }
                            }
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

    /// A slider for the whole picture's `keyPath`, or the object's own when one is being adjusted (and has one).
    private func slider(_ title: String, _ keyPath: WritableKeyPath<EditState, Double>, _ range: ClosedRange<Double>,
                        format: @escaping (Double) -> String = { String(format: "%+.0f", $0 * 100) },
                        resetValue: Double = 0, undoName: String? = nil) -> some View {
        let object = model.currentAdjustTarget.flatMap { LocalAdjustment.keys.contains(keyPath) ? $0 : nil }
        let value: (EditState) -> Double = { e in object.map { e.localValue(keyPath, of: $0.id) } ?? e[keyPath: keyPath] }
        let set: (inout EditState, Double) -> Void = { e, v in
            if let object { e.setLocalValue(keyPath, v, of: object.id, mask: object.mask) } else { e[keyPath: keyPath] = v }
        }
        return AdjustmentSlider(
            title: title,
            value: Binding(
                get: { value(model.currentEdits) },
                set: { v in model.previewEdits { set(&$0, v) } }
            ),
            range: range,
            format: format,
            isDefault: abs(value(model.currentEdits) - resetValue) < 0.0001,
            onEditingChanged: { editing in
                if editing {
                    dragStart = model.currentEdits
                } else if let start = dragStart {
                    model.commitEdits(from: start, actionName: undoName ?? title)
                    dragStart = nil
                    // (Straightening an extended photo makes its extension again.)
                    model.refillExtensionIfNeeded()
                }
            },
            reset: { model.updateEdits("Reset \(undoName ?? title)") { set(&$0, resetValue) } }
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
