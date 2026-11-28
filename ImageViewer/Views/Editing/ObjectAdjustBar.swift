import SwiftUI

/// Adjust Objects' bar under the picture: which object the Adjust panel's sliders are changing, selecting
/// another, its steps, and Cancel and Done (Done saves a copy, as Remove Objects does).
struct ObjectAdjustBar: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .allowsHitTesting(false)
            HStack(spacing: 10) {
                Image(systemName: "person.crop.rectangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                HStack(spacing: 2) {
                    Button { model.undoObjectChange() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(model.objectSession?.undo.isEmpty ?? true)
                        .help("Undo (⌘Z)")
                    Button { model.redoObjectChange() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(model.objectSession?.redo.isEmpty ?? true)
                        .help("Redo (⇧⌘Z)")
                }
                Button("Edit Selection…") {
                    if let target = model.currentAdjustTarget { model.editSelection(of: target) }
                }
                .disabled(model.currentAdjustTarget == nil)
                .help("Change what's selected: paint in what was missed, or take away what shouldn't be adjusted")
                Button("Select Another…") { model.activeTool = .selectToAdjust }
                    .help("Click another object, or paint over it, to adjust it on its own")
                Button("Cancel") { model.cancelAdjustingObjects() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { model.finishAdjustingObjects() }
                    .prominentButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .help(doneHelp)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCommit)) { note in
            if note.object as AnyObject? === model { model.finishAdjustingObjects() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCancel)) { note in
            if note.object as AnyObject? === model { model.cancelAdjustingObjects() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolUndo)) { note in
            if note.object as AnyObject? === model { model.undoObjectChange() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolRedo)) { note in
            if note.object as AnyObject? === model { model.redoObjectChange() }
        }
    }

    private var message: String {
        let objects = model.adjustableObjects
        guard let t = model.currentAdjustTarget, let index = objects.firstIndex(where: { $0.id == t.id }) else {
            return "Select an object to adjust."
        }
        let which = objects.count > 1 ? "Object \(index + 1) of \(objects.count)" : "The object"
        return "\(which): the Adjust panel's sliders change it alone."
    }

    private var doneHelp: String {
        let name = model.currentURL.map { $0.deletingPathExtension().lastPathComponent } ?? "the picture"
        return Prefs.makesCopy(.adjustObjects)
            ? "Save “\(name) (Adjusted)”, stacked on the original, which stays as it was"
            : "Keep the adjustments as an edit of the picture (Settings ▸ Editing ▸ Copies)"
    }
}
