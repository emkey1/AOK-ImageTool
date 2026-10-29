import CoreImage
import Foundation
import ImageIO

/// Segmentation masks (single-channel images in source pixel space) kept outside `EditState`
/// so the edit recipe stays a small value type.
nonisolated final class MaskStore: @unchecked Sendable {
    static let shared = MaskStore()

    private let lock = NSLock()
    private var subjectMasks: [URL: CIImage] = [:]
    private var objectMasks: [UUID: CIImage] = [:]

    func subjectMask(for url: URL) -> CIImage? {
        lock.withLock { subjectMasks[url] }
    }

    func setSubjectMask(_ mask: CIImage, for url: URL) {
        lock.withLock { subjectMasks[url] = mask }
    }

    func addObjectMask(_ mask: CIImage) -> UUID {
        let id = UUID()
        lock.withLock { objectMasks[id] = mask }
        return id
    }

    func mask(for cutout: Cutout, url: URL) -> CIImage? {
        switch cutout {
        case .subject: subjectMask(for: url)
        case .object(let id): lock.withLock { objectMasks[id] }
        }
    }

    func forget(_ url: URL) {
        lock.withLock { _ = subjectMasks.removeValue(forKey: url) }
    }
}

/// Renders an `EditState` over a decoded image with Core Image.
nonisolated final class EditRenderer: @unchecked Sendable {
    static let shared = EditRenderer()

    enum Stage: Sendable {
        /// Everything.
        case full
        /// Everything except Extend, the crop and vignette (what the crop tool shows).
        case beforeCrop
        /// Cutout, background, perspective and rotation/straightening, without adjustments: what Extend
        /// continues (adjustments apply to the original and the fill alike afterwards).
        case geometry
        /// The source with cutout only, no adjustments or geometry (what object selection works on).
        case source
    }

    struct Output: @unchecked Sendable {
        let image: CGImage
        let fullSize: CGSize
    }

    let context = CIContext(options: [.cacheIntermediates: false, .name: "EditRenderer"])

    private let lock = NSLock()
    private var autoRecipes: [URL: [(String, [String: Any])]] = [:]
    private var proxies: [(key: String, image: CGImage)] = []
    private var backdrops: [String: CIImage] = [:]
    private var patches: [String: CIImage] = [:]
    private var lightingCache: [String: (subject: [CGFloat], background: [CGFloat])] = [:]

    // MARK: - Public API

    func render(_ decoded: DecodedImage, edits: EditState, maxDimension: CGFloat?, stage: Stage = .full) async -> Output? {
        await Task.detached(priority: .userInitiated) {
            self.renderSync(decoded, edits: edits, maxDimension: maxDimension, stage: stage)
        }.value
    }

    func renderSync(_ decoded: DecodedImage, edits: EditState, maxDimension: CGFloat?, stage: Stage = .full) -> Output? {
        let image = makeImage(decoded, edits: edits, maxDimension: maxDimension, stage: stage)
        let fullSize = maxDimension == nil
            ? image.extent.size
            : makeImage(decoded, edits: edits, maxDimension: nil, stage: stage).extent.size
        guard let cg = createCGImage(image, like: decoded) else { return nil }
        return Output(image: cg, fullSize: fullSize)
    }

    /// Output size of a full-resolution render, without rendering pixels.
    func outputSize(_ decoded: DecodedImage, edits: EditState) -> CGSize {
        makeImage(decoded, edits: edits, maxDimension: nil, stage: .full).extent.size
    }

    func createCGImage(_ image: CIImage, like decoded: DecodedImage) -> CGImage? {
        let deep = decoded.isHDR || decoded.cgImage.bitsPerComponent > 8
        return context.createCGImage(image, from: image.extent, format: deep ? .RGBAh : .RGBA8,
                                     colorSpace: outputColorSpace(for: decoded), deferred: false)
    }

    func outputColorSpace(for decoded: DecodedImage) -> CGColorSpace {
        if let cs = decoded.cgImage.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Small previews of every filter preset applied on top of the current edits.
    func presetPreviews(_ decoded: DecodedImage, edits: EditState, size: CGFloat) -> [FilterPreset: CGImage] {
        var result: [FilterPreset: CGImage] = [:]
        for preset in FilterPreset.allCases {
            var e = edits
            e.filter = preset
            e.filterIntensity = 1
            let img = makeImage(decoded, edits: e, maxDimension: size, stage: .full)
            if let cg = context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
                result[preset] = cg
            }
        }
        return result
    }

    func forget(_ url: URL) {
        lock.withLock {
            autoRecipes[url] = nil
            proxies.removeAll { $0.key.hasPrefix(url.path + "|") }
        }
    }

    // MARK: - Pipeline

    func makeImage(_ decoded: DecodedImage, edits e: EditState, maxDimension: CGFloat?, stage: Stage) -> CIImage {
        // 0. Objects painted out (Remove Objects), part of the picture from here on.
        let base = withRemovals(baseImage(decoded, maxDimension: maxDimension), e.removals)
        var img = base
        let scale = img.extent.width / max(decoded.pixelSize.width, 1)

        // 1. Cutout (mask lives in source space; scale it onto the base image).
        var subjectMask: CIImage?
        if let cutout = e.cutout, let mask = MaskStore.shared.mask(for: cutout, url: decoded.url) {
            let ext = img.extent
            let m = mask
                .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: ext.width / mask.extent.width, y: ext.height / mask.extent.height))
            subjectMask = m
            img = img.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: ext),
                kCIInputMaskImageKey: m,
            ])
        }
        if stage == .source { return normalized(img) }

        // 2. What shows through: behind a cutout, or behind transparency already in the file (a saved cutout,
        //    an upscaled copy of one, a logo…). Optionally with the subject's light matched to a picture.
        if let backdrop = e.background {
            var layer: (subject: CIImage, mask: CIImage)?
            if e.cutout != nil, let m = subjectMask {
                layer = (base, m)
            } else if e.cutout == nil, decoded.hasTransparentPixels {
                layer = (base.unpremultiplyingAlpha().settingAlphaOne(in: base.extent), Self.alphaMask(of: base))
            }
            if let layer, let behind = backdropImage(backdrop, base: base) {
                if case .image(let path) = backdrop, let strength = e.matchLighting, strength > 0 {
                    let source = e.cutout.map { "\($0)" } ?? "alpha"
                    let key = "\(decoded.url.path)|\(ObjectIdentifier(decoded).hashValue)|\(source)|\(path)"
                    img = lightMatched(layer.subject, mask: layer.mask, behind: behind, strength: strength, key: key)
                } else {
                    img = img.composited(over: behind)
                }
            }
        }

        // 3. Perspective (document) correction.
        if let q = e.perspective { img = perspectiveCorrected(img, q) }

        // 4. Geometry. Before the adjustments (which are per-pixel, so the order doesn't change them) so that
        //    Extend's fill, made from this stage, gets the same adjustments as the original pixels.
        img = applyOrientation(img, e)
        if e.straighten != 0 {
            img = straightened(img, degrees: e.straighten)
        }
        img = normalized(img)
        if stage == .geometry { return img }
        let frame = img.extent   // `crop` is relative to this

        // 5. Extend: when the crop reaches past the image, the fill shows there (transparent until it's made).
        if stage == .full, let c = e.crop, e.cropExtendsBeyondImage {
            // Whole pixels, as the crop below rounds outward; the fill's edge pixels cover the last sliver.
            let canvas = Self.pixelRect(c, in: frame).integral
            var under = CIImage(color: .clear).cropped(to: canvas)
            if let fill = e.extendFill, fill.covers(c), let picture = backdropPicture(fill.path) {
                let target = Self.pixelRect(fill.canvas, in: frame)
                // Clamped before scaling, so resampling at the edges never blends in transparency.
                under = picture.clampedToExtent()
                    .transformed(by: CGAffineTransform(scaleX: target.width / picture.extent.width, y: target.height / picture.extent.height))
                    .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
                    .cropped(to: canvas)
                let band = (fill.feather ?? 0) * min(frame.width, frame.height)
                if band > 0 || fill.content != nil {
                    img = img.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: under,
                        kCIInputMaskImageKey: Self.pictureMask(frame, content: fill.content, band: band, crop: c),
                    ]).cropped(to: canvas)
                } else {
                    img = img.composited(over: under)
                }
            } else {
                img = img.composited(over: under)
            }
        }

        // 6–9. Auto enhance, light & color, detail, look.
        img = applyAdjustments(img, e, decoded: decoded, scale: scale)
        if stage == .beforeCrop { return normalized(img) }

        // 10. Crop (possibly beyond the original frame, onto the Extend fill).
        if let c = e.crop {
            let rect = Self.pixelRect(c, in: frame).integral.intersection(img.extent)
            if rect.width >= 1, rect.height >= 1 { img = img.cropped(to: rect) }
        }
        img = normalized(img)

        // 11. Vignette (relative to the final frame).
        return vignetted(img, e.vignette)
    }

    /// The picture as white balance sees it: turned and straightened, with Auto enhance, before light and color
    /// (and uncropped, so a spot is found by where it is before the crop). For the eyedropper and Auto.
    func whiteBalanceInput(_ decoded: DecodedImage, edits e: EditState, maxDimension: CGFloat?) -> CIImage {
        var img = makeImage(decoded, edits: e, maxDimension: maxDimension, stage: .geometry)
        if e.autoEnhance {
            for (name, params) in autoRecipe(for: decoded) { img = img.applyingFilter(name, parameters: params) }
        }
        return img
    }

    /// The edits that hold for every frame of a Live Photo (perspective, turns, straightening, light and
    /// color, filters, crop, vignette) on one frame, upright. `still` is the photo they were made on (Auto's
    /// recipe comes from it); `renderScale` is the frame's size relative to it. A cutout, a background and
    /// Extend are for the still only.
    func applyToFrame(_ frame: CIImage, edits e: EditState, still: DecodedImage, renderScale: CGFloat) -> CIImage {
        var img = normalized(frame)
        if let q = e.perspective { img = perspectiveCorrected(img, q) }
        img = applyOrientation(img, e)
        if e.straighten != 0 { img = straightened(img, degrees: e.straighten) }
        img = normalized(img)
        let frameRect = img.extent
        img = applyAdjustments(img, e, decoded: still, scale: renderScale)
        if let c = e.crop, !e.cropExtendsBeyondImage {
            let rect = Self.pixelRect(c, in: frameRect).integral.intersection(img.extent)
            if rect.width >= 1, rect.height >= 1 { img = img.cropped(to: rect) }
        }
        return vignetted(normalized(img), e.vignette)
    }

    private func perspectiveCorrected(_ img: CIImage, _ q: Quad) -> CIImage {
        let ext = img.extent
        func p(_ n: CGPoint) -> CIVector { CIVector(x: ext.minX + n.x * ext.width, y: ext.minY + n.y * ext.height) }
        return normalized(img.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": p(q.topLeft), "inputTopRight": p(q.topRight),
            "inputBottomRight": p(q.bottomRight), "inputBottomLeft": p(q.bottomLeft),
            "inputCrop": true,
        ]))
    }

    private func vignetted(_ img: CIImage, _ amount: Double) -> CIImage {
        guard amount > 0 else { return img }
        let ext = img.extent
        return img.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: ext.midX, y: ext.midY),
            kCIInputRadiusKey: 0.62 * max(ext.width, ext.height),
            kCIInputIntensityKey: amount,
            "inputFalloff": 0.6,
        ]).cropped(to: ext)
    }

    /// The per-pixel adjustments, in pipeline order. `scale` is the image's size relative to the source.
    private func applyAdjustments(_ input: CIImage, _ e: EditState, decoded: DecodedImage, scale: CGFloat) -> CIImage {
        var img = input
        // 6. Auto enhance.
        if e.autoEnhance {
            for (name, params) in autoRecipe(for: decoded) {
                img = img.applyingFilter(name, parameters: params)
            }
        }

        // 7. Light & color.
        img = applyLightAndColor(img, e)

        // 8. Detail.
        if e.noiseReduction > 0 {
            img = img.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.01 + e.noiseReduction * 0.05, kCIInputSharpnessKey: 0.4,
            ])
        }
        if e.sharpness > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: e.sharpness * 1.2, kCIInputRadiusKey: max(0.5, 1.7 * scale),
            ])
        }

        // 9. Look.
        if e.filter != .none {
            let filtered = applyPreset(e.filter, to: img)
            img = e.filterIntensity >= 0.999 ? filtered : img.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: filtered, kCIInputTimeKey: e.filterIntensity,
            ])
        }
        return img
    }

    /// A black and white version of `picture` (a rendered image; Black & White makes a copy).
    func blackAndWhite(_ picture: CGImage, _ bw: BlackAndWhite) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        return context.createCGImage(blackAndWhite(CIImage(cgImage: picture), bw), from: rect,
                                     format: picture.bitsPerComponent > 8 ? .RGBAh : .RGBA8,
                                     colorSpace: picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Colors to grays through the chosen camera filter (in linear light, like a filter on a lens), then
    /// toned.
    private func blackAndWhite(_ input: CIImage, _ bw: BlackAndWhite) -> CIImage {
        let w = bw.filter.weights
        let gray = CIVector(x: w.red, y: w.green, z: w.blue, w: 0)
        var img = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": gray, "inputGVector": gray, "inputBVector": gray,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        if bw.toning != .none {
            let t = bw.toning.tint, a = min(max(bw.toningAmount, 0), 1)
            func toned(_ c: Double) -> Double { 1 + a * (c - 1) }
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: toned(t.red), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: toned(t.green), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: toned(t.blue), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        }
        return img
    }

    /// Another picture with the edits' adjustments, e.g. a preview of Extend's fill (which is made from the
    /// unadjusted geometry stage). `scale` is its size relative to the source image.
    func adjusted(_ picture: CGImage, like decoded: DecodedImage, edits: EditState, scale: CGFloat) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        let img = applyAdjustments(CIImage(cgImage: picture), edits, decoded: decoded, scale: scale)
        return context.createCGImage(img, from: rect, format: .RGBA8,
                                     colorSpace: picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// The image's alpha channel as an opaque grayscale mask (white = keep), like a cutout mask.
    static func alphaMask(of image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// A backdrop filling `base`'s extent: a color, `base` blurred, or a picture scaled to fill.
    private func backdropImage(_ backdrop: Backdrop, base: CIImage) -> CIImage? {
        let ext = base.extent
        switch backdrop {
        case .color(let red, let green, let blue, let alpha):
            guard let color = CIColor(red: red, green: green, blue: blue, alpha: alpha,
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
            return CIImage(color: color).cropped(to: ext)
        case .blur(let amount):
            // Relative to the image size, so proxies and full renders match.
            let sigma = max(1, amount * 0.04 * max(ext.width, ext.height))
            return base.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ext)
        case .image(let path):
            guard let picture = backdropPicture(path) else { return nil }
            let size = picture.extent.size
            let fill = max(ext.width / size.width, ext.height / size.height)
            return picture
                .transformed(by: CGAffineTransform(scaleX: fill, y: fill))
                .transformed(by: CGAffineTransform(translationX: ext.midX - size.width * fill / 2, y: ext.midY - size.height * fill / 2))
                .cropped(to: ext)
        }
    }

    /// The subject of `base` composited over `behind` with its light moved toward the picture's. Light multiplies
    /// what it falls on, so the subject is scaled per channel (blacks stay black): its exposure moves halfway (in
    /// stops) toward the background's, and it takes on part of the background's color cast. The background's
    /// light also wraps softly around the subject's edges.
    func lightMatched(_ base: CIImage, mask m: CIImage, behind: CIImage, strength: Double, key: String) -> CIImage {
        let ext = base.extent
        let s = CGFloat(strength)
        var subject = base
        if let means = lightingMeans(base, mask: m, behind: behind, key: key) {
            func luma(_ c: [CGFloat]) -> CGFloat { max(0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2], 0.0001) }
            let (ls, lb) = (luma(means.subject), luma(means.background))
            let exposure = min(max(pow(lb / ls, 0.5 * s), 0.4), 2.5)
            // Color of the light: each channel relative to brightness, moved a third of the way, then
            // normalized so it doesn't change brightness.
            var tint = (0..<3).map { c in
                min(max(pow((means.background[c] / lb) / max(means.subject[c] / ls, 0.0001), 0.35 * s), 0.6), 1.6)
            }
            let norm = luma(zip(tint, means.subject).map { $0 * $1 }) / ls
            tint = tint.map { $0 / norm }
            subject = base.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: exposure * tint[0], y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: exposure * tint[1], z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: exposure * tint[2], w: 0),
            ])
        }
        let composite = subject.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: behind, kCIInputMaskImageKey: m,
        ])

        // Light wrap: the background, blurred, mixed into the subject just inside its edge.
        let radius = 0.02 * max(ext.width, ext.height)
        let glow = behind.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ext)
        let outside = m.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ext).applyingFilter("CIColorInvert")
        let amount = 0.6 * s
        let edge = m.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: outside])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
            ])
        return glow.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: composite, kCIInputMaskImageKey: edge,
        ]).cropped(to: ext)
    }

    /// Average color (linear) of the subject, weighted by the mask, and of the background around it. Measured on
    /// small copies and kept: they don't depend on the strength or the render size.
    private func lightingMeans(_ base: CIImage, mask m: CIImage, behind: CIImage, key: String) -> (subject: [CGFloat], background: [CGFloat])? {
        if let hit = lock.withLock({ lightingCache[key] }) { return hit }
        let ext = base.extent
        let f = min(1, 256 / max(ext.width, ext.height))
        let rect = CGRect(x: 0, y: 0, width: max(1, (ext.width * f).rounded(.down)), height: max(1, (ext.height * f).rounded(.down)))
        func small(_ image: CIImage) -> CIImage { image.transformed(by: CGAffineTransform(scaleX: f, y: f)) }
        func average(_ image: CIImage) -> [CGFloat] {
            let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
            var px = [Float](repeating: 0, count: 4)
            context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return px.prefix(3).map { CGFloat($0) }
        }
        func mean(_ image: CIImage, weight: CIImage) -> [CGFloat]? {
            let total = average(weight)[0]
            guard total > 0.02 else { return nil }
            let weighted = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
            return average(weighted).map { $0 / total }
        }
        let weight = small(m)
        guard let subject = mean(small(base), weight: weight),
              let background = mean(small(behind), weight: weight.applyingFilter("CIColorInvert")) else { return nil }
        lock.withLock {
            if lightingCache.count > 16 { lightingCache.removeAll() }
            lightingCache[key] = (subject, background)
        }
        return (subject, background)
    }

    /// Remove Objects' patches laid over `image` in order (they're placed by normalized rects, so they fit a
    /// proxy as well as the full image).
    private func withRemovals(_ image: CIImage, _ removals: [Removal]?) -> CIImage {
        guard let removals, !removals.isEmpty else { return image }
        let ext = image.extent
        var img = image
        for removal in removals {
            guard var patch = removalPatch(removal.path) else { continue }
            if let opacity = removal.opacity, opacity < 1 {
                patch = patch.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(opacity, 0))])
            }
            let target = Self.pixelRect(removal.rect, in: ext)
            img = patch
                .transformed(by: CGAffineTransform(scaleX: target.width / patch.extent.width, y: target.height / patch.extent.height))
                .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
                .composited(over: img)
        }
        return img.cropped(to: ext)
    }

    /// Patches, decoded once at full size and kept for later renders.
    private func removalPatch(_ path: String) -> CIImage? {
        if let hit = lock.withLock({ patches[path] }) { return hit }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let patch = CIImage(cgImage: cg)
        lock.withLock {
            if patches.count > 32 { patches.removeAll() }
            patches[path] = patch
        }
        return patch
    }

    /// Backdrop pictures, decoded once (upright, at most 4096 px) and kept for later renders.
    private func backdropPicture(_ path: String) -> CIImage? {
        if let hit = lock.withLock({ backdrops[path] }) { return hit }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary)
        else { return nil }
        let picture = CIImage(cgImage: cg)
        lock.withLock {
            if backdrops.count > 8 { backdrops.removeAll() }
            backdrops[path] = picture
        }
        return picture
    }

    /// A normalized, top-left-origin rect (like `EditState.crop`) in Core Image pixel coordinates of `frame`.
    /// Where the photo is drawn over Extend's fill: white over its picture (all of it, or the part inside a
    /// print's border), ramping to black over `band` at the edges the fill continues past (the crop's
    /// extended sides, and a removed border's). Core Image coordinates: the crop's top is the frame's maxY.
    static func pictureMask(_ frame: CGRect, content: CGRect?, band: CGFloat, crop c: CGRect) -> CIImage {
        let n = content ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let r = CGRect(x: frame.minX + n.minX * frame.width, y: frame.minY + (1 - n.maxY) * frame.height,
                       width: n.width * frame.width, height: n.height * frame.height)
        var mask = CIImage(color: .white).cropped(to: r)
        guard band > 0 else { return mask }
        func ramp(from: CGPoint, to: CGPoint) -> CIImage {
            CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: from), "inputPoint1": CIVector(cgPoint: to),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white,
            ])!.outputImage!
        }
        var edges: [CIImage] = []
        if c.minX < -0.001 || n.minX > 0.0005 { edges.append(ramp(from: CGPoint(x: r.minX, y: 0), to: CGPoint(x: r.minX + band, y: 0))) }
        if c.maxX > 1.001 || n.maxX < 0.9995 { edges.append(ramp(from: CGPoint(x: r.maxX, y: 0), to: CGPoint(x: r.maxX - band, y: 0))) }
        if c.minY < -0.001 || n.minY > 0.0005 { edges.append(ramp(from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.maxY - band))) }
        if c.maxY > 1.001 || n.maxY < 0.9995 { edges.append(ramp(from: CGPoint(x: 0, y: r.minY), to: CGPoint(x: 0, y: r.minY + band))) }
        for edge in edges { mask = edge.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask]) }
        return mask.cropped(to: r)
    }

    static func pixelRect(_ r: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width,
               y: frame.minY + (1 - r.maxY) * frame.height,
               width: r.width * frame.width,
               height: r.height * frame.height)
    }

    private func normalized(_ img: CIImage) -> CIImage {
        let ext = img.extent
        guard ext.minX != 0 || ext.minY != 0 else { return img }
        return img.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
    }

    /// The decoded image, downscaled once and cached when a proxy size is requested (keeps slider drags fast).
    private func baseImage(_ decoded: DecodedImage, maxDimension: CGFloat?) -> CIImage {
        let longest = max(decoded.pixelSize.width, decoded.pixelSize.height)
        guard let maxDimension, longest > maxDimension else { return CIImage(cgImage: decoded.cgImage) }
        let key = "\(decoded.url.path)|\(decoded.pageIndex)|\(ObjectIdentifier(decoded).hashValue)|\(Int(maxDimension))"
        if let hit = lock.withLock({ proxies.first { $0.key == key }?.image }) {
            return CIImage(cgImage: hit)
        }
        let s = maxDimension / longest
        // Clamped first, so the edges don't fade to transparent (Extend would continue a darkened edge).
        let scaled = CIImage(cgImage: decoded.cgImage).clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: s, kCIInputAspectRatioKey: 1,
        ])
        let size = CGRect(x: 0, y: 0, width: (decoded.pixelSize.width * s).rounded(), height: (decoded.pixelSize.height * s).rounded())
        guard let cg = createCGImage(normalized(scaled.cropped(to: size)), like: decoded) else {
            return scaled.cropped(to: size)
        }
        lock.withLock {
            proxies.insert((key, cg), at: 0)
            if proxies.count > 6 { proxies.removeLast() }
        }
        return CIImage(cgImage: cg)
    }

    private func autoRecipe(for decoded: DecodedImage) -> [(String, [String: Any])] {
        if let hit = lock.withLock({ autoRecipes[decoded.url] }) { return hit }
        let base = baseImage(decoded, maxDimension: 1024)
        let filters = base.autoAdjustmentFilters(options: [.redEye: false])
        let recipe: [(String, [String: Any])] = filters.map { f in
            var params: [String: Any] = [:]
            for key in f.inputKeys where key != kCIInputImageKey {
                if let v = f.value(forKey: key) { params[key] = v }
            }
            return (f.name, params)
        }
        lock.withLock { autoRecipes[decoded.url] = recipe }
        return recipe
    }

    private func applyLightAndColor(_ input: CIImage, _ e: EditState) -> CIImage {
        var img = input
        if e.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: e.exposure])
        }
        img = WhiteBalance.apply(img, temperature: e.temperature, tint: e.tint)
        if e.brightness != 0 || e.highlights > 0 {
            let b = e.brightness * 0.12
            let h = max(0, e.highlights) * 0.1
            func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: clamp(0.25 + b * 0.8)),
                "inputPoint2": CIVector(x: 0.5, y: clamp(0.5 + b)),
                "inputPoint3": CIVector(x: 0.75, y: clamp(0.75 + b * 0.7 + h)),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        if e.highlights < 0 || e.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(0, e.highlights),
                "inputShadowAmount": e.shadows,
            ])
        }
        if e.contrast != 0 || e.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + e.contrast * 0.4,
                kCIInputSaturationKey: 1 + e.saturation,
                kCIInputBrightnessKey: 0,
            ])
        }
        if e.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: e.vibrance])
        }
        return img
    }

    private func applyPreset(_ preset: FilterPreset, to img: CIImage) -> CIImage {
        switch preset {
        case .none:
            return img
        case .vivid:
            return img
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3, kCIInputContrastKey: 1.08, kCIInputBrightnessKey: 0])
                .applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: 0.35])
        case .warm:
            return img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 8200, y: 6), "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        case .cool:
            return img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 5200, y: -4), "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        case .dramatic:
            return img
                .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.7, "inputShadowAmount": 0.25])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.22, kCIInputBrightnessKey: -0.02])
        case .mono: return img.applyingFilter("CIPhotoEffectMono")
        case .noir: return img.applyingFilter("CIPhotoEffectNoir")
        case .silvertone: return img.applyingFilter("CIPhotoEffectTonal")
        case .chrome: return img.applyingFilter("CIPhotoEffectChrome")
        case .fade: return img.applyingFilter("CIPhotoEffectFade")
        case .instant: return img.applyingFilter("CIPhotoEffectInstant")
        case .process: return img.applyingFilter("CIPhotoEffectProcess")
        case .transfer: return img.applyingFilter("CIPhotoEffectTransfer")
        case .sepia: return img.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
        }
    }

    private func applyOrientation(_ input: CIImage, _ e: EditState) -> CIImage {
        var img = input
        if e.flipHorizontal { img = img.oriented(.upMirrored) }
        if e.flipVertical { img = img.oriented(.downMirrored) }
        switch ((e.quarterTurns % 4) + 4) % 4 {
        case 1: img = img.oriented(.right)
        case 2: img = img.oriented(.down)
        case 3: img = img.oriented(.left)
        default: break
        }
        return normalized(img)
    }

    /// Rotates by `degrees` (clockwise) and crops to the largest centered rectangle of the
    /// original aspect ratio that contains no empty corners.
    private func straightened(_ input: CIImage, degrees: Double) -> CIImage {
        let ext = input.extent
        let theta = degrees * .pi / 180
        let center = CGPoint(x: ext.midX, y: ext.midY)
        let rotation = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -theta)
            .translatedBy(x: -center.x, y: -center.y)
        let rotated = input.clampedToExtent().transformed(by: rotation)
        let scale = Self.inscribedScale(size: ext.size, degrees: degrees)
        let w = ext.width * scale
        let h = ext.height * scale
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h).integral
        return normalized(rotated.cropped(to: rect))
    }

    static func inscribedScale(size: CGSize, degrees: Double) -> CGFloat {
        let t = abs(degrees) * .pi / 180
        let w = size.width / 2
        let h = size.height / 2
        let s1 = w / (w * cos(t) + h * sin(t))
        let s2 = h / (w * sin(t) + h * cos(t))
        return min(s1, s2, 1)
    }
}
