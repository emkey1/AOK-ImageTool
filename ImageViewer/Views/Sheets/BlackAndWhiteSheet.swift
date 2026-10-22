import SwiftUI

/// Image ▸ Black & White…: a camera filter and toning, previewed, for a black and white copy saved next to
/// the original (which stays as it is).
struct BlackAndWhiteSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bw = BlackAndWhite.last
    @State private var base: CGImage?
    @State private var preview: CGImage?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Black & White", systemImage: "circle.lefthalf.filled").font(.title2.weight(.bold))
            Text("Saves a black and white copy next to the original, stacked on top of it.")
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
                if let shown = preview ?? base {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    ProgressView()
                }
            }
            .frame(minHeight: 240, maxHeight: .infinity)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Filter").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Filter", selection: $bw.filter) {
                            ForEach(BlackAndWhite.Filter.allCases) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(bw.filter.help).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Toning").foregroundStyle(.secondary)
                    Picker("Toning", selection: $bw.toning) {
                        ForEach(BlackAndWhite.Toning.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                GridRow {
                    Text("Amount").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $bw.toningAmount, in: 0...1)
                        Text("\(Int(bw.toningAmount * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    .frame(maxWidth: 320)
                    .disabled(bw.toning == .none)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Copy") {
                    model.saveBlackAndWhite(bw)
                    dismiss()
                }
                .prominentButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(base == nil)
            }
        }
        .padding(20)
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task(id: model.decoded?.url) {
            // (Again once the image has decoded, if it hadn't when the sheet opened.)
            guard let d = model.decoded, d.url == model.currentURL else { return }
            let e = model.currentEdits
            base = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                try? await MaskStore.shared.prepare(e, for: d)
                return EditRenderer.shared.renderSync(d, edits: e, maxDimension: 1600)?.image
            }.value
            updatePreview()
        }
        .onChange(of: bw) { updatePreview() }
    }

    /// Most of the window's height, for the preview.
    private var sheetSize: CGSize {
        let window = model.window?.contentLayoutRect.size ?? CGSize(width: 1280, height: 840)
        let height = max(520, window.height * 0.8)
        return CGSize(width: min(max(640, height * 0.9), window.width * 0.9), height: height)
    }

    private func updatePreview() {
        guard let base else { return }
        let bw = self.bw
        previewTask?.cancel()
        previewTask = Task {
            let made = await Task.detached(priority: .userInitiated) { EditRenderer.shared.blackAndWhite(base, bw) }.value
            if !Task.isCancelled { preview = made }
        }
    }
}
