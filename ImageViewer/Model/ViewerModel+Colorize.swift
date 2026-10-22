import AppKit

extension ViewerModel {
    /// Saves a copy of the image at `url`, with its edits, made by `transform`, as "<name> (<label>)" next to
    /// it. The copy records what it was made from, so it stacks on top of it, and is shown.
    func saveCopy(of url: URL, decoded d: DecodedImage, edits e: EditState, label: String, defaultFormat: ExportFormat,
                  working: String, systemImage: String, failure: String,
                  transform: @escaping @Sendable (CGImage) async throws -> CGImage) {
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
            } catch {
                dismissToast()
                showError(failure, error)
            }
        }
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
                 working: "Colorizing…", systemImage: "paintpalette", failure: "Couldn't colorize “\(url.lastPathComponent)”") {
            try await Colorizer.colorize($0)
        }
    }

    /// Saves a black and white copy of the current image, with its edits, next to the original.
    func saveBlackAndWhite(_ bw: BlackAndWhite) {
        guard let url = currentURL, let d = decoded, d.url == url else { return }
        BlackAndWhite.last = bw
        saveCopy(of: url, decoded: d, edits: currentEdits, label: "Black & White", defaultFormat: .heic,
                 working: "Making a black and white copy…", systemImage: "circle.lefthalf.filled",
                 failure: "Couldn't make a black and white copy of “\(url.lastPathComponent)”") {
            guard let made = EditRenderer.shared.blackAndWhite($0, bw) else { throw ImageWriteError.finalizeFailed }
            return made
        }
    }
}
