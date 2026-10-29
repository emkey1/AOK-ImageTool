import SwiftUI
import UniformTypeIdentifiers

/// Intelligence ▸ Combine Pictures…: a foreground picture's subject, its background removed, laid on a
/// background picture. Drag it to move it, pinch (or Size) to size it; its light can be matched to the new
/// background and a soft shadow put under it. Saved as a copy of the background.
struct CombineSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: CombineRequest

    /// A picture in one of the two places, as it shows here (edits applied), with a small copy to preview with.
    private struct Picture {
        let url: URL
        let decoded: DecodedImage
        let full: CGImage
        let preview: CGImage
        let transparent: Bool
    }

    private enum Role { case background, foreground }

    @State private var background: Picture?
    @State private var foreground: Picture?
    /// The subject as lifted, and as shown (with what's been erased from it), full size and preview size.
    @State private var lifted: Combine.Subject?
    @State private var liftedPreview: Combine.Subject?
    @State private var subject: Combine.Subject?
    @State private var subjectPreview: Combine.Subject?
    @State private var strokes: [Combine.Stroke] = []
    @State private var erasing = false
    @State private var brush = 0.04
    @State private var painting = false
    @State private var lastErase = Date.distantPast
    @State private var pointer: CGPoint?
    @State private var layout: Combine.Layout?
    @State private var matchLighting = 0.6
    @State private var shadow = 0.0
    @State private var composite: CGImage?
    @State private var compositeFor: Combine.Layout?
    @State private var rendering: Task<Void, Never>?
    @State private var dragStart: Combine.Layout?
    @State private var pinchStart: Double?
    @State private var working: String?
    @State private var error: String?
    @State private var choosing: Role?

    private static let previewSide: CGFloat = 1600

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Combine Pictures", systemImage: "square.2.layers.3d").font(.title2.weight(.bold))
            Text(erasing ? "Paint over what shouldn't be part of the subject to take it away; ⌥-paint puts it back."
                         : "The foreground picture's subject, its background removed, on the background picture. Drag it to move it; pinch, or use Size, to size it.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                slot(.background, title: "Background", picture: background)
                Button { swap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                    .disabled(background == nil || foreground == nil || working != nil)
                    .help("Use the background's subject on the foreground instead")
                slot(.foreground, title: "Foreground", picture: foreground)
            }
            canvas
            controls
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if let working {
                    ProgressView().controlSize(.small)
                    Text(working).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Combined") { save() }
                    .prominentButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(background == nil || subject == nil || layout == nil || working != nil)
                    .help("Save it as a new picture beside the background, stacked with it")
            }
        }
        .padding(20)
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task { await start() }
        .onChange(of: layout) { render() }
        .onChange(of: matchLighting) { render() }
        .onChange(of: shadow) { render() }
        .onChange(of: strokes) { if !painting { render() } }
    }

    private var sheetSize: CGSize {
        let window = model.window?.contentLayoutRect.size ?? CGSize(width: 1280, height: 840)
        let height = max(620, window.height * 0.9)
        return CGSize(width: max(760, min(window.width * 0.9, height * 1.3)), height: height)
    }

    // MARK: The pictures

    private func slot(_ role: Role, title: String, picture: Picture?) -> some View {
        HStack(spacing: 8) {
            Group {
                if let picture {
                    Image(decorative: picture.preview, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 44, height: 44)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(picture?.url.lastPathComponent ?? "None").lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button("Choose…") { choosing = role }
                .disabled(working != nil)
                .popover(isPresented: Binding(get: { choosing == role }, set: { if !$0 { choosing = nil } })) {
                    chooser(role)
                }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    /// The folder's pictures to pick from, or any file.
    private func chooser(_ role: Role) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role == .background ? "Choose the background" : "Choose the foreground (its subject is used)").font(.headline)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 5), spacing: 8) {
                    ForEach(model.items) { item in
                        ThumbnailView(item: item, tier: .small)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                            .onTapGesture { pick(item.url, as: role) }
                            .help(item.name)
                    }
                }
            }
            .frame(width: 84 * 5 + 8 * 4, height: 300)
            Button("Choose a File…") { chooseFile(as: role) }
        }
        .padding(12)
    }

    private func chooseFile(as role: Role) {
        choosing = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = role == .background ? "Choose the background picture" : "Choose the picture whose subject goes in front"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pick(url, as: role)
    }

    private func pick(_ url: URL, as role: Role) {
        choosing = nil
        error = nil
        Task { await load(url, as: role) }
    }

    // MARK: Loading

    private func start() async {
        if let url = request.background { await load(url, as: .background, findSubject: false) }
        if let url = request.foreground { await load(url, as: .foreground) }
        // (The picture with no subject is the background: two picked the other way round are swapped.)
        if subject == nil, foreground != nil, let background, (try? await Combine.subject(of: background.full, transparent: background.transparent)) != nil {
            swap()
        } else if background == nil, subject == nil, let foreground {
            self.foreground = nil
            self.background = foreground
            error = "“\(foreground.url.lastPathComponent)” has no subject to lift: it's the background. Choose the foreground."
        }
    }

    private func load(_ url: URL, as role: Role, findSubject: Bool = true) async {
        working = "Opening “\(url.lastPathComponent)”…"
        defer { working = nil }
        do {
            let (decoded, full, transparent) = try await model.combinePicture(url)
            let preview = await Task.detached { Combine.reduced(full, longSide: Self.previewSide) }.value
            let picture = Picture(url: url, decoded: decoded, full: full, preview: preview, transparent: transparent)
            switch role {
            case .background:
                background = picture
                placeSubject()
            case .foreground:
                foreground = picture
                subject = nil
                subjectPreview = nil
                if findSubject { await liftSubject() }
            }
        } catch {
            self.error = "Couldn't open “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// The foreground's subject, at full size and preview size.
    private func liftSubject() async {
        guard let foreground else { return }
        working = "Finding the subject in “\(foreground.url.lastPathComponent)”…"
        defer { working = nil }
        do {
            let lifted = try await Combine.subject(of: foreground.full, transparent: foreground.transparent)
            let small = await Task.detached { Combine.reduced(lifted.image, longSide: 1200) }.value
            self.lifted = lifted
            liftedPreview = Combine.Subject(image: small, rect: lifted.rect)
            strokes = []
            subject = lifted
            subjectPreview = liftedPreview
            layout = nil
            placeSubject()
        } catch {
            subject = nil
            subjectPreview = nil
            lifted = nil
            liftedPreview = nil
            self.error = "No subject found in “\(foreground.url.lastPathComponent)”. Choose another foreground, or Swap."
        }
    }

    /// Where the subject starts: where it was in its own picture.
    private func placeSubject() {
        guard let subject, let background else { return }
        if layout == nil {
            layout = .initial(for: subject, on: CGSize(width: background.full.width, height: background.full.height))
        }
        render()
    }

    private func swap() {
        let (b, f) = (background, foreground)
        background = f
        foreground = b
        layout = nil
        composite = nil
        subject = nil
        subjectPreview = nil
        lifted = nil
        liftedPreview = nil
        strokes = []
        error = nil
        Task { await liftSubject() }
    }

    // MARK: The canvas

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.1))
                if let background {
                    let size = CGSize(width: background.preview.width, height: background.preview.height)
                    let fit = min(geo.size.width / size.width, geo.size.height / size.height)
                    let shown = CGSize(width: size.width * fit, height: size.height * fit)
                    ZStack(alignment: .topLeading) {
                        // The lit composite once it's made; the plain pictures while dragging or making it.
                        if let composite, compositeFor == layout, dragStart == nil, pinchStart == nil, !painting {
                            Image(decorative: composite, scale: 1).resizable()
                        } else {
                            Image(decorative: background.preview, scale: 1).resizable()
                            if let subjectPreview, let layout {
                                let r = layout.rect(for: subjectPreview, on: size)
                                Image(decorative: subjectPreview.image, scale: 1).resizable()
                                    .scaleEffect(x: layout.flipped ? -1 : 1, y: 1)
                                    .frame(width: r.width * shown.width, height: r.height * shown.height)
                                    .offset(x: r.minX * shown.width, y: r.minY * shown.height)
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if erasing, let pointer, let layout {
                            let d = brush * layout.height * shown.height * 2
                            Circle().strokeBorder(.white, lineWidth: 1.5).shadow(radius: 1)
                                .frame(width: d, height: d)
                                .offset(x: pointer.x - d / 2, y: pointer.y - d / 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: shown.width, height: shown.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { pointer = p } else { pointer = nil }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard let layout else { return }
                        if erasing { return paint(at: value.location, shown: shown, size: size) }
                        guard value.translation != .zero else { return }
                        let start = dragStart ?? layout
                        dragStart = start
                        var moved = start
                        moved.center = CGPoint(x: min(max(start.center.x + value.translation.width / shown.width, 0), 1),
                                               y: min(max(start.center.y + value.translation.height / shown.height, 0), 1))
                        self.layout = moved
                    }.onEnded { _ in
                        dragStart = nil
                        if painting {
                            painting = false
                            applyErasing()
                        }
                        render()
                    })
                    .simultaneousGesture(MagnifyGesture().onChanged { value in
                        guard let layout else { return }
                        let start = pinchStart ?? layout.height
                        pinchStart = start
                        self.layout?.height = min(max(start * value.magnification, 0.05), 2)
                    }.onEnded { _ in
                        pinchStart = nil
                        render()
                    })
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("Choose a background picture").foregroundStyle(.secondary)
                        Button("Choose…") { choosing = .background }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Text("Size")
                Slider(value: Binding(get: { layout?.height ?? 0.5 }, set: { layout?.height = $0 }), in: 0.05...1.5)
                    .frame(width: 140)
            }
            Button { layout?.flipped.toggle() } label: { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            Toggle(isOn: $erasing) { Label("Erase", systemImage: "eraser") }
                .toggleStyle(.button)
                .help("Paint over parts of the subject to take them away (⌥ to put them back)")
            if erasing {
                Slider(value: $brush, in: 0.01...0.15).frame(width: 80)
                    .help("Brush size")
                Button("Reset") {
                    strokes = []
                    applyErasing()
                    render()
                }
                .disabled(strokes.isEmpty)
            }
            HStack(spacing: 6) {
                Text("Match Lighting")
                Slider(value: $matchLighting, in: 0...1).frame(width: 120)
            }
            .help("Move the subject's brightness and color toward the background's, and let its light wrap the edges")
            HStack(spacing: 6) {
                Text("Shadow")
                Slider(value: $shadow, in: 0...1).frame(width: 100)
            }
            .help("A soft shadow under the subject")
            Spacer()
        }
        .disabled(layout == nil)
    }

    /// A brush stroke over the subject, where the pointer is (`location` in the shown canvas).
    private func paint(at location: CGPoint, shown: CGSize, size: CGSize) {
        guard let layout, let subjectPreview else { return }
        let r = layout.rect(for: subjectPreview, on: size)
        var p = CGPoint(x: (location.x / shown.width - r.minX) / r.width, y: (location.y / shown.height - r.minY) / r.height)
        if layout.flipped { p.x = 1 - p.x }
        if !painting {
            painting = true
            strokes.append(Combine.Stroke(points: [p], radius: brush, restore: NSEvent.modifierFlags.contains(.option)))
        } else if !strokes.isEmpty {
            strokes[strokes.count - 1].points.append(p)
        }
        // (Shown as it goes, a few times a second.)
        if Date().timeIntervalSince(lastErase) > 0.05 {
            lastErase = Date()
            applyErasing()
        }
    }

    /// The preview's subject with the strokes applied (the full-size one is made when saving).
    private func applyErasing() {
        guard let liftedPreview else { return }
        subjectPreview = Combine.erased(liftedPreview, by: strokes)
    }

    /// The lit composite at preview size, made after a change settles.
    private func render() {
        rendering?.cancel()
        guard dragStart == nil, pinchStart == nil, let background, let subjectPreview, let layout else { return }
        let (lighting, shade) = (matchLighting, shadow)
        rendering = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let made = await Task.detached(priority: .userInitiated) {
                Combine.compose(background: background.preview, subject: subjectPreview, layout: layout, matchLighting: lighting, shadow: shade)
            }.value
            guard !Task.isCancelled else { return }
            composite = made
            compositeFor = layout
        }
    }

    private func save() {
        guard let background, let lifted, let layout else { return }
        let subject = Combine.erased(lifted, by: strokes)
        model.saveCombined(background: background.url, decoded: background.decoded, subject: subject, layout: layout,
                           matchLighting: matchLighting, shadow: shadow)
        dismiss()
    }
}
