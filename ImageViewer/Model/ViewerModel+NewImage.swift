import AppKit

extension ViewerModel {
    // MARK: - New Image from Description

    /// File ▸ New Image from Description…: a picture painted from a description, on this Mac.
    func beginNewImage() {
        showNewImage = true
    }

    /// Where a new picture goes: this folder, or Pictures (no folder open, a photo from Photos showing, or a
    /// folder that can't be written to).
    var newImageFolder: (url: URL, isHere: Bool) {
        let fm = FileManager.default
        if let folder = folderURL, !PhotosRoundTrip.isFromPhotos(folder.appendingPathComponent("x")), fm.isWritableFile(atPath: folder.path) {
            return (folder, true)
        }
        return (fm.urls(for: .picturesDirectory, in: .userDomainMask)[0], false)
    }

    /// The picture made from `description`, saved as a new image named after it, and shown.
    func saveNewImage(_ image: CGImage, description: String) {
        let (folder, isHere) = newImageFolder
        let dest = ImageWriter.uniqueURL(in: folder, baseName: GenerativeImage.title(for: description), ext: "heic")
        do {
            try ImageWriter.write(image, to: dest, format: .heic, quality: 0.9, sourceProperties: [:], metadata: .removeAll)
        } catch {
            return showError("Couldn't save the new image", error)
        }
        show(newImage: dest, isHere: isHere)
    }

    /// The picture Image Playground made from `description` (a file it hands over), saved the same way.
    func saveNewImage(from made: URL, description: String) {
        let (folder, isHere) = newImageFolder
        let ext = made.pathExtension.isEmpty ? "heic" : made.pathExtension
        let dest = ImageWriter.uniqueURL(in: folder, baseName: GenerativeImage.title(for: description), ext: ext)
        do {
            try FileManager.default.copyItem(at: made, to: dest)
        } catch {
            return showError("Couldn't save the Image Playground image", error)
        }
        show(newImage: dest, isHere: isHere)
    }

    private func show(newImage url: URL, isHere: Bool) {
        if isHere, let item = FolderScanner.item(for: url) {
            insertItem(item, select: true)
            viewMode = .viewer
        } else {
            open([url])
        }
        showToast("Saved “\(url.lastPathComponent)”", systemImage: "wand.and.stars")
    }
}
