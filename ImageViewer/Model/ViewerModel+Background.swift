import AppKit
import UniformTypeIdentifiers

/// Pictures drawn behind cutouts, copied into Application Support so an edit keeps working when
/// the original picture moves, and across relaunches along with the pending edits.
nonisolated enum BackdropStore {
    static var directory: URL {
        AppStorageLocation.support.appendingPathComponent("Backgrounds")
    }

    /// Copies a picture the user chose (or Image Playground made). Returns the stored path.
    static func importPicture(_ url: URL) throws -> String {
        let dest = try newFile(ext: url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest.path
    }

    /// Stores a picture made in the app (a background generated on this Mac). Returns the stored path.
    static func save(_ image: CGImage) throws -> String {
        let dest = try newFile(ext: "heic")
        try ImageWriter.write(image, to: dest, format: .heic, quality: 0.9, sourceProperties: [:], metadata: .removeAll)
        return dest.path
    }

    /// Deletes pictures nothing refers to any more (at launch, when only pending edits can).
    static func prune(keeping paths: Set<String>) {
        let keep = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func newFile(ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.lowercased())
    }
}

extension ViewerModel {
    /// The current image has see-through areas a background can fill: a cutout edit, or transparency already
    /// in the file (a saved cutout, an upscaled copy of one, a logo…).
    var hasFillableTransparency: Bool {
        guard let d = decoded, d.url == currentURL else { return false }
        return currentEdits.cutout != nil || d.hasTransparentPixels
    }

    var canAddBackground: Bool { canEdit && hasFillableTransparency }

    /// "Blurred original" needs the original pixels behind a cutout; a file whose transparency is baked in
    /// no longer has them.
    var canBlurOriginalBackground: Bool { currentEdits.cutout != nil }

    /// Sets what shows behind the current image's cutout (nil: transparent).
    func setBackground(_ backdrop: Backdrop?, actionName: String = "Background") {
        updateEdits(actionName) { e in
            e.background = backdrop
            // Lighting is only matched to pictures.
            if backdrop?.isPicture != true { e.matchLighting = nil }
        }
    }

    func chooseBackgroundPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to put behind the subject"
        panel.prompt = "Use as Background"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                setBackground(.image(path: try BackdropStore.importPicture(url)), actionName: "Background Picture")
            } catch {
                showError("Couldn't use “\(url.lastPathComponent)” as a background", error)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// The image Image Playground made for "Generate…" (a temporary file, so it's copied first).
    func useGeneratedBackground(from url: URL) {
        guard hasFillableTransparency else { return }
        do {
            setBackground(.image(path: try BackdropStore.importPicture(url)), actionName: "Generated Background")
        } catch {
            showError("Couldn't use the Image Playground image as a background", error)
        }
    }
}
