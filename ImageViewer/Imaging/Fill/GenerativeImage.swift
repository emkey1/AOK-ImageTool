import CoreGraphics
import CoreImage
import Foundation

/// The on-device model's use besides Extend, offered next to Image Playground (or instead of it, where a
/// Mac has none): a background painted around a cut-out subject. (Not Reimagine: this model restyles photos
/// weakly and doesn't keep a person's likeness, which Image Playground does.)
nonisolated enum GenerativeImage {
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
