import SwiftUI
import UniformTypeIdentifiers

/// Intelligence ▸ Stitch Pictures…: pictures taken from one spot, the camera turned between them, joined into
/// one. They're lined up by what they show; the result can be kept flat (straight lines stay straight) or
/// wrapped (for wide views), leveled, tilted and turned; and what no picture covers is cropped away or filled.
/// Saved as a copy of the first picture.
struct StitchSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: StitchRequest

    /// A picture in the set, as it shows here (edits applied), at the size it's worked with while the sheet is open.
    private struct Entry: Identifiable {
        let id = UUID()
        let url: URL
        let decoded: DecodedImage
        let picture: Stitch.Picture
        let thumbnail: CGImage?
    }

    /// How far a fill has got, read a few times a second while it's being made (the fill runs off the main actor).
    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        var fraction: Double {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @State private var entries: [Entry] = []
    @State private var layout: Stitch.Layout?
    @State private var look = Stitch.Look()
    @State private var edges = StitchEdges.crop
    @State private var method = GenerativeModel.isSupported ? Prefs.preferredExtendMethod : .match
    @State private var preview: Stitch.Stitched?
    @State private var previewFor: Stitch.Look?
    @State private var filling: Stitch.Filling?
    @State private var filled: CGImage?
    @State private var fullSize: CGSize?
    @State private var seed: UInt64 = 1
    @State private var working: String?
    @State private var progress: Double?
    @State private var error: String?
    @State private var rendering: Task<Void, Never>?
    @State private var job: Task<Void, Never>?
    @State private var cancel: CancelFlag?
    @State private var adding = false

    private static let previewSide = 1800

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Stitch Pictures", systemImage: "rectangle.split.3x1").font(.title2.weight(.bold))
            Text("Pictures taken from one spot, the camera turned between them, joined into one. Flat keeps straight lines straight; Level, Tilt and Turn re-aim the view.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            strip
            canvas
            controls
            if let message = error ?? note {
                Text(message).font(.caption).foregroundStyle(error != nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let working {
                    if let progress {
                        ProgressView(value: progress).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(working).foregroundStyle(.secondary)
                    if cancel != nil {
                        Button("Stop") { cancel?.set() }.controlSize(.small)
                    }
                } else if let size = savedSize {
                    Text("Makes a picture \(Int(size.width).formatted()) × \(Int(size.height).formatted()) pixels").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    cancel?.set()
                    job?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save Stitched") { save() }
                    .prominentButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .help(edges == .fill && !canSave ? "Fill what the pictures don't cover first, or choose Crop"
                                                           : "Save it as a new picture beside the first one, stacked with it")
            }
        }
        .padding(20)
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task { await start() }
        .onChange(of: look) { render() }
        .onDisappear {
            cancel?.set()
            job?.cancel()
            rendering?.cancel()
        }
    }

    private var sheetSize: CGSize {
        let window = model.window?.contentLayoutRect.size ?? CGSize(width: 1280, height: 840)
        let height = max(620, window.height * 0.9)
        return CGSize(width: max(820, min(window.width * 0.92, height * 1.5)), height: height)
    }

    private var canSave: Bool {
        guard working == nil, let preview, previewFor == look else { return false }
        // (With nothing uncovered there's nothing to fill: it's saved as it is.)
        return edges == .fill ? filling != nil || preview.coverage > 0.9995 : preview.covered != nil
    }

    /// What's said under the picture when nothing's wrong: which pictures were left out, and what was trimmed.
    private var note: String? {
        var parts: [String] = []
        if let layout {
            let out = entries.indices.filter { layout.onto[$0] == nil }.map { "“\(entries[$0].url.lastPathComponent)”" }
            if out.count == 1 {
                parts.append("\(out[0]) shows nothing the others do, and is left out.")
            } else if !out.isEmpty {
                parts.append("\(out.joined(separator: ", ")) show nothing the others do, and are left out.")
            }
        }
        if let preview, preview.trimmed, preview.shape == .flat {
            parts.append("The pictures take in too much to show flat: their far ends are left out. Cylinder or Sphere shows all of them.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// How big the saved picture will be.
    private var savedSize: CGSize? {
        guard let preview, let fullSize, previewFor == look else { return nil }
        guard edges == .crop else { return fullSize }
        guard let covered = preview.covered else { return nil }
        let s = fullSize.width / CGFloat(max(preview.image.width, 1))
        return CGSize(width: (covered.width * s).rounded(), height: (covered.height * s).rounded())
    }

    // MARK: The pictures

    private var strip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        let left = layout.map { $0.onto[index] == nil } ?? false
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let thumbnail = entry.thumbnail {
                                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "photo").foregroundStyle(.tertiary)
                                }
                            }
                            .frame(width: 64, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .opacity(left ? 0.4 : 1)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(left ? Color.orange : .clear, lineWidth: 1.5))
                            Button { remove(entry) } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(2)
                            .disabled(working != nil)
                            .help("Take “\(entry.url.lastPathComponent)” out")
                        }
                        .help(left ? "“\(entry.url.lastPathComponent)” shows nothing the others do" : entry.url.lastPathComponent)
                    }
                }
            }
            Button { adding = true } label: { Label("Add…", systemImage: "plus") }
                .disabled(working != nil)
                .popover(isPresented: $adding) { chooser }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    /// The folder's pictures to add, or any files.
    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add the pictures taken beside these").font(.headline)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 5), spacing: 8) {
                    ForEach(model.items) { item in
                        let chosen = entries.contains { $0.url == item.url }
                        ThumbnailView(item: item, tier: .small)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .opacity(chosen ? 0.35 : 1)
                            .contentShape(Rectangle())
                            .onTapGesture { if !chosen { add([item.url]) } }
                            .help(item.name)
                    }
                }
            }
            .frame(width: 84 * 5 + 8 * 4, height: 300)
            Button("Choose Files…") { chooseFiles() }
        }
        .padding(12)
    }

    private func chooseFiles() {
        adding = false
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose the pictures to stitch with these"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        let new = urls.filter { url in !entries.contains { $0.url == url } }
        guard !new.isEmpty, working == nil else { return }
        error = nil
        job = Task {
            await open(new)
            await lineUp()
        }
    }

    private func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        error = nil
        job = Task { await lineUp() }
    }

    // MARK: Lining up

    private func start() async {
        await open(request.urls)
        await lineUp()
        #if DEBUG
        // `-debugStitch flat,fill,generate,tilt=8`: the sheet as it is after those choices (for a look at it).
        guard let choices = UserDefaults.standard.string(forKey: "debugStitch")?.split(separator: ",").map(String.init) else { return }
        for choice in choices {
            let parts = choice.split(separator: "=").map(String.init)
            if let shape = Stitch.Shape(rawValue: choice) { look.shape = shape }
            if let chosen = ExtendMethod(rawValue: choice) { method = chosen }
            if choice == "fill" { edges = .fill }
            if parts.count == 2, let value = Double(parts[1]) {
                switch parts[0] {
                case "level": look.level = value
                case "tilt": look.tilt = value
                case "turn": look.turn = value
                default: break
                }
            }
        }
        if edges == .fill {
            for _ in 0..<100 where previewFor != look || preview == nil { try? await Task.sleep(for: .milliseconds(100)) }
            fill()
        }
        #endif
    }

    private func open(_ urls: [URL]) async {
        for url in urls {
            working = "Opening “\(url.lastPathComponent)”…"
            let edits = model.edits[url] ?? .identity
            let space = entries.first?.picture.space
            do {
                let opened = try await Task.detached(priority: .userInitiated) {
                    let (decoded, picture) = try await Stitch.open(url, edits: edits, maxSide: Stitch.workingSide, space: space)
                    return (decoded, picture, picture.image.map { VisionServices.downscaledSync($0, maxDimension: 192) })
                }.value
                entries.append(Entry(url: url, decoded: opened.0, picture: opened.1, thumbnail: opened.2))
            } catch {
                self.error = "Couldn't open “\(url.lastPathComponent)”: \(error.localizedDescription)"
            }
        }
        working = nil
    }

    /// Finds how the pictures lie on each other (again, after one is added or taken out).
    private func lineUp() async {
        layout = nil
        preview = nil
        previewFor = nil
        fullSize = nil
        dropFilling()
        guard entries.count >= 2 else {
            if error == nil { error = entries.isEmpty ? "Add the pictures to stitch." : "Add the pictures taken beside this one." }
            return
        }
        working = "Lining the pictures up…"
        let pictures = entries.map(\.picture)
        do {
            layout = try await Task.detached(priority: .userInitiated) { try Stitch.layout(of: pictures) }.value
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        working = nil
        render()
    }

    /// The stitched picture at preview size, made after a change settles.
    private func render() {
        rendering?.cancel()
        dropFilling()
        guard let layout else { return }
        let pictures = entries.map(\.picture), look = look
        rendering = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let made = await Task.detached(priority: .userInitiated) {
                (try? Stitch.render(pictures, layout: layout, look: look, maxSide: Self.previewSide),
                 Stitch.size(for: pictures, layout: layout, look: look))
            }.value
            guard !Task.isCancelled else { return }
            preview = made.0
            previewFor = look
            fullSize = made.1.map { CGSize(width: ($0.size.width * $0.fit).rounded(.up), height: ($0.size.height * $0.fit).rounded(.up)) }
            if made.0 == nil, error == nil { error = StitchError.failed.localizedDescription }
        }
    }

    // MARK: The canvas

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.1))
                if let preview {
                    let size = CGSize(width: preview.image.width, height: preview.image.height)
                    let fit = min((geo.size.width - 16) / size.width, (geo.size.height - 16) / size.height)
                    let shown = CGSize(width: size.width * fit, height: size.height * fit)
                    ZStack(alignment: .topLeading) {
                        Checkerboard().opacity(0.25)
                        Image(decorative: edges == .fill ? (filled ?? preview.image) : preview.image, scale: 1).resizable()
                        if edges == .crop, let covered = preview.covered {
                            // What's cropped away is dimmed; what's kept is outlined.
                            let kept = CGRect(x: covered.minX * fit, y: covered.minY * fit, width: covered.width * fit, height: covered.height * fit)
                            Path { path in
                                path.addRect(CGRect(origin: .zero, size: shown))
                                path.addRect(kept)
                            }
                            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                            Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1)
                                .frame(width: kept.width, height: kept.height)
                                .offset(x: kept.minX, y: kept.minY)
                        }
                    }
                    .frame(width: shown.width, height: shown.height)
                    .clipped()
                } else if working == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.split.3x1").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(entries.count < 2 ? "Add two or more pictures that overlap" : "Nothing to show").foregroundStyle(.secondary)
                        Button("Add…") { adding = true }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Light and dark squares, behind what no picture covers.
    private struct Checkerboard: View {
        var body: some View {
            Canvas { context, size in
                let side: CGFloat = 12
                for row in 0..<Int((size.height / side).rounded(.up)) {
                    for column in 0..<Int((size.width / side).rounded(.up)) where (row + column).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)), with: .color(.gray))
                    }
                }
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Picker("Shape", selection: $look.shape) {
                    ForEach(Stitch.Shape.allCases) { shape in
                        Text(shape == .automatic ? automaticTitle : shape.title).tag(shape)
                    }
                }
                .fixedSize()
                .help("Flat keeps straight lines straight, and stretches a wide view toward its sides. Cylinder suits a wide view, Sphere one that's tall as well: lines across them bend.")
                slider("Level", value: $look.level, range: -20...20, help: "Turn the picture to level it")
                slider("Tilt", value: $look.tilt, range: -40...40, help: "Look further up or down: makes upright lines lean together or stand straight")
                slider("Turn", value: $look.turn, range: -40...40, help: "Look further left or right")
                Button("Reset") { (look.level, look.tilt, look.turn) = (0, 0, 0) }
                    .disabled(look.isStraight)
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                Picker("Edges", selection: $edges) {
                    ForEach(StitchEdges.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Crop keeps the largest part the pictures cover. Fill keeps everything, and fills what they don't cover.")
                if edges == .fill {
                    Picker("With", selection: $method) {
                        // (Generate only where its model can run: on Apple silicon.)
                        ForEach(ExtendMethod.allCases.filter { $0 == .match || GenerativeModel.isSupported }) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    .help("Match Photo copies texture from the pictures. Generate draws what's missing with the model on this Mac, as Extend does.")
                    Button(filling == nil ? "Fill" : "Try Another") { fill() }
                        .disabled(working != nil || preview == nil || previewFor != look || (preview?.coverage ?? 1) > 0.9995)
                        .help(filling == nil ? "Fill what the pictures don't cover" : "Fill it again, differently")
                    if let preview, preview.coverage > 0.9995 {
                        Text("Nothing to fill").foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(layout == nil || working != nil)
        .onChange(of: method) { dropFilling() }
    }

    private var automaticTitle: String {
        guard look.shape == .automatic, let preview else { return Stitch.Shape.automatic.title }
        return "Automatic (\(preview.shape.title))"
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, help: String) -> some View {
        HStack(spacing: 6) {
            Text(title).fixedSize()
            Slider(value: value, in: range).frame(minWidth: 60, maxWidth: 130)
            Text("\(Int(value.wrappedValue.rounded()))°").monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
        .help(help)
    }

    // MARK: Filling and saving

    private func dropFilling() {
        filling = nil
        filled = nil
    }

    /// Fills what the pictures don't cover, on a canvas the size Extend fills at; shown on the preview.
    private func fill() {
        guard let layout, let first = entries.first else { return }
        if method == .generate, !GenerativeModel.isInstalled {
            // (Offered for download; chosen again once it's there.)
            return model.offerDownload(.generativeFill) { }
        }
        if filling != nil { seed = UInt64.random(in: 1...UInt64.max) }
        let pictures = entries.map(\.picture), look = look, method = method, seed = seed
        let edits = model.edits[first.url] ?? .identity, decoded = first.decoded
        let flag = CancelFlag(), meter = Meter()
        cancel = flag
        error = nil
        working = method == .generate ? "Generating what's missing…" : "Filling what's missing…"
        progress = method == .generate ? 0 : nil
        let watching = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if progress != nil { progress = meter.fraction }
            }
        }
        job = Task {
            defer {
                watching.cancel()
                working = nil
                progress = nil
                cancel = nil
            }
            do {
                let made = try await Task.detached(priority: .userInitiated) { () async throws -> (Stitch.Filling, CGImage?) in
                    let canvas = try Stitch.render(pictures, layout: layout, look: look, maxSide: Stitch.fillSide)
                    // (Generate is told the setting, as Extend's is; never the subject.)
                    let setting = method == .generate ? await ExtendRenderer.settingDescription(decoded, edits: edits) : nil
                    let filling = try await Stitch.fill(canvas, method: method, prompt: GenerativeExtend.prompt(nil, setting: setting), seed: seed) { fraction in
                        meter.fraction = fraction
                        return flag.isSet
                    }
                    let small = try Stitch.render(pictures, layout: layout, look: look, maxSide: Self.previewSide)
                    return (filling, Stitch.filled(small, with: filling))
                }.value
                guard self.look == look, self.method == method else { return }
                filling = made.0
                filled = made.1
            } catch StitchError.cancelled {
                return
            } catch {
                self.error = "Couldn't fill it: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        guard let layout, canSave else { return }
        let (joined, indices) = layout.joinedOnly()
        let kept = indices.map { entries[$0] }
        guard let first = kept.first else { return }
        let pictures = kept.map(\.picture)
        let fit = Stitch.size(for: pictures, layout: joined, look: look)?.fit ?? 1
        let filling = edges == .fill ? filling : nil
        model.saveStitched(kept.map(\.url), decoded: first.decoded, layout: joined, look: look, edges: filling == nil ? .crop : .fill, filling: filling,
                           fit: fit, space: first.picture.space)
        dismiss()
    }
}
