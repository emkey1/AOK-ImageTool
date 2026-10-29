import CoreImage
import Foundation

/// Combine Pictures: the subject of one picture (its background removed: by Vision, or by its own
/// transparency) laid on another picture, where it can be moved, sized and flipped, its light matched to
/// the new background and a soft shadow put under it.
nonisolated enum Combine {
    /// A picture's subject, cut out and cropped to it.
    struct Subject: @unchecked Sendable {
        let image: CGImage
        /// Where it was in its own picture: fractions of it, top-left origin.
        let rect: CGRect
    }

    /// Where the subject goes on the background.
    struct Layout: Equatable, Sendable {
        /// Its center, as fractions of the background (top-left origin).
        var center: CGPoint
        /// Its height, as a fraction of the background's.
        var height: Double
        var flipped = false

        /// Where it was in its own picture, at the same height and place in the background (as near as
        /// fits: no wider than the background).
        static func initial(for subject: Subject, on background: CGSize) -> Layout {
            let aspect = Double(subject.image.width) / Double(max(subject.image.height, 1))
            let widthPerHeight = aspect * Double(background.height) / Double(max(background.width, 1))
            var height = min(max(Double(subject.rect.height), 0.2), 0.95)
            height = min(height, 0.95 / max(widthPerHeight, 0.0001))
            // (It keeps its bottom where it was: people and things stand on something.)
            let bottom = Double(subject.rect.maxY)
            let center = CGPoint(x: min(max(Double(subject.rect.midX), height * widthPerHeight / 2), 1 - height * widthPerHeight / 2),
                                 y: min(max(bottom - height / 2, height / 2), 1 - height / 2))
            return Layout(center: center, height: height)
        }

        /// The subject's rect in the background, as fractions of it (top-left origin).
        func rect(for subject: Subject, on background: CGSize) -> CGRect {
            let aspect = Double(subject.image.width) / Double(max(subject.image.height, 1))
            let width = height * aspect * Double(background.height) / Double(max(background.width, 1))
            return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        }
    }

    // MARK: The subject

    /// The subject of `picture`: where it's transparent, what isn't; otherwise the foreground subjects
    /// Vision finds (people, animals, things).
    @concurrent static func subject(of picture: CGImage, transparent: Bool) async throws -> Subject {
        let base = CIImage(cgImage: picture)
        let ext = base.extent
        let mask: CIImage
        if transparent {
            // (Cropped: the mask's filter fills the whole plane around the picture.)
            mask = EditRenderer.alphaMask(of: base).cropped(to: ext)
        } else {
            let m = try await VisionServices.subjectMask(for: picture)
            mask = m.transformed(by: CGAffineTransform(translationX: -m.extent.minX, y: -m.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: ext.width / m.extent.width, y: ext.height / m.extent.height))
        }
        guard let bounds = VisionServices.maskBounds(mask, imageSize: ext.size)?.integral.intersection(ext), !bounds.isEmpty else {
            throw VisionError.noSubject
        }
        let cut = defringed(base, mask: mask).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: ext),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: bounds)
        let space = picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let image = ImageDecoder.ciContext.createCGImage(cut, from: bounds, format: .RGBA8, colorSpace: space) else {
            throw VisionError.noSubject
        }
        let rect = CGRect(x: bounds.minX / ext.width, y: 1 - bounds.maxY / ext.height, width: bounds.width / ext.width, height: bounds.height / ext.height)
        return Subject(image: image, rect: rect)
    }

    /// `base` with the color of its subject's edge (where `mask` is between in and out) taken from the subject
    /// just inside it, so the old background (snow around a fox) doesn't come along as a pale fringe.
    private static func defringed(_ base: CIImage, mask: CIImage) -> CIImage {
        let ext = base.extent
        func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
            a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b])
        }
        // The inside counts most (mask cubed); its colors are spread a little way out and averaged.
        let weight = multiply(multiply(mask, mask), mask)
        let radius = max(2, 0.004 * max(ext.width, ext.height))
        func blurred(_ image: CIImage) -> CIImage { image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ext) }
        // (A hair over zero, so far outside, where nothing's weighed, there's no dividing by it.)
        let total = blurred(weight).applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: 0.0005, y: 0.0005, z: 0.0005, w: 0)])
        let colors = blurred(multiply(base.settingAlphaOne(in: ext), weight))
        // (The divide blend divides its background by its image.)
        let spread = total.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: colors])
        // Wholly inside keeps its own color; the further out, the more it takes the inside's.
        return spread.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base,
            kCIInputMaskImageKey: mask.applyingFilter("CIColorInvert"),
        ]).cropped(to: ext)
    }

    /// A brush stroke over the subject: points and radius as fractions of the subject (top-left origin; the
    /// radius of its height), taking away from it, or putting back what was taken.
    struct Stroke: Equatable, Sendable {
        var points: [CGPoint]
        var radius: Double
        var restore: Bool
    }

    /// `original` with `strokes` taken away from (or put back into) it.
    static func erased(_ original: Subject, by strokes: [Stroke]) -> Subject {
        guard !strokes.isEmpty else { return original }
        let w = original.image.width, h = original.image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return original }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes {
            let gray: CGFloat = stroke.restore ? 1 : 0
            ctx.setStrokeColor(gray: gray, alpha: 1)
            ctx.setFillColor(gray: gray, alpha: 1)
            let radius = stroke.radius * Double(h)
            ctx.setLineWidth(radius * 2)
            // (The bitmap's origin is the bottom left.)
            let points = stroke.points.map { CGPoint(x: $0.x * Double(w), y: (1 - $0.y) * Double(h)) }
            if points.count == 1, let p = points.first {
                ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            } else if let first = points.first {
                ctx.beginPath()
                ctx.move(to: first)
                for p in points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
        }
        guard let keep = ctx.makeImage() else { return original }
        let image = CIImage(cgImage: original.image)
        let ext = image.extent
        let kept = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: ext),
            kCIInputMaskImageKey: CIImage(cgImage: keep),
        ])
        let space = original.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let made = ImageDecoder.ciContext.createCGImage(kept, from: ext, format: .RGBA8, colorSpace: space) else { return original }
        return Subject(image: made, rect: original.rect)
    }

    // MARK: Combining

    /// `subject` laid on `background` by `layout`, its light moved toward the background's (`matchLighting`,
    /// 0...1) and a soft shadow under it (`shadow`, 0...1), at the background's size.
    static func compose(background: CGImage, subject: Subject, layout: Layout, matchLighting: Double, shadow: Double) -> CGImage? {
        let behind = CIImage(cgImage: background)
        let ext = behind.extent
        let rect = layout.rect(for: subject, on: ext.size)
        // (Core Image's origin is the bottom left.)
        let target = CGRect(x: rect.minX * ext.width, y: (1 - rect.maxY) * ext.height, width: rect.width * ext.width, height: rect.height * ext.height)
        var cut = CIImage(cgImage: subject.image)
        let size = cut.extent.size
        var transform = CGAffineTransform(scaleX: target.width / size.width, y: target.height / size.height)
        if layout.flipped { transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -target.width, y: 0)) }
        cut = cut.transformed(by: transform).transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        let placed = cut.composited(over: CIImage(color: .clear).cropped(to: ext)).cropped(to: ext)
        let mask = EditRenderer.alphaMask(of: placed).cropped(to: ext)

        var ground = behind
        if shadow > 0 {
            // Soft, a little below: the subject's own shape, darkening what's behind it.
            let blur = max(2, 0.025 * target.height)
            let darkness = 0.55 * min(shadow, 1)
            // (Its edges stretched out before it's moved: moving it first would stretch a half-transparent edge.)
            let shade = mask.clampedToExtent().transformed(by: CGAffineTransform(translationX: 0.006 * target.height, y: -0.012 * target.height))
                .applyingGaussianBlur(sigma: blur).cropped(to: ext)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: darkness, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: darkness, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: darkness, w: 0),
                ])
                .applyingFilter("CIColorInvert")
                .settingAlphaOne(in: ext)
            ground = behind.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: shade]).cropped(to: ext)
        }

        let result: CIImage
        if matchLighting > 0 {
            let key = "combine|\(ObjectIdentifier(background).hashValue)|\(ObjectIdentifier(subject.image).hashValue)|\(target)|\(layout.flipped)"
            result = EditRenderer.shared.lightMatched(placed.unpremultiplyingAlpha().settingAlphaOne(in: ext), mask: mask, behind: ground,
                                                      strength: matchLighting, key: key)
        } else {
            result = placed.composited(over: ground)
        }
        let space = background.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ImageDecoder.ciContext.createCGImage(result.cropped(to: ext), from: ext, format: .RGBA8, colorSpace: space)
    }

    /// `image` no bigger than `longSide` (for the preview).
    static func reduced(_ image: CGImage, longSide: CGFloat) -> CGImage {
        let scale = longSide / CGFloat(max(image.width, image.height))
        guard scale < 1 else { return image }
        let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ImageDecoder.ciContext.createCGImage(ci, from: ci.extent.integral, format: .RGBA8, colorSpace: space) ?? image
    }
}
