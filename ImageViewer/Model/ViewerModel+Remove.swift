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

    /// Done in Remove Objects with `removals` made: saved as "<name> (Retouched)", stacked on the original
    /// (which stays as it was), or, with copies turned off, kept as an edit of the image to save.
    func finishRemovingObjects(_ removals: [Removal], url: URL, decoded d: DecodedImage) {
        guard !removals.isEmpty, d.url == url else { return }
        let previous = edits[url] ?? .identity
        var result = previous
        result.removals = (previous.removals ?? []) + removals
        if Prefs.makesCopy(.removeObjects) {
            let failure = "Couldn't save a retouched copy of “\(url.lastPathComponent)”"
            let save: (EditState) -> Void = { [weak self] e in
                self?.saveCopy(of: url, decoded: d, edits: e, label: "Retouched", defaultFormat: .heic,
                               working: "Saving the retouched copy…", systemImage: "eraser", failure: failure) { $0 }
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
            applyEdits(result, to: url, undoName: removals.count == 1 ? "Remove Object" : "Remove Objects", previous: previous)
        }
    }
}
