import SwiftUI

struct AdjustPanel: View {
    @Environment(ViewerModel.self) private var model
    @State private var dragStart: EditState?
    @State private var presetPreviews: [FilterPreset: CGImage] = [:]
    /// Each saved preset on this picture.
    @State private var savedPreviews: [UUID: CGImage] = [:]
    /// A saved preset about to be deleted (asked first).
    @State private var deleting: AdjustmentPreset?
    /// The object being adjusted, the rest of the picture darkened (and which object it was made for).
    @State private var objectPreview: (id: UUID, image: CGImage)?
    @AppStorage(PrefKey.upscaledAnimationFormat) private var animationFormat = Animation.Container.gif.rawValue

    var body: some View {
        let e = model.currentEdits
        // In Adjust Objects, only what an object has its own of shows (the rest is the whole picture's), and
        // its bar under the picture has Cancel and Done.
        let objectMode = model.isAdjustingObjects
        let object = objectMode ? model.currentAdjustTarget : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if objectMode {
                    adjustingObjectsSection(object)
                } else {
                    quickActions(e)
                    objectsSection(e)
                    straightenSection(e)
                }

                Group {
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
                        if !objectMode {
                            slider("Vignette", \.vignette, 0...1)
                        }
                    }
                }
                // (In Adjust Objects with no object yet, nothing here is the object's.)
                .disabled(objectMode && object == nil)

                if let object {
                    HStack {
                        Button("Reset Object") { resetObject(object) }
                            .disabled((e.localAdjustments?.first { $0.id == object.id }?.shown.isEmpty) ?? true)
                        Spacer()
                    }
                    .controlSize(.small)
                } else if !objectMode {
                    wholePictureSections(e)

                    HStack {
                        Button("Reset Adjustments") { model.resetAdjustments() }
                            .disabled(!e.hasAdjustments)
                        Spacer()
                        Button("Revert All") { model.revertEdits() }
                            .disabled(e.isIdentity)
                    }
                    .controlSize(.small)

                    saveButtons(e)
                }
            }
            .padding(14)
        }
        // (Also while the image is being saved over: an edit then would be lost when it's replaced.)
        .disabled(!model.canEdit && !objectMode)
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
        .task(id: savedPreviewKey) {
            let presets = PresetStore.shared.presets
            guard !presets.isEmpty else { return savedPreviews = [:] }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let d = model.decoded else { return }
            var base = model.currentEdits
            base.crop = nil
            let previews = await Task.detached(priority: .utility) {
                EditRenderer.shared.adjustmentPresetPreviews(d, edits: base, presets: presets, size: 150)
            }.value
            guard !Task.isCancelled else { return }
            savedPreviews = previews
        }
        .confirmationDialog("Delete the preset “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { preset in
            Button("Delete", role: .destructive) { PresetStore.shared.delete(preset.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Pictures it was put on keep their adjustments.")
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

    private func saveButtons(_ e: EditState) -> some View {
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

    /// The filters, the copies made from the picture: the whole picture's alone.
    @ViewBuilder
    private func wholePictureSections(_ e: EditState) -> some View {
        PanelSection(title: "Filters", systemImage: "camera.filters") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 10) {
                ForEach(FilterPreset.allCases) { preset in
                    PresetTile(title: preset.title, image: presetPreviews[preset], selected: e.filter == preset) {
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

        presetsSection(e)

        copiesSection
    }

    /// The user's own presets: a picture's adjustments saved under a name, put on this one with a click (in place
    /// of its own, as Paste Edits does).
    private func presetsSection(_ e: EditState) -> some View {
        let presets = PresetStore.shared.presets
        let adjusted = !e.adjustments.shown.isIdentity
        return PanelSection(title: "Presets", systemImage: "square.stack.3d.up") {
            if presets.isEmpty {
                Text("Save this picture's light, color, white balance, detail and filter as a preset, to put on others with a click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 10) {
                    ForEach(presets) { preset in
                        PresetTile(title: preset.name, image: savedPreviews[preset.id], selected: preset.matches(e)) {
                            model.applyPreset(preset, to: model.currentURL.map { [$0] })
                        }
                        .help("“\(preset.name)”: its light, color, detail and filter in place of this picture's (right-click to rename or delete)")
                        .contextMenu {
                            Button("Rename…") { model.presetNaming = PresetNaming(kind: .rename(preset)) }
                            Button("Replace with This Picture's Adjustments") { PresetStore.shared.update(preset.id, edits: e) }
                                .disabled(!adjusted || preset.matches(e))
                            Divider()
                            Button("Delete…") { deleting = preset }
                        }
                    }
                }
            }
            Button {
                model.beginSavingPreset()
            } label: {
                Label("Save as Preset…", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(!adjusted)
            .help("Save this picture's light, color, white balance, detail and filter, to put on other pictures")
        }
    }

    /// What the saved presets' previews show: the picture's own parts (a preset replaces the rest) and the presets.
    private var savedPreviewKey: Int {
        var h = Hasher()
        h.combine(model.decoded.map(ObjectIdentifier.init))
        var own = model.currentEdits
        own.takeAdjustments(from: .identity)
        h.combine(try? JSONEncoder().encode(own))
        h.combine(try? JSONEncoder().encode(PresetStore.shared.presets))
        return h.finalize()
    }

    /// What the object preview shows: the object, in the picture as it's edited (made again a moment after a change).
    private var objectPreviewKey: Int {
        var h = Hasher()
        h.combine(model.currentAdjustTarget?.id)
        h.combine(model.decoded.map(ObjectIdentifier.init))
        h.combine(try? JSONEncoder().encode(model.currentEdits))
        return h.finalize()
    }

    /// Objects (outside Adjust Objects): what it does, and opening it.
    private func objectsSection(_ e: EditState) -> some View {
        let count = e.shown.localAdjustments?.count ?? 0
        return PanelSection(title: "Objects", systemImage: "person.crop.rectangle") {
            Text(count == 0
                 ? "Change one object's light, color and detail on its own, leaving the rest of the picture as it is."
                 : "\(count == 1 ? "One object is" : "\(count) objects are") adjusted on their own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.beginAdjustingObjects()
            } label: {
                Label("Adjust Objects…", systemImage: "hand.point.up.left")
            }
            .controlSize(.small)
            .help(Prefs.makesCopy(.adjustObjects)
                  ? "Click an object and adjust it on its own; Done saves a copy, stacked on the original"
                  : "Click an object and adjust it on its own")
        }
    }

    /// In Adjust Objects: which object the sliders below change, a picture of it, and taking one's adjustments
    /// away (selecting another is in its bar under the picture).
    private func adjustingObjectsSection(_ object: AdjustTarget?) -> some View {
        let objects = model.adjustableObjects
        return PanelSection(title: "Adjust Objects", systemImage: "person.crop.rectangle") {
            if objects.count > 1 {
                Picker("Adjusting", selection: Binding(
                    get: { object?.id },
                    set: { id in if let o = objects.first(where: { $0.id == id }) { model.adjustTarget = o } }
                )) {
                    ForEach(Array(objects.enumerated()), id: \.element.id) { index, o in
                        Text("Object \(index + 1)").tag(Optional(o.id))
                    }
                }
                .help("Which object the sliders below change")
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
                Text("Under the picture, Edit Selection… changes what's selected and Select Another… adds an object.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let object {
                    Button(role: .destructive) {
                        model.removeObjectFromSession(object)
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
        model.changeObjects { e in
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

    /// Straightening and tilting without opening the crop tool: what they turn out of the frame is cropped away
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
            slider("Vertical", \.vertical, Tilt.range, format: { String(format: "%+.1f°", $0) }, undoName: "Vertical Perspective")
                .help("Tilt the picture's top forward or back, to make lines that should be upright (a building's sides) upright")
            slider("Horizontal", \.horizontal, Tilt.range, format: { String(format: "%+.1f°", $0) }, undoName: "Horizontal Perspective")
                .help("Tilt the picture's side forward or back, to square up something photographed from one side")
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
        let objectMode = model.isAdjustingObjects
        let object = objectMode ? model.currentAdjustTarget.flatMap { LocalAdjustment.keys.contains(keyPath) ? $0 : nil } : nil
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
                    dragStart = nil
                    // (In Adjust Objects, a step of its own: Cancel and Done take or keep them all.)
                    if objectMode { return model.changeObjects(from: start) }
                    model.commitEdits(from: start, actionName: undoName ?? title)
                    // (Straightening or tilting an extended photo makes its extension again.)
                    model.refillExtensionIfNeeded()
                }
            },
            reset: {
                if objectMode { model.changeObjects { set(&$0, resetValue) } } else { model.updateEdits("Reset \(undoName ?? title)") { set(&$0, resetValue) } }
            }
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
    let title: String
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
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 84)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
