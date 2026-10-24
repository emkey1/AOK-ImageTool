import CoreGraphics
import CoreImage
import Foundation

/// The on-device model's uses besides Extend: a background painted around a cut-out subject, offered next to
/// Image Playground (or instead of it, where a Mac has none), and a new picture from a description. (Not
/// Reimagine: this model restyles photos weakly and doesn't keep a person's likeness, which Image Playground
/// does.)
nonisolated enum GenerativeImage {
    // MARK: New Image from Description

    /// A new picture's shape.
    enum Shape: String, CaseIterable, Identifiable, Sendable {
        case square, landscape, portrait, wide

        var id: String { rawValue }

        var title: String {
            switch self {
            case .square: "Square"
            case .landscape: "3:2"
            case .portrait: "2:3"
            case .wide: "16:9"
            }
        }

        /// The size it's painted at: the model's 512 on the short side (in overlapping windows past that).
        var workingSize: (width: Int, height: Int) {
            let n = GenerativeExtend.window
            switch self {
            case .square: return (n, n)
            case .landscape: return (n * 3 / 2, n)
            case .portrait: return (n, n * 3 / 2)
            case .wide: return (n * 16 / 9 / 8 * 8, n)
            }
        }
    }

    /// Words that say a description is already a kind of picture ("a watercolor of a fox"), not a scene to photograph.
    private static let pictureKinds = ["painting", "watercolor", "water color", "drawing", "illustration", "sketch", "cartoon", "render",
                                       "photo", "photograph", "poster", "pixel art", "anime", "comic", "engraving", "pastel", "charcoal"]

    /// What a new picture shouldn't have: the usual, and the stock-photo watermarks the model learned from.
    private static let negativePrompt = GenerativeExtend.negativePrompt + ", stock photo watermark, copyright notice, website address"

    /// The prompt for a new picture: the description as a photo, unless it says it's another kind of picture.
    static func picturePrompt(_ description: String) -> String {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let lower = text.lowercased()
        if pictureKinds.contains(where: lower.contains) { return "\(text), high quality, detailed" }
        return "a high quality photo of \(text), detailed, sharp focus"
    }

    /// A file name for a picture made from `description`: its first words, without a leading article.
    static func title(for description: String) -> String {
        var words = description.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/:\\\"")))
            .filter { !$0.isEmpty }
        if let first = words.first?.lowercased(), ["a", "an", "the"].contains(first), words.count > 1 { words.removeFirst() }
        var title = ""
        for word in words where title.count + word.count < 60 { title += (title.isEmpty ? "" : " ") + word }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
        guard let first = title.first else { return "New Image" }
        return first.uppercased() + title.dropFirst()
    }

    /// New Image from Description's preview: `description` painted from nothing in `shape`, at the model's
    /// working size.
    @concurrent static func picture(_ description: String, shape: Shape, seed: UInt64,
                                    progress: (@Sendable (Double) -> Bool)? = nil) async throws -> CGImage {
        let (w, h) = shape.workingSize
        var canvas = RGBABitmap(width: w, height: h)
        var known = [UInt8](repeating: 0, count: w * h)
        try await GenerativeExtend.paint(&canvas, known: &known, start: nil, prompt: picturePrompt(description),
                                         negative: negativePrompt, seed: seed, strength: 1, steps: 20,
                                         overlap: GenerativeExtend.overlap, progress: progress)
        guard let image = canvas.makeImage(space: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw ExtendError.failed }
        return image
    }

    /// The preview kept, finished: redrawn at twice its size with a light touch, for detail at that scale (as
    /// Extend's second pass does), then enlarged to `longSide`. Only the redraw's fine detail is kept, over the
    /// preview's own color and light: each window of a light redraw drifts a little, which would show as seams.
    @concurrent static func finished(_ preview: CGImage, description: String, seed: UInt64, longSide: Int = 2048,
                                     progress: (@Sendable (Double) -> Bool)? = nil) async throws -> CGImage {
        let w = preview.width * 2, h = preview.height * 2
        var base = RGBABitmap(width: w, height: h)
        base.draw(preview, topLeftRect: CGRect(x: 0, y: 0, width: w, height: h), space: CGColorSpace(name: CGColorSpace.sRGB)!, quality: .high)
        var canvas = base
        var known = [UInt8](repeating: 0, count: w * h)
        try await GenerativeExtend.paint(&canvas, known: &known, start: nil, prompt: picturePrompt(description),
                                         negative: negativePrompt, seed: seed &+ 1, strength: GenerativeExtend.refineStrength,
                                         steps: GenerativeExtend.refineSteps, overlap: GenerativeExtend.refineOverlap, progress: progress)
        var broad = base, redrawnBroad = canvas
        broad.blur(radius: 6)
        redrawnBroad.blur(radius: 6)
        for i in stride(from: 0, to: canvas.pixels.count, by: 4) {
            for c in 0..<3 {
                let v = Int(canvas.pixels[i + c]) - Int(redrawnBroad.pixels[i + c]) + Int(broad.pixels[i + c])
                canvas.pixels[i + c] = UInt8(clamping: v)
            }
        }
        return try await enlarged(canvas, longSide: longSide)
    }

    // MARK: Generate a Background

    /// The prompt for a background: the scene, and (when known) what's in front of it, so the model frames
    /// and lights the scene for it ("a smiling woman in a turquoise shirt, a sunny beach in the background").
    static func backgroundPrompt(scene: String, subject: String?) -> String {
        let scene = scene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty else {
            return GenerativeExtend.prompt(scene)
        }
        return scene.isEmpty ? "a high quality photo of \(subject)" : "a high quality photo of \(subject), \(scene) in the background"
    }

    /// A scene behind a cut-out subject, painted around it so its scale, perspective and light suit the
    /// subject: everything outside `subject` (a mask over `photo`, white = the subject) is made from the
    /// scene and the subject's description. Returns the whole picture at `photo`'s proportions; the subject
    /// is in it too, but the cutout stays in front.
    @concurrent static func background(_ photo: CGImage, subject: CIImage, scene: String, subjectDescription: String?, seed: UInt64,
                           progress: (@Sendable (Double) -> Bool)? = nil) async throws -> CGImage {
        let prompt = backgroundPrompt(scene: scene, subject: subjectDescription)
        // Naming the subject would fight "no people"; instead, no second one of it.
        let avoid = subjectDescription == nil ? ", people, person, crowd" : ", crowd, extra people, second person, duplicate subject"
        var canvas = working(photo)
        let w = canvas.width, h = canvas.height
        // The subject, pulled in a little, is kept; its edge is redrawn so the new scene meets it cleanly.
        var known = eroded(mask(subject, width: w, height: h), width: w, height: h, radius: 2)
        guard known.contains(1) else { throw ExtendError.failed }
        try await GenerativeExtend.paint(&canvas, known: &known, start: nil, prompt: prompt,
                                         negative: GenerativeExtend.negativePrompt + avoid,
                                         seed: seed, strength: 1, steps: 25, overlap: GenerativeExtend.overlap, progress: progress)
        return try await enlarged(canvas, longSide: min(2048, max(photo.width, photo.height)))
    }

    /// `photo` at the model's working size (short side 512).
    private static func working(_ photo: CGImage) -> RGBABitmap {
        let n = CGFloat(GenerativeExtend.window)
        let scale = n / CGFloat(min(photo.width, photo.height))
        let w = max(Int(n), Int((CGFloat(photo.width) * scale).rounded())), h = max(Int(n), Int((CGFloat(photo.height) * scale).rounded()))
        var canvas = RGBABitmap(width: w, height: h)
        canvas.draw(photo, topLeftRect: CGRect(x: 0, y: 0, width: w, height: h), space: CGColorSpace(name: CGColorSpace.sRGB)!, quality: .high)
        return canvas
    }

    /// A mask at `width` × `height`: 1 where it's mostly white.
    private static func mask(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return [] }
        let fitted = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height))
        return ImageDecoder.ciContext.renderGray(fitted, bounds: CGRect(x: 0, y: 0, width: width, height: height)).map { $0 > 127 ? 1 : 0 }
    }

    private static func eroded(_ mask: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        guard mask.count == w * h else { return mask }
        var out = mask
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] == 1 {
                outer: for yy in max(0, y - r)...min(h - 1, y + r) {
                    for xx in max(0, x - r)...min(w - 1, x + r) where mask[yy * w + xx] == 0 {
                        out[y * w + x] = 0
                        break outer
                    }
                }
            }
        }
        return out
    }

    /// The working-size result with `longSide` pixels on its longer side: Apple's super resolution where
    /// the Mac has it, else resampled.
    private static func enlarged(_ bitmap: RGBABitmap, longSide: Int) async throws -> CGImage {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let image = bitmap.makeImage(space: sRGB) else { throw ExtendError.failed }
        let scale = CGFloat(longSide) / CGFloat(max(image.width, image.height))
        guard scale > 1.05 else { return image }
        if scale > 1.5, SuperResolution.modelState == .ready, SuperResolution.fits(width: image.width, height: image.height),
           let upscaled = try? await SuperResolution.upscale(image, scale: min(CGFloat(SuperResolution.factor), scale)) {
            return upscaled
        }
        let w = Int((CGFloat(image.width) * scale).rounded()), h = Int((CGFloat(image.height) * scale).rounded())
        var big = RGBABitmap(width: w, height: h)
        big.draw(image, topLeftRect: CGRect(x: 0, y: 0, width: w, height: h), space: sRGB, quality: .high)
        guard let result = big.makeImage(space: sRGB) else { throw ExtendError.failed }
        return result
    }
}
