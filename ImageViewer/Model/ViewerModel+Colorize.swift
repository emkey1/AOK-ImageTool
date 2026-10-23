import AppKit

extension ViewerModel {
    /// Saves a copy of the image at `url`, with its edits, made by `transform`, as "<name> (<label>)" next to
    /// it. The copy records what it was made from, so it stacks on top of it, and is shown. When `operation` is
    /// set not to make copies (Settings ▸ Editing ▸ Copies), the result takes the image's place instead. `then`
    /// gets the file made (the copy, or the image replaced) once it's saved and listed (not for a photo from
    /// Photos, whose copy goes to the library).
    func saveCopy(of url: URL, decoded d: DecodedImage, edits e: EditState, label: String, defaultFormat: ExportFormat,
                  working: String, systemImage: String, failure: String, operation: CopyOperation? = nil, replaced: String = "",
                  then: ((URL) -> Void)? = nil, transform: @escaping @Sendable (CGImage) async throws -> CGImage) {
        // (A photo from the Photos library always gets a copy, added to Photos.)
        if let operation, !Prefs.makesCopy(operation), PhotosLibrary.shared.photo(for: url) == nil,
           let format = inPlaceFormat(for: d, edits: e) {
            return replace(url, decoded: d, edits: e, format: format, label: label, operation: operation, working: working,
                           systemImage: systemImage, failure: failure, replaced: replaced, then: then, transform: transform)
        }
        var format = SupportedFormats.writableFormat(for: d.contentType).flatMap { [.jpeg, .heic, .avif, .png, .tiff].contains($0) ? $0 : nil }
            ?? defaultFormat
        if e.hasTransparency && !format.supportsAlpha { format = .png }   // a cutout keeps its transparency
        let folder = copyFolder(for: url)
        let name = url.deletingPathExtension().lastPathComponent + " (\(label))"
        showToast(working, systemImage: systemImage)
        Task {
            do {
                let dest = try await Task.detached(priority: .userInitiated) { () async throws -> URL in
                    try await MaskStore.shared.prepare(e, for: d)
                    guard let rendered = EditRenderer.shared.renderSync(d, edits: e, maxDimension: nil) else {
                        throw ImageWriteError.finalizeFailed
                    }
                    let made = try await transform(rendered.image)
                    let dest = ImageWriter.uniqueURL(in: folder, baseName: name, ext: format.fileExtension)
                    try ImageWriter.write(made, to: dest, format: format, quality: 0.92, sourceProperties: d.properties, metadata: .keepAll,
                                          source: url)
                    Self.copyWritten(dest, picture: made, from: url)
                    return dest
                }.value
                try await finishCopy(dest, from: url)
                if !PhotosRoundTrip.isFromPhotos(url) { then?(dest.standardizedFileURL) }
            } catch {
                dismissToast()
                showError(failure, error)
            }
        }
    }

    /// The result of Colorize, Upscale… in place of the image: the file is replaced (the original going to the
    /// Trash as Save would), asking first when Save asks.
    private func replace(_ url: URL, decoded d: DecodedImage, edits e: EditState, format: ExportFormat, label: String,
                         operation: CopyOperation, working: String, systemImage: String, failure: String, replaced: String,
                         then: ((URL) -> Void)?, transform: @escaping @Sendable (CGImage) async throws -> CGImage) {
        let go: () -> Void = { [weak self] in
            guard let self else { return }
            showToast(working, systemImage: systemImage)
            Task {
                do {
                    try await self.writeOver(url: url, decoded: d, edits: e, format: format, transform: transform)
                    self.showToast(replaced.isEmpty ? "Replaced “\(url.lastPathComponent)”" : replaced, systemImage: "checkmark.circle")
                    then?(url.standardizedFileURL)
                } catch {
                    self.dismissToast()
                    self.showError(failure, error)
                }
            }
        }
        guard Prefs.confirmOverwrite else { return go() }
        let alert = NSAlert()
        alert.messageText = "Replace “\(url.lastPathComponent)” with the \(label.lowercased()) version?"
        alert.informativeText = (Prefs.trashOriginalOnSave
            ? "The original is moved to the Trash, so you can still recover it."
            : "The original file is replaced. This can't be undone.")
            + " To keep the original and get a copy instead, turn on “\(operation.title) makes a copy” in Settings ▸ Editing."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if alert.suppressionButton?.state == .on { Prefs.setBool(false, PrefKey.confirmOverwrite) }
            if response == .alertFirstButtonReturn { go() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    /// Where a copy of `original` is written: next to it, or, for a photo from Photos, somewhere to wait until
    /// it's added to the library (see `finishCopy`).
    func copyFolder(for original: URL) -> URL {
        PhotosRoundTrip.isFromPhotos(original) ? PhotosRoundTrip.copiesFolder : original.deletingLastPathComponent()
    }

    /// Right after a copy is written (before the folder's watcher can list it): it records what it was made
    /// from, so it stacks, and its thumbnail is made from `picture`, so the filmstrip doesn't read it back.
    nonisolated static func copyWritten(_ dest: URL, picture: CGImage?, from original: URL) {
        guard !PhotosRoundTrip.isFromPhotos(original) else { return }
        ImageStacks.markDerived(dest, from: original)
        if let picture { ThumbnailCache.shared.seed(picture, for: dest) }
    }

    /// A copy of `original` has been written at `dest`: it's shown (stacked on the original), or, for a photo
    /// from Photos, added to the Photos library as a new photo.
    func finishCopy(_ dest: URL, from original: URL) async throws {
        if PhotosRoundTrip.isFromPhotos(original) {
            do {
                try await PhotosRoundTrip.add(dest)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
            showToast("Added “\(dest.lastPathComponent)” to Photos", systemImage: "photo.on.rectangle")
            return
        }
        copySaved(dest, from: original)
    }

    /// A copy of `original` is saved at `dest`: it's shown straight away if you're still on the original with
    /// no tool open; otherwise the toast offers to show it.
    func copySaved(_ dest: URL, from original: URL) {
        let stillHere = currentURL == original && activeTool == nil
        if let item = FolderScanner.item(for: dest) { insertItem(item, select: stillHere) }
        let copy = dest.standardizedFileURL
        // The newest copy is what its stack shows from now on (unless a picture in it is the one being viewed).
        if !stillHere, let root = stackOf[copy], stackFront[root] != copy {
            stackFront[root] = copy
            applySortAndFilter(selecting: currentURL)
        }
        if stillHere || !items.contains(where: { $0.url == copy }) {
            showToast("Saved \(dest.lastPathComponent)", systemImage: "checkmark.circle")
        } else {
            showToast("Saved \(dest.lastPathComponent)", systemImage: "checkmark.circle", actionTitle: "Show") { [weak self] in
                self?.activeTool = nil
                self?.select(copy)
            }
        }
    }

    /// Saves a colorized copy of the current image, with its edits, next to the original (see `Colorizer`).
    func colorizeCurrent() {
        guard Colorizer.isInstalled else {
            return offerDownload(.colorize) { [weak self] in self?.colorizeCurrent() }
        }
        guard let url = currentURL, let d = decoded, d.url == url else { return }
        saveCopy(of: url, decoded: d, edits: currentEdits, label: "Colorized", defaultFormat: .heic,
                 working: "Colorizing…", systemImage: "paintpalette", failure: "Couldn't colorize “\(url.lastPathComponent)”",
                 operation: .colorize, replaced: "Colorized “\(url.lastPathComponent)”") {
            try await Colorizer.colorize($0)
        }
    }

    /// Done in the Crop tool with the frame extended, when Extend makes copies: the extension is made (sharing
    /// the preview's generation) and saved as "<name> (Extended)", stacked on the original, which stays as it was.
    func saveExtendedCopy(url: URL, decoded d: DecodedImage, edits e: EditState) {
        showToast("Extending…", systemImage: "arrow.up.left.and.arrow.down.right")
        let report: @Sendable (Double) -> Bool = { [weak self] fraction in
            let model = self
            Task { @MainActor in model?.showToast("Extending… \(Int(fraction * 100))%", systemImage: "arrow.up.left.and.arrow.down.right") }
            return false
        }
        Task {
            do {
                let fill = try await ExtendRenderer.makeFill(d, edits: e, progress: report)
                var extended = e
                extended.extendFill = fill.extendFill(try ExtendFillStore.save(fill.fill))
                saveCopy(of: url, decoded: d, edits: extended, label: "Extended", defaultFormat: .heic,
                         working: "Saving the extended copy…", systemImage: "arrow.up.left.and.arrow.down.right",
                         failure: "Couldn't extend “\(url.lastPathComponent)”") { $0 }
            } catch {
                dismissToast()
                showError("Couldn't extend “\(url.lastPathComponent)”", error)
            }
        }
    }

    /// Fix Blur (and restoring faces) can't do an animation's frames.
    var canFixBlur: Bool {
        guard let d = decoded, d.url == currentURL, let url = currentURL, !savingURLs.contains(url) else { return false }
        return !d.isAnimated
    }

    /// Image ▸ Fix Blur…: the sheet, once a model it needs is installed (it offers the downloads itself).
    func beginFixBlur() {
        guard canFixBlur else { return }
        guard GenerativeModel.isSupported else {
            alert = AlertInfo(title: "This needs a Mac with Apple silicon", message: "Fix Blur's models run on Apple silicon only.")
            return
        }
        showFixBlur = true
    }

    /// Saves a sharpened copy of the current image, with its edits, next to the original (see `BlurFixer`).
    func fixBlurCurrent(_ options: BlurFixer.Options) {
        guard let url = currentURL, let d = decoded, d.url == url else { return }
        let relay = ModelRelay(self)
        let working = Prefs.makesCopy(.fixBlur) ? "Fixing the blur…" : "Sharpening…"
        saveCopy(of: url, decoded: d, edits: currentEdits, label: "Sharpened", defaultFormat: .heic,
                 working: working, systemImage: "camera.metering.center.weighted",
                 failure: "Couldn't fix the blur in “\(url.lastPathComponent)”",
                 operation: .fixBlur, replaced: "Sharpened “\(url.lastPathComponent)”") {
            try await BlurFixer.fix($0, options) { fraction in
                Task { @MainActor in
                    // (Only while it's working: a late update mustn't cover "Saved …".)
                    if let model = relay.model, model.toast?.text.hasPrefix(working) == true {
                        model.showToast("\(working) \(Int(fraction * 100))%", systemImage: "camera.metering.center.weighted")
                    }
                }
                return false
            }
        }
    }

    /// Saves a black and white copy of the current image, with its edits, next to the original.
    func saveBlackAndWhite(_ bw: BlackAndWhite) {
        guard let url = currentURL, let d = decoded, d.url == url else { return }
        BlackAndWhite.last = bw
        let copy = Prefs.makesCopy(.blackAndWhite)
        saveCopy(of: url, decoded: d, edits: currentEdits, label: "Black & White", defaultFormat: .heic,
                 working: copy ? "Making a black and white copy…" : "Making it black and white…", systemImage: "circle.lefthalf.filled",
                 failure: "Couldn't make “\(url.lastPathComponent)” black and white",
                 operation: .blackAndWhite, replaced: "Made “\(url.lastPathComponent)” black and white") {
            guard let made = EditRenderer.shared.blackAndWhite($0, bw) else { throw ImageWriteError.finalizeFailed }
            return made
        }
    }
}
