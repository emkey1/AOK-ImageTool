import SwiftUI

/// Progress of a generation, updated from the background.
@MainActor @Observable
private final class SheetProgress {
    var value: Double?
}

/// A picture made on this Mac, shown large, with progress over it while it's being made.
private struct GeneratedPreview: View {
    let image: CGImage?
    let placeholder: CGImage?
    let progress: Double?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
            if let shown = image ?? placeholder {
                Image(decorative: shown, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .opacity(image == nil ? 0.45 : 1)
                    .padding(6)
            }
            if let progress {
                VStack(spacing: 8) {
                    ProgressView(value: progress).frame(width: 180)
                    Text("Generating on this Mac… \(Int(progress * 100))%").font(.callout).monospacedDigit()
                }
                .padding(14)
                .glassBackground(in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(minHeight: 240, maxHeight: .infinity)
    }
}

/// Intelligence ▸ Background ▸ Generate on This Mac: a scene painted around the cut-out subject, from a
/// description of the scene and of the subject (which Apple Intelligence suggests), so the scene suits it.
struct GenerateBackgroundSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var source: BackgroundSource?
    @State private var subject = ""
    @State private var describing = false
    @State private var scene = ""
    @State private var result: CGImage?
    @State private var progress = SheetProgress()
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    private static let suggestions = ["a sunny beach with palm trees", "a mountain lake at sunrise", "a city street at night",
                                      "an autumn forest", "a cozy living room", "a soft gray studio backdrop", "a field of wildflowers"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Generate a Background", systemImage: "sparkles").font(.title2.weight(.bold))
            Text("Made on this Mac, and painted around your subject so the scene suits it.")
                .foregroundStyle(.secondary)
            GeneratedPreview(image: result, placeholder: source?.cutout, progress: progress.value)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Subject").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField(describing ? "Describing…" : "What's in front, e.g. “a woman in a turquoise shirt”", text: $subject)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Background").foregroundStyle(.secondary)
                    TextField("Describe the scene, e.g. “a sunny beach with palm trees”", text: $scene)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(generate)
                }
            }
            FlowLayout(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button(s) { scene = s }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(result == nil ? "Generate" : "Try Again", action: generate)
                    .disabled(scene.trimmingCharacters(in: .whitespaces).isEmpty || source == nil || progress.value != nil)
                if let result {
                    Button("Use Background") {
                        model.useGeneratedBackground(result)
                        close()
                    }
                    .prominentButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(progress.value != nil)
                }
            }
        }
        .padding(20)
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task {
            source = await model.backgroundSource()
            guard let cutout = source?.cutout, subject.isEmpty else { return }
            describing = true
            let labels = ImageDescriber.support == .vision ? [] : await VisionServices.classify(cutout)
            let described = await ImageDescriber.describeSubject(cutout, labels: labels)
            describing = false
            if subject.isEmpty, let described { subject = described }
        }
    }

    /// About 90% of the window's height (the preview takes the room), and wide enough to match.
    private var sheetSize: CGSize {
        let window = model.window?.contentLayoutRect.size ?? CGSize(width: 1280, height: 840)
        let height = max(560, window.height * 0.9)
        return CGSize(width: min(max(640, height * 0.85), window.width * 0.9), height: height)
    }

    private func generate() {
        guard let source, task == nil else { return }
        let scene = self.scene, subject = self.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let progress = self.progress
        let flag = CancelFlag()
        error = nil
        progress.value = 0
        task = Task {
            defer {
                progress.value = nil
                task = nil
            }
            do {
                let made = try await withTaskCancellationHandler {
                    try await GenerativeImage.background(source.photo, subject: source.subject, scene: scene,
                                                         subjectDescription: subject.isEmpty ? nil : subject,
                                                         seed: UInt64.random(in: 1...UInt64.max)) { fraction in
                        Task { @MainActor in if progress.value != nil { progress.value = fraction } }
                        return flag.isSet
                    }
                } onCancel: { flag.set() }
                guard !Task.isCancelled else { return }
                result = made
            } catch ExtendError.cancelled {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func close() {
        task?.cancel()
        dismiss()
    }
}

/// File ▸ New Image from Description: a picture painted from a description, on this Mac. Previews come one at a
/// time; the one kept is finished at full size and saved as a new image. Image Playground makes it in its own
/// styles instead, where the Mac has it.
struct NewImageSheet: View {
    private struct Preview: Identifiable {
        let id: Int
        let seed: UInt64
        var image: CGImage?
    }

    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrefKey.newImageShape) private var shapeName = GenerativeImage.Shape.square.rawValue
    @State private var text = ""
    @State private var previews: [Preview] = []
    /// What the previews show (the description and shape they were made for).
    @State private var made = ""
    @State private var madeShape = GenerativeImage.Shape.square
    @State private var chosen: Int?
    @State private var progress = SheetProgress()
    /// The preview being painted, or (`finishing`) the one kept being finished.
    @State private var painting: Int?
    @State private var finishing = false
    @State private var task: Task<Void, Never>?
    /// Each job's number, so one that's stopped doesn't tidy away the one after it.
    @State private var job = 0
    @State private var error: String?
    @State private var installed = GenerativeModel.isInstalled

    private static let count = 4
    private static let suggestions = ["a lighthouse on a rocky coast at sunset", "a red fox in fresh snow", "a cozy cabin in an autumn forest",
                                      "a bowl of ripe peaches on a wooden table", "a city street in the rain at night", "a watercolor of a sailboat"]

    private var shape: GenerativeImage.Shape { GenerativeImage.Shape(rawValue: shapeName) ?? .square }
    private var description: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var busy: Bool { painting != nil || finishing }
    private var chosenImage: CGImage? { previews.first { $0.id == chosen }?.image }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New Image", systemImage: "wand.and.stars").font(.title2.weight(.bold))
            Text("Describe a picture and it's painted on this Mac. Pick the one you like: it's finished at full size and saved as a new image "
                 + (model.folderURL == nil ? "in Pictures." : "in this folder."))
                .foregroundStyle(.secondary)
            TextField("Describe the picture, e.g. “a lighthouse on a rocky coast at sunset”", text: $text, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(generate)
            FlowLayout(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button(s) { text = s }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }
            HStack(spacing: 10) {
                Picker("Shape", selection: $shapeName) {
                    ForEach(GenerativeImage.Shape.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .disabled(busy)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text(status).monospacedDigit().foregroundStyle(.secondary)
                    Button("Stop") { task?.cancel() }
                        .controlSize(.small)
                }
            }
            if installed {
                tiles
            } else {
                missingModel
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if PlaygroundSupport.isAvailable {
                    Button("Illustration, Animation or Sketch…") { openPlayground() }
                        .disabled(description.isEmpty || busy)
                        .help("Make it in Image Playground instead, in one of its styles")
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(previews.isEmpty ? "Generate" : "Generate Again", action: generate)
                    .keyboardShortcut(chosenImage == nil ? .defaultAction : nil)
                    .disabled(description.isEmpty || busy || !installed)
                Button("Keep", action: keep)
                    .prominentButtonStyle()
                    .keyboardShortcut(chosenImage != nil ? .defaultAction : nil)
                    .disabled(chosenImage == nil || finishing)
                    .help("Finish this one at full size and save it as a new image")
            }
        }
        .padding(20)
        .frame(width: sheetSize.width, height: sheetSize.height)
        .onAppear {
            text = model.newImageDescription
            // (The Guide's screenshot: previews being painted.)
            if DebugHooks.scene == "newimage" { DispatchQueue.main.async { generate() } }
        }
        .onChange(of: text) { model.newImageDescription = text }
        .onChange(of: ModelDownloads.shared.installCount) { installed = GenerativeModel.isInstalled }
    }

    private var status: String {
        let percent = "\(Int((progress.value ?? 0) * 100))%"
        if finishing { return "Finishing at full size… \(percent)" }
        return "Painting \((painting ?? 0) + 1) of \(Self.count)… \(percent)"
    }

    /// The previews, two by two, as big as the room allows.
    private var tiles: some View {
        GeometryReader { geo in
            let aspect = CGFloat(madeShape.workingSize.width) / CGFloat(madeShape.workingSize.height)
            let spacing: CGFloat = 10
            let width = min((geo.size.width - spacing) / 2, (geo.size.height - spacing) / 2 * aspect)
            let height = width / aspect
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { column in
                            tile(row * 2 + column).frame(width: width, height: height)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func tile(_ index: Int) -> some View {
        let preview = previews.indices.contains(index) ? previews[index] : nil
        let selected = preview != nil && chosen == preview?.id
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.12))
            if let image = preview?.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(3)
            } else if painting == index {
                ProgressView(value: progress.value ?? 0)
                    .progressViewStyle(.circular)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard preview?.image != nil else { return }
            chosen = preview?.id
            keep()
        }
        .onTapGesture { if preview?.image != nil, !finishing { chosen = preview?.id } }
    }

    private var missingModel: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("Pictures are painted by \(GenerativeModel.displayName), which runs on this Mac: a one-time download of \(DownloadableModel.generativeFill.formattedSize).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Get the Model…") { model.offerDownload(.generativeFill) {} }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    /// About 90% of the window's height, and wide enough for the previews.
    private var sheetSize: CGSize {
        let window = model.window?.contentLayoutRect.size ?? CGSize(width: 1280, height: 840)
        let height = max(600, window.height * 0.9)
        return CGSize(width: min(max(680, height * 0.95), window.width * 0.9), height: height)
    }

    /// A new set of previews, painted one after another.
    private func generate() {
        let description = self.description, shape = self.shape
        guard !description.isEmpty, installed, !busy else { return }
        previews = (0..<Self.count).map { Preview(id: $0, seed: .random(in: 1...UInt64.max)) }
        made = description
        madeShape = shape
        chosen = nil
        error = nil
        let seeds = previews.map(\.seed)
        job += 1
        let mine = job, progress = self.progress, flag = CancelFlag()
        task = Task {
            defer {
                if job == mine {
                    painting = nil
                    progress.value = nil
                    task = nil
                }
            }
            for (i, seed) in seeds.enumerated() {
                guard !Task.isCancelled else { return }
                painting = i
                progress.value = 0
                do {
                    let image = try await withTaskCancellationHandler {
                        try await GenerativeImage.picture(description, shape: shape, seed: seed) { fraction in
                            Task { @MainActor in if progress.value != nil { progress.value = fraction } }
                            return flag.isSet
                        }
                    } onCancel: { flag.set() }
                    guard !Task.isCancelled, job == mine else { return }
                    previews[i].image = image
                    if chosen == nil { chosen = i }
                } catch {
                    if !Task.isCancelled, (error as? ExtendError) != .cancelled { self.error = error.localizedDescription }
                    return
                }
            }
        }
    }

    /// The chosen preview, finished at full size and saved; the rest aren't painted.
    private func keep() {
        guard let preview = previews.first(where: { $0.id == chosen }), let image = preview.image, !finishing else { return }
        task?.cancel()
        let description = made
        job += 1
        let mine = job, progress = self.progress, flag = CancelFlag()
        painting = nil
        finishing = true
        error = nil
        progress.value = 0
        task = Task {
            defer {
                if job == mine {
                    finishing = false
                    progress.value = nil
                    task = nil
                }
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await GenerativeImage.finished(image, description: description, seed: preview.seed) { fraction in
                        Task { @MainActor in if progress.value != nil { progress.value = fraction } }
                        return flag.isSet
                    }
                } onCancel: { flag.set() }
                guard !Task.isCancelled else { return }
                model.saveNewImage(result, description: description)
                dismiss()
            } catch {
                if !Task.isCancelled, (error as? ExtendError) != .cancelled { self.error = error.localizedDescription }
            }
        }
    }

    /// The description handed to Image Playground, for its own styles.
    private func openPlayground() {
        model.newImageDescription = description
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showNewImagePlayground = true }
    }

    private func close() {
        task?.cancel()
        dismiss()
    }
}
