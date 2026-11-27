import AppKit
import ImageIO
import simd

/// What Stitch Pictures starts with: the pictures selected (more can be added in it).
struct StitchRequest: Identifiable {
    let id = UUID()
    var urls: [URL]
}

extension ViewerModel {
    // MARK: - Stitch Pictures

    /// Intelligence ▸ Stitch Pictures…: the pictures selected, or this one with others to add.
    func beginStitch(_ urls: [URL]? = nil) {
        stitchRequest = StitchRequest(urls: urls ?? actionTargets)
    }

    /// Saves the stitched picture as a copy of the first of `urls` (“Name (Stitched)”, stacked with it). The
    /// pictures are opened again at full size (times `fit`, when that would make the stitched picture too big)
    /// and laid out as the sheet had them (`layout`, which is of these pictures in this order).
    func saveStitched(_ urls: [URL], decoded d: DecodedImage, layout: Stitch.Layout, look: Stitch.Look, edges: StitchEdges,
                      filling: Stitch.Filling?, fit: Double, space: CGColorSpace) {
        guard let first = urls.first else { return }
        let all = urls.map { ($0, edits[$0] ?? .identity) }
        saveCopy(of: first, decoded: d, edits: edits[first] ?? .identity, label: "Stitched", undoName: "Stitch", defaultFormat: .heic,
                 working: "Stitching the pictures…", systemImage: "rectangle.split.3x1", failure: "Couldn't stitch the pictures") { rendered in
            var pictures: [Stitch.Picture] = []
            for (i, (url, e)) in all.enumerated() {
                if i == 0 {
                    // (Already made, by `saveCopy`.)
                    let side = fit < 1 ? Int((Double(max(rendered.width, rendered.height)) * fit).rounded(.up)) : nil
                    guard let p = Stitch.Picture(rendered, focal: Stitch.focal(from: d.properties, pixels: d.pixelSize),
                                                 down: Stitch.down(from: d.properties, edits: e), space: space, maxSide: side) else {
                        throw ImageWriteError.finalizeFailed
                    }
                    pictures.append(p)
                } else {
                    pictures.append(try await Stitch.open(url, edits: e, fit: fit, space: space).picture)
                }
            }
            let stitched = try Stitch.render(pictures, layout: layout, look: look, sharp: true)
            guard let made = Stitch.finished(stitched, edges: edges, filling: filling) else { throw ImageWriteError.finalizeFailed }
            return made
        }
    }
}

nonisolated extension Stitch {
    /// A picture as it shows (its edits applied), for stitching: no bigger than `maxSide`, or `fit` times its
    /// size. In `space`, or its own color space (what the first picture has, the rest are given).
    static func open(_ url: URL, edits: EditState, maxSide: Int? = nil, fit: Double = 1, space: CGColorSpace? = nil) async throws
        -> (decoded: DecodedImage, picture: Picture) {
        let d = try ImageDecoder.decode(url: url, page: 0, allowHDR: false)
        try await MaskStore.shared.prepare(edits, for: d)
        let full = EditRenderer.shared.outputSize(d, edits: edits)
        let longest = max(full.width, full.height, 1)
        var scale = min(1, fit)
        if let maxSide { scale = min(scale, Double(maxSide) / longest) }
        let source = max(d.pixelSize.width, d.pixelSize.height)
        guard let rendered = EditRenderer.shared.renderSync(d, edits: edits, maxDimension: scale < 1 ? (source * scale).rounded(.up) : nil)?.image else {
            throw ImageWriteError.finalizeFailed
        }
        let own = rendered.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let picture = Picture(rendered, fullSize: full, focal: focal(from: d.properties, pixels: d.pixelSize), down: down(from: d.properties, edits: edits),
                                    space: space ?? CGColorSpaceCreateCopyWithStandardRange(own),
                                    maxSide: scale < 1 ? Int((longest * scale).rounded(.up)) : nil) else { throw ImageWriteError.finalizeFailed }
        return (d, picture)
    }

    /// Which way was down when the picture was taken, in its own directions as it shows (x to its right, y down
    /// it, z into it), when the file says: an iPhone writes what its motion sensor read. Only for a picture
    /// that hasn't been turned, flipped, straightened or tilted here (cropping doesn't change its directions).
    static func down(from properties: [String: Any], edits: EditState) -> SIMD3<Double>? {
        guard edits.quarterTurns == 0, !edits.flipHorizontal, !edits.flipVertical, edits.straighten == 0, !edits.isTilted, edits.perspective == nil,
              let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              let reading = maker["8"] as? [Any], reading.count == 3 else { return nil }
        let a = reading.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? String).flatMap(Double.init) }
        guard a.count == 3 else { return nil }
        // (The front camera looks the other way, and its pictures are mirrored: not worked out here.)
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        guard (exif?[kCGImagePropertyExifLensModel as String] as? String)?.localizedCaseInsensitiveContains("back") == true else { return nil }
        // The reading is the pull of gravity along the phone's own axes (to its right, to its top, out of its
        // screen); the back camera's sensor has its right toward the phone's bottom and its top toward the
        // phone's left, and looks out of the back.
        let sensor = SIMD3(-a[1], -a[0], -a[2])
        let pull = simd_length(sensor)
        // (About one g: a phone being swung about reads something else.)
        guard pull > 0.85, pull < 1.15 else { return nil }
        let s = sensor / pull
        // The picture shows the sensor's turned by some number of quarter turns: the one that puts down nearest
        // its bottom, which is how the camera chose to turn it. (Not read from the file's orientation: a
        // picture saved again with its turn applied says "not turned", and still carries the reading.)
        if abs(s.y) >= abs(s.x) { return s.y >= 0 ? s : SIMD3(-s.x, -s.y, s.z) }
        return s.x >= 0 ? SIMD3(-s.y, s.x, s.z) : SIMD3(s.y, -s.x, s.z)
    }
}
