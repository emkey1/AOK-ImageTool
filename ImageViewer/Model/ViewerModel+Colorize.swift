import AppKit

extension ViewerModel {
    /// Saves a copy of the image at `url`, with its edits, made by `transform`, as "<name> (<label>)" next to
    /// it. The copy records what it was made from, so it stacks on top of it, and is shown.
    func saveCopy(of url: URL, decoded d: DecodedImage, edits e: EditState, label: String, defaultFormat: ExportFormat,
                  working: String, systemImage: String, failure: String,
                  transform: @escaping @Sendable (CGImage) async throws -> CGImage) {
        let format = SupportedFormats.writableFormat(for: d.contentType).flatMap { [.jpeg, .heic, .avif, .png, .tiff].contains($0) ? $0 : nil }
            ?? defaultFormat
        let folder = url.deletingLastPathComponent()
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
                    try ImageWriter.write(made, to: dest, format: format, quality: 0.92, sourceProperties: d.properties, metadata: .keepAll)
                    ImageStacks.markDerived(dest, from: url)
                    return dest
                }.value
                if let item = FolderScanner.item(for: dest) { insertItem(item, select: true) }
                showToast("Saved \(dest.lastPathComponent)", systemImage: "checkmark.circle")
            } catch {
                dismissToast()
                showError(failure, error)
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
