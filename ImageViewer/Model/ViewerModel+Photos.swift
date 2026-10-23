import AppKit
import PhotosUI

extension ViewerModel {
    // MARK: - Photos library (File ▸ Open from Photos…)

    /// File ▸ Open from Photos…: picks photos in the library to browse and edit here (see `PhotosLibrary`).
    func openFromPhotos() {
        presentPhotosPicker { [weak self] ids in self?.openLibraryPhotos(ids) }
    }

    /// File ▸ Import from Photos…: photos picked in the library are copied into a folder as ordinary files (the
    /// one imported into last, or another), which then opens. Edits then belong to the files, not to Photos.
    func importFromPhotos() {
        presentPhotosPicker { [weak self] ids in self?.chooseImportFolder(for: ids) }
    }

    private func chooseImportFolder(for ids: [String]) {
        guard !ids.isEmpty else { return }
        let photos = ids.count == 1 ? "the photo" : "\(ids.count) photos"
        guard let last = Prefs.lastImportFolder else { return chooseOtherImportFolder(for: ids) }
        let alert = NSAlert()
        alert.messageText = "Import \(photos) into “\(last.lastPathComponent)”?"
        alert.informativeText = "They're copied there as ordinary files: \((last.path as NSString).abbreviatingWithTildeInPath). This is the folder you imported into last."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.importLibraryPhotos(ids, into: last)
            case .alertSecondButtonReturn: self?.chooseOtherImportFolder(for: ids)
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    private func chooseOtherImportFolder(for ids: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Import Here"
        panel.message = ids.count == 1 ? "Choose the folder to import the photo into." : "Choose the folder to import \(ids.count) photos into."
        panel.directoryURL = Prefs.lastImportFolder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.importLibraryPhotos(ids, into: folder)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    private func importLibraryPhotos(_ ids: [String], into folder: URL) {
        Prefs.set(folder.standardizedFileURL.path, PrefKey.lastImportFolder)
        showToast(ids.count == 1 ? "Importing the photo from Photos…" : "Importing \(ids.count) photos from Photos…", systemImage: "square.and.arrow.down")
        let report: @Sendable (Int, Int) -> Void = { [weak self] i, n in
            let model = self
            guard n > 1 else { return }
            Task { @MainActor in model?.showToast("Importing photo \(i + 1) of \(n) from Photos…", systemImage: "square.and.arrow.down") }
        }
        Task {
            do {
                let made = try await PhotosLibrary.shared.importPhotos(ids, into: folder, progress: report)
                guard let first = made.first else { return dismissToast() }
                openFolder(folder.standardizedFileURL, selecting: first.standardizedFileURL)
                showToast(made.count == 1 ? "Imported “\(first.lastPathComponent)” into “\(folder.lastPathComponent)”"
                          : "Imported \(made.count) photos into “\(folder.lastPathComponent)”", systemImage: "square.and.arrow.down")
            } catch {
                dismissToast()
                showError("Couldn't import from Photos", error)
            }
        }
    }

    /// Photos' picker in a sheet, after asking for access to the library; `done` gets the photos picked.
    private func presentPhotosPicker(_ done: @escaping ([String]) -> Void) {
        Task {
            do {
                try await PhotosLibrary.requestAccess()
            } catch {
                return showError("Couldn't open Photos", error)
            }
            guard let host = window?.contentViewController else { return }
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.selectionLimit = 0
            config.filter = .any(of: [.images, .livePhotos])
            let picker = PHPickerViewController(configuration: config)
            let delegate = PhotosPickerDelegate(done: done)
            picker.delegate = delegate
            PhotosPickerDelegate.current = delegate
            // The picker doesn't size itself in a sheet (it shrinks to its toolbar): most of the window.
            let bounds = host.view.bounds.size
            let size = NSSize(width: max(760, bounds.width * 0.85), height: max(560, bounds.height * 0.85))
            picker.preferredContentSize = size
            picker.view.setFrameSize(size)
            host.presentAsSheet(picker)
        }
    }

    private func openLibraryPhotos(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        showToast(ids.count == 1 ? "Getting the photo from Photos…" : "Getting \(ids.count) photos from Photos…", systemImage: "photo.on.rectangle")
        let report: @Sendable (Int, Int) -> Void = { [weak self] i, n in
            let model = self
            guard n > 1 else { return }
            Task { @MainActor in model?.showToast("Getting photo \(i + 1) of \(n) from Photos…", systemImage: "photo.on.rectangle") }
        }
        Task {
            do {
                let opened = try await PhotosLibrary.shared.open(assetIDs: ids, progress: report)
                guard let first = opened.files.first else { return dismissToast() }
                for (url, e) in opened.edits { setEditsDictionary(url, e) }
                openFolder(opened.folder, selecting: first, restrictedTo: Set(opened.files))
                dismissToast()
            } catch {
                dismissToast()
                showError("Couldn't open the photos from Photos", error)
            }
        }
    }

    // MARK: Saved or not

    /// Whether `url` has changes that aren't saved: any edits to a file; for a photo from the library, edits
    /// that differ from the ones in Photos.
    func isUnsaved(_ url: URL) -> Bool {
        if let photo = PhotosLibrary.shared.photo(for: url) {
            return (edits[url] ?? .identity) != (photo.savedEdits ?? .identity)
        }
        return edits[url] != nil
    }

    var unsavedURLs: [URL] {
        var urls = Set(edits.keys)
        for item in allItems where PhotosLibrary.shared.photo(for: item.url)?.savedEdits != nil { urls.insert(item.url) }
        return urls.filter(isUnsaved).sorted { $0.path < $1.path }
    }

    // MARK: Saving to Photos

    /// Save for a photo from the library: the edit goes to Photos. Taking every edit away reverts the photo
    /// to its original there.
    func saveToPhotos(url: URL, decoded d: DecodedImage, edits e: EditState) {
        guard let photo = PhotosLibrary.shared.photo(for: url) else { return }
        guard isUnsaved(url) else { return showToast("No changes to save", systemImage: "checkmark.circle") }
        if photo.isLive && PhotosLibrary.stillOnly(e) {
            let alert = NSAlert()
            alert.messageText = "Save the Live Photo as a still photo?"
            alert.informativeText = "A removed background and Extend are for a single picture, so the photo would be saved without its motion."
            alert.addButton(withTitle: "Save as Still")
            alert.addButton(withTitle: "Cancel")
            let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                if response == .alertFirstButtonReturn { self?.performPhotosSave(url: url, decoded: d, edits: e, keepLive: false) }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
            return
        }
        performPhotosSave(url: url, decoded: d, edits: e, keepLive: true)
    }

    private func performPhotosSave(url: URL, decoded d: DecodedImage, edits e: EditState, keepLive: Bool) {
        let live = PhotosLibrary.shared.photo(for: url)?.isLive == true && keepLive
        showToast(live ? "Saving to Photos, every frame of the Live Photo…" : "Saving to Photos…", systemImage: "photo.on.rectangle")
        Task {
            do {
                try await savePhoto(url, decoded: d, edits: e, keepLive: keepLive)
                showToast(e.isIdentity ? "Back to the original in Photos" : "Saved to Photos (Revert to Original there undoes it)",
                          systemImage: "photo.on.rectangle")
            } catch {
                dismissToast()
                showError("Couldn't save “\(url.lastPathComponent)” to Photos", error)
            }
        }
    }

    /// Saves to Photos, the image blocked from editing meanwhile.
    func savePhoto(_ url: URL, decoded d: DecodedImage, edits e: EditState, keepLive: Bool) async throws {
        savingURLs.insert(url)
        defer {
            savingURLs.remove(url)
            window?.isDocumentEdited = hasUnsavedEdits
        }
        if e.isIdentity {
            try await PhotosLibrary.shared.revertToOriginal(url)
        } else {
            try await PhotosLibrary.shared.save(url, decoded: d, edits: e, keepLive: keepLive)
        }
    }
}

/// Hands the photos chosen in Photos' picker on, and closes it.
final class PhotosPickerDelegate: NSObject, PHPickerViewControllerDelegate {
    /// The one in use (the picker doesn't keep its delegate).
    static var current: PhotosPickerDelegate?
    private let done: ([String]) -> Void

    init(done: @escaping ([String]) -> Void) {
        self.done = done
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.presentingViewController?.dismiss(picker)
        Self.current = nil
        done(results.compactMap(\.assetIdentifier))
    }
}
