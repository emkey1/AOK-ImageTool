import AppKit

/// What Combine Pictures starts with: a background and a foreground (either can still be chosen in it).
struct CombineRequest: Identifiable {
    let id = UUID()
    var background: URL?
    var foreground: URL?
}

extension ViewerModel {
    // MARK: - Combine Pictures

    /// Intelligence ▸ Combine Pictures…: the two pictures selected, or this one with one to choose (it's the
    /// foreground; the sheet makes it the background instead when it has no subject).
    func beginCombine(_ urls: [URL]? = nil) {
        let urls = urls ?? actionTargets
        combineRequest = urls.count >= 2 ? CombineRequest(background: urls[0], foreground: urls[1])
                                         : CombineRequest(background: nil, foreground: urls.first)
    }

    /// A picture as it shows here (its edits, if it has any, applied), full size, for Combine; whether it has
    /// transparency for a subject (a cutout, or see-through areas in the file).
    func combinePicture(_ url: URL) async throws -> (decoded: DecodedImage, picture: CGImage, transparent: Bool) {
        let e = edits[url] ?? .identity
        let hdr = false
        return try await Task.detached(priority: .userInitiated) {
            let d = try ImageDecoder.decode(url: url, page: 0, allowHDR: hdr)
            try await MaskStore.shared.prepare(e, for: d)
            guard let rendered = EditRenderer.shared.renderSync(d, edits: e, maxDimension: nil)?.image else { throw ImageWriteError.finalizeFailed }
            return (d, rendered, e.hasTransparency || (d.hasTransparentPixels && e.background == nil))
        }.value
    }

    /// Saves the combined picture as a copy of the background (“Name (Combined)”, stacked with it).
    func saveCombined(background url: URL, decoded d: DecodedImage, subject: Combine.Subject, layout: Combine.Layout,
                      matchLighting: Double, shadow: Double) {
        saveCopy(of: url, decoded: d, edits: edits[url] ?? .identity, label: "Combined", defaultFormat: .heic,
                 working: "Combining the pictures…", systemImage: "square.2.layers.3d", failure: "Couldn't combine the pictures") { rendered in
            guard let made = Combine.compose(background: rendered, subject: subject, layout: layout, matchLighting: matchLighting, shadow: shadow) else {
                throw ImageWriteError.finalizeFailed
            }
            return made
        }
    }
}
