import SwiftUI

/// Names a preset: saving the picture's adjustments as one (a name already used replaces that preset, after
/// saying so), or renaming one.
struct PresetNameSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let naming: PresetNaming
    @State private var name = ""

    private var store: PresetStore { .shared }

    private var renaming: AdjustmentPreset? {
        if case .rename(let preset) = naming.kind { return preset }
        return nil
    }

    /// Another preset already called what's typed.
    private var taken: AdjustmentPreset? { store.preset(named: name, except: renaming?.id) }

    private var canFinish: Bool {
        !PresetStore.clean(name).isEmpty && !(renaming != nil && taken != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(renaming.map { "Rename “\($0.name)”" } ?? "Save as Preset")
                .font(.headline)
                .lineLimit(1).truncationMode(.middle)
            if renaming == nil {
                Text("This picture's light, color, white balance, detail and filter, to put on other pictures with a click (Presets in the Adjust panel, or Image ▸ Apply Preset). Its crop, turn and retouching aren't included.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(finish)
            Group {
                if let taken {
                    Text(renaming == nil ? "This replaces the preset “\(taken.name)”." : "Another preset is called “\(taken.name)”.")
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            .foregroundStyle(renaming == nil ? Color.secondary : Color.orange)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(renaming != nil ? "Rename" : taken != nil ? "Replace" : "Save", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canFinish)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            name = renaming?.name ?? Self.newName(in: store)
        }
    }

    private func finish() {
        guard canFinish else { return }
        switch naming.kind {
        case .save(let edits):
            let preset = store.save(name, edits: edits)
            model.showToast("Saved the preset “\(preset.name)”", systemImage: "camera.filters")
        case .rename(let preset):
            store.rename(preset.id, to: name)
        }
        dismiss()
    }

    /// "Preset 1", "Preset 2"…: the first not yet used.
    static func newName(in store: PresetStore) -> String {
        var n = store.presets.count + 1
        while store.preset(named: "Preset \(n)") != nil { n += 1 }
        return "Preset \(n)"
    }
}
