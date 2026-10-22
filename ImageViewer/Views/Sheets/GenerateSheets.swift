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
