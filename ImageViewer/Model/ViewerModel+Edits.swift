import AppKit
import SwiftUI

nonisolated struct ExportOptions: Sendable {
    var format: ExportFormat = .jpeg
    var quality: Double = 0.88
    var maxDimension: Int?
    var metadata: MetadataPolicy = .keepAll
    var applyEdits = true
}

extension ViewerModel {
    // MARK: - Editing

    /// Applies a discrete edit (button press) with undo support.
    /// Changes the edits of `image` (the current image when nil: pass the image a slow operation started
    /// on, so its result doesn't land on whatever is showing when it finishes).
    func updateEdits(_ actionName: String, of image: URL? = nil, _ change: (inout EditState) -> Void) {
        guard let url = image ?? currentURL else { return }
        let old = edits[url] ?? .identity
        var new = old
        change(&new)
        guard new != old else { return }
        applyEdits(new, to: url, undoName: actionName, previous: old)
    }

    /// Live update for continuous controls (sliders). Pair with `commitEdits(from:actionName:)`.
    func previewEdits(_ change: (inout EditState) -> Void) {
        guard let url = currentURL else { return }
        var state = edits[url] ?? .identity
        change(&state)
        setEditsDictionary(url, state.isIdentity ? nil : state)
        refreshDisplay()
        window?.isDocumentEdited = hasUnsavedEdits
    }

    /// Registers a single undo step for a completed slider drag.
    func commitEdits(from start: EditState, actionName: String) {
        guard let url = currentURL else { return }
        let current = edits[url] ?? .identity
        guard current != start else { return }
        registerEditUndo(url: url, restoring: start, redoState: current, name: actionName)
    }

    func applyEdits(_ new: EditState, to url: URL, undoName: String?, previous: EditState) {
        guard !savingURLs.contains(url) else {
            NSSound.beep()
            return
        }
        setEditsDictionary(url, new.isIdentity ? nil : new)
        if let undoName { registerEditUndo(url: url, restoring: previous, redoState: new, name: undoName) }
        if url == currentURL {
            refreshDisplay()
            refillExtensionIfNeeded()
        }
        window?.isDocumentEdited = hasUnsavedEdits
    }

    private func registerEditUndo(url: URL, restoring previous: EditState, redoState: EditState, name: String) {
        guard let undoManager else { return }
        let target = editUndoTargets[url] ?? EditUndoTarget()
        editUndoTargets[url] = target
        undoManager.registerUndo(withTarget: target) { [weak self] _ in
            guard let model = self else { return }
            if model.currentURL != url { model.select(url) }
            model.applyEdits(previous, to: url, undoName: name, previous: redoState)
        }
        undoManager.setActionName(name)
    }

    /// Once edits are in the file, undoing them would apply them again: forget that image's edit undos.
    private func dropEditUndos(for url: URL) {
        if let target = editUndoTargets.removeValue(forKey: url) { undoManager?.removeAllActions(withTarget: target) }
    }

    func rotate(clockwise: Bool) {
        updateEdits(clockwise ? "Rotate Right" : "Rotate Left") { $0.rotate(clockwise: clockwise) }
    }

    func flip(horizontal: Bool) {
        updateEdits(horizontal ? "Flip Horizontal" : "Flip Vertical") { $0.flip(horizontal: horizontal) }
    }

    func toggleAutoEnhance() {
        updateEdits("Auto Enhance") { $0.autoEnhance.toggle() }
    }

    func revertEdits() {
        updateEdits("Revert to Original") { $0 = .identity }
    }

    func resetAdjustments() {
        updateEdits("Reset Adjustments") { $0.resetAdjustments() }
    }

    var canEdit: Bool {
        guard let url = currentURL else { return false }
        return decoded != nil && activeTool == nil && !savingURLs.contains(url)
    }

    // MARK: - Saving

    /// Writes the edits back into the original file (same format), keeping metadata.
    func save() {
        guard let url = currentURL, let d = decoded, d.url == url else { return }
        guard !extendIsPending(for: url) else {
            showToast("Extend is still filling in the new area — try again in a moment", systemImage: "hourglass")
            return
        }
        let e = currentEdits
        guard !e.isIdentity else {
            showToast("No changes to save", systemImage: "checkmark.circle")
            return
        }
        guard let format = inPlaceFormat(for: d, edits: e) else {
            showToast("This file can't be saved in place — choose an export format", systemImage: "square.and.arrow.up")
            exportRequest = ExportRequest(urls: [url])
            return
        }

        if Prefs.confirmOverwrite {
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(url.lastPathComponent)”?"
            alert.informativeText = Prefs.trashOriginalOnSave
                ? "The edited image replaces the file. The original is moved to the Trash, so you can still recover it."
                : "The edited image replaces the original file. This can't be undone."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Export a Copy…")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                if alert.suppressionButton?.state == .on { Prefs.setBool(false, PrefKey.confirmOverwrite) }
                switch response {
                case .alertFirstButtonReturn: self.performSave(url: url, decoded: d, edits: e, format: format)
                case .alertThirdButtonReturn: self.exportRequest = ExportRequest(urls: [url])
                default: break
                }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
        } else {
            performSave(url: url, decoded: d, edits: e, format: format)
        }
    }

    /// The format to write `d` back in, or nil when it can't be saved in place.
    private func inPlaceFormat(for d: DecodedImage, edits e: EditState) -> ExportFormat? {
        // Not animations (one frame would replace them all) or images reduced to fit the display.
        guard let format = SupportedFormats.writableFormat(for: d.contentType),
              !d.isVector, d.pageCount == 1, !d.isAnimated, !d.isReduced,
              !(e.hasTransparency && !format.supportsAlpha)
        else { return nil }
        return format
    }

    private func performSave(url: URL, decoded d: DecodedImage, edits e: EditState, format: ExportFormat) {
        showToast("Saving…", systemImage: "arrow.down.doc")
        Task {
            do {
                try await writeEdits(url: url, decoded: d, edits: e, format: format)
                showToast("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle")
            } catch {
                showError("Couldn't save “\(url.lastPathComponent)”", error)
            }
        }
    }

    /// Renders `e` at full resolution, replaces the file with it, then drops the saved edits.
    private func writeEdits(url: URL, decoded d: DecodedImage, edits e: EditState, format: ExportFormat) async throws {
        let trash = Prefs.trashOriginalOnSave
        savingURLs.insert(url)
        defer { savingURLs.remove(url) }
        try await Task.detached(priority: .userInitiated) {
            try await MaskStore.shared.prepare(e, for: d)
            guard let output = EditRenderer.shared.renderSync(d, edits: e, maxDimension: nil) else {
                throw ImageWriteError.finalizeFailed
            }
            // The new file is a new file: keep its record of what it was made from (it may be a stacked copy).
            let source = ImageStacks.source(of: url)
            try ImageWriter.replace(original: url, with: output.image, format: format, quality: 0.93,
                                    sourceProperties: d.properties, trashOriginal: trash)
            if let source { ImageStacks.setSource(source, of: url) }
        }.value
        setEditsDictionary(url, nil)
        dropEditUndos(for: url)
        window?.isDocumentEdited = hasUnsavedEdits
        fileDidChange(url)
    }

    /// Saves every edited image in place, one at a time, without asking (closing the window already
    /// asked). Returns a line for each image that couldn't be saved.
    func saveAllEdits() async -> [String] {
        var failures: [String] = []
        let hdr = Prefs.hdrEnabled
        for (url, e) in edits.sorted(by: { $0.key.path < $1.key.path }) {
            do {
                let d: DecodedImage
                if let current = decoded, current.url == url {
                    d = current
                } else if let cached = ImagePipeline.shared.cached(url, page: 0, hdr: hdr) {
                    d = cached
                } else {
                    d = try await Task.detached(priority: .userInitiated) {
                        try ImageDecoder.decode(url: url, page: 0, allowHDR: hdr)
                    }.value
                }
                guard let format = inPlaceFormat(for: d, edits: e) else {
                    failures.append("\(url.lastPathComponent): can't be saved in its own format")
                    continue
                }
                try await writeEdits(url: url, decoded: d, edits: e, format: format)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }

    /// Refreshes caches and item metadata after a file is rewritten.
    func fileDidChange(_ url: URL) {
        ImagePipeline.shared.invalidate(url)
        ThumbnailCache.shared.invalidate(url)
        EditRenderer.shared.forget(url)
        MaskStore.shared.forget(url)
        intelligence.forget(url)
        if let fresh = FolderScanner.item(for: url) {
            updateItem(url) { $0 = fresh }
        }
        if currentURL == url { reloadCurrent() }
    }

    // MARK: - Export

    func requestExport() {
        let urls = actionTargets
        guard !urls.isEmpty else { return }
        guard !urls.contains(where: extendIsPending) else {
            showToast("Extend is still filling in the new area — try again in a moment", systemImage: "hourglass")
            return
        }
        exportRequest = ExportRequest(urls: urls)
    }

    /// Exports `urls` into `folder`. Returns the written files.
    func export(_ urls: [URL], options: ExportOptions, to folder: URL, singleName: String?,
                progress: @escaping (Double) -> Void) async -> (written: [URL], errors: [String]) {
        var written: [URL] = []
        var errors: [String] = []
        let hdr = Prefs.hdrEnabled
        for (i, url) in urls.enumerated() {
            let e = options.applyEdits ? (edits[url] ?? .identity) : .identity
            let cached = ImagePipeline.shared.cached(url, page: 0, hdr: hdr)
            let name = (urls.count == 1 ? singleName : nil) ?? url.deletingPathExtension().lastPathComponent
            do {
                let out = try await Task.detached(priority: .userInitiated) { () async throws -> URL in
                    let d = try cached ?? ImageDecoder.decode(url: url, page: 0, allowHDR: hdr)
                    try await MaskStore.shared.prepare(e, for: d)
                    let maxDim = options.maxDimension.map { CGFloat($0) }
                    guard let rendered = EditRenderer.shared.renderSync(d, edits: e, maxDimension: maxDim) else {
                        throw ImageWriteError.finalizeFailed
                    }
                    let dest = ImageWriter.uniqueURL(in: folder, baseName: name, ext: options.format.fileExtension)
                    try ImageWriter.write(rendered.image, to: dest, format: options.format, quality: options.quality,
                                          sourceProperties: d.properties, metadata: options.metadata, source: url)
                    ImageStacks.markDerived(dest, from: url)    // (when it's beside the original)
                    return dest
                }.value
                written.append(out)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            progress(Double(i + 1) / Double(urls.count))
        }
        if let folderURL, written.contains(where: { $0.deletingLastPathComponent().standardizedFileURL == folderURL }) {
            rescan()
        }
        return (written, errors)
    }
}
