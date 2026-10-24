import Foundation

extension ViewerModel {
    // MARK: - Remove Objects

    /// Remove Objects needs a still, opaque picture (a see-through area has nothing to fill from, and a patch
    /// would cover only an animation's first frame).
    var canRemoveObjects: Bool {
        guard let url = currentURL, let d = decoded, d.url == url, activeTool == nil, !savingURLs.contains(url) else { return false }
        return !d.hasTransparentPixels && !d.isAnimated
    }

    /// Image ▸ Remove Objects…: opens the tool.
    func beginRemoveObjects() {
        guard canRemoveObjects else { return }
        viewMode = .viewer
        activeTool = .removeObjects
    }

    /// Image ▸ Change Objects…: opens Remove Objects' tool for changing what's marked (another color, or
    /// something else) instead.
    func beginChangeObjects() {
        guard canRemoveObjects else { return }
        viewMode = .viewer
        activeTool = .changeObjects
    }

    /// Image ▸ Clone & Heal…: opens Remove Objects' tool for painting with what's copied from elsewhere in the
    /// picture instead.
    func beginCloneHeal() {
        guard canRemoveObjects else { return }
        viewMode = .viewer
        activeTool = .cloneHeal
    }

    /// Done in Remove Objects (or Change Objects, or Clone & Heal: `operation`) with `removals` made: saved as
    /// "<name> (Retouched)" ("(Changed)"), stacked on the original (which stays as it was), or, with its copies
    /// turned off, kept as an edit of the image to save.
    func finishRemovingObjects(_ removals: [Removal], url: URL, decoded d: DecodedImage, operation: CopyOperation = .removeObjects) {
        let changed = operation == .changeObjects
        guard !removals.isEmpty, d.url == url else { return }
        let previous = edits[url] ?? .identity
        var result = previous
        result.removals = (previous.removals ?? []) + removals
        if Prefs.makesCopy(operation) {
            let kind = changed ? "changed" : "retouched"
            let failure = "Couldn't save a \(kind) copy of “\(url.lastPathComponent)”"
            let save: (EditState) -> Void = { [weak self] e in
                self?.saveCopy(of: url, decoded: d, edits: e, label: changed ? "Changed" : "Retouched", defaultFormat: .heic,
                               working: "Saving the \(kind) copy…", systemImage: changed ? "paintbrush" : operation == .cloneHeal ? "bandage" : "eraser",
                               failure: failure) { $0 }
            }
            guard result.needsExtendFill else { return save(result) }
            // An extended photo: its extension continues the retouched picture, so it's made again first.
            showToast("Extending…", systemImage: "arrow.up.left.and.arrow.down.right")
            Task {
                do {
                    let fill = try await ExtendRenderer.makeFill(d, edits: result)
                    var filled = result
                    filled.extendFill = fill.extendFill(try ExtendFillStore.save(fill.fill))
                    save(filled)
                } catch {
                    dismissToast()
                    showError(failure, error)
                }
            }
        } else {
            let undoName = switch operation {
            case .changeObjects: removals.count == 1 ? "Change Object" : "Change Objects"
            case .cloneHeal: "Clone & Heal"
            default: removals.count == 1 ? "Remove Object" : "Remove Objects"
            }
            applyEdits(result, to: url, undoName: undoName, previous: previous)
        }
    }
}
