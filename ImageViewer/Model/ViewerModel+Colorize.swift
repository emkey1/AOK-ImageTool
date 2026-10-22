import AppKit

extension ViewerModel {
    /// Saves a colorized copy of the current image, with its edits, next to the original (see `Colorizer`).
    func colorizeCurrent() {
        guard Colorizer.isInstalled, let url = currentURL, let d = decoded, d.url == url else { return }
        let e = currentEdits
        let format = SupportedFormats.writableFormat(for: d.contentType).flatMap { [.jpeg, .heic, .avif, .png, .tiff].contains($0) ? $0 : nil }
            ?? .heic
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent + " (Colorized)"
        showToast("Colorizing…", systemImage: "paintpalette")
        Task {
            do {
                let dest = try await Task.detached(priority: .userInitiated) { () async throws -> URL in
                    try await MaskStore.shared.prepare(e, for: d)
                    guard let rendered = EditRenderer.shared.renderSync(d, edits: e, maxDimension: nil) else {
                        throw ImageWriteError.finalizeFailed
                    }
                    let colored = try await Colorizer.colorize(rendered.image)
                    let dest = ImageWriter.uniqueURL(in: folder, baseName: name, ext: format.fileExtension)
                    try ImageWriter.write(colored, to: dest, format: format, quality: 0.92, sourceProperties: d.properties, metadata: .keepAll)
                    return dest
                }.value
                if let item = FolderScanner.item(for: dest) { insertItem(item, select: true) }
                showToast("Saved \(dest.lastPathComponent)", systemImage: "checkmark.circle")
            } catch {
                dismissToast()
                showError("Couldn't colorize “\(url.lastPathComponent)”", error)
            }
        }
    }
}
