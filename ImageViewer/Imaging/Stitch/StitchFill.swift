import CoreImage
import Foundation

/// What to do about the parts of a stitched picture that no picture covers.
nonisolated enum StitchEdges: String, CaseIterable, Identifiable, Sendable {
    /// Keep only the largest upright rectangle that's covered everywhere.
    case crop
    /// Keep everything, and fill what isn't covered.
    case fill

    var id: String { rawValue }
    var title: String {
        switch self {
        case .crop: "Crop"
        case .fill: "Fill"
        }
    }
}

nonisolated extension Stitch {
    /// How far inside the pictures' edges a generated filling is redrawn for them to fade into, as a fraction
    /// of the filling's shorter side.
    static let bandFraction: CGFloat = 0.004

    /// What fills the uncovered parts of a stitched picture: the same view, made at another size.
    struct Filling: @unchecked Sendable {
        /// The whole view, the pictures' own parts included (they're put back over it at full size).
        let image: CGImage
        /// As `Stitched`'s: its pixels to a unit of the view, and where its top left corner is.
        let scale: Double
        let origin: CGPoint
        /// How far inside the pictures' edges (its pixels) it was made to carry on from them: the pictures fade
        /// into it over that.
        let band: Double
        let method: ExtendMethod
        /// What gives the filled-in parts the pictures' own fine texture when they're put under the pictures,
        /// at whatever size (nil: there was no memory for it, and they're left as smooth as they were made).
        let detail: Detail?
    }

    /// Where each filled-in place takes its fine texture from (see StitchDetail.h): worked out once, at the
    /// filling's size, so that the preview and the picture saved at full size get the same.
    final class Detail: @unchecked Sendable {
        let plan: OpaquePointer

        /// `filling`: the whole view filled; `pictures`: the same view with only the pictures in it.
        init?(filling: RGBABitmap, pictures: RGBABitmap, band: Int) {
            guard filling.width == pictures.width, filling.height == pictures.height else { return nil }
            let made = filling.pixels.withUnsafeBufferPointer { f in
                pictures.pixels.withUnsafeBufferPointer { p in
                    iv_detail_make(f.baseAddress, p.baseAddress, Int32(filling.width), Int32(filling.height), Int32(band))
                }
            }
            guard let made else { return nil }
            plan = made
        }

        deinit { iv_detail_free(plan) }

        /// How many of its grid's points take texture from elsewhere, and how many found nowhere to.
        var counts: (moved: Int, none: Int) {
            var moved: Int32 = 0, none: Int32 = 0
            iv_detail_counts(plan, &moved, &none)
            return (Int(moved), Int(none))
        }
    }

    /// Fills what `stitched` (made no bigger than `fillSide`) doesn't cover, as Extend does: with texture copied
    /// from the picture itself, or drawn by the generative model (which must be installed), in two passes like
    /// Extend's. `progress` returns true to cancel.
    static func fill(_ stitched: Stitched, method: ExtendMethod, prompt: String, seed: UInt64,
                     progress: (@Sendable (Double) -> Bool)? = nil) async throws -> Filling {
        let w = stitched.image.width, h = stitched.image.height
        let space = stitched.image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let whole = CGRect(x: 0, y: 0, width: w, height: h)
        guard method == .generate else {
            var canvas = RGBABitmap(width: w, height: h)
            canvas.draw(stitched.image, topLeftRect: whole, space: space, quality: .none)
            let pictures = canvas
            // (A pixel in from the pictures' own edge, where they're a little soft.)
            let known = covered(canvas, inset: 1)
            do {
                try ContentAwareFill.fill(&canvas.pixels, known: known, width: w, height: h, seed: seed, progress: progress)
            } catch ExtendError.cancelled {
                throw StitchError.cancelled
            }
            guard let image = canvas.makeImage(space: space) else { throw StitchError.failed }
            return Filling(image: image, scale: stitched.scale, origin: stitched.origin, band: 2, method: .match,
                           detail: Detail(filling: canvas, pictures: pictures, band: 2))
        }

        // First pass, at the model's own size (the short side 512): the layout of what's new.
        let n = GenerativeExtend.window
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let down = CGFloat(n) / CGFloat(min(w, h))
        let ww = max(n, Int((CGFloat(w) * down).rounded())), wh = max(n, Int((CGFloat(h) * down).rounded()))
        var canvas = RGBABitmap(width: ww, height: wh)
        canvas.draw(stitched.image, topLeftRect: CGRect(x: 0, y: 0, width: ww, height: wh), space: sRGB, quality: .high)
        var known = covered(canvas, inset: 1)
        guard known.contains(1) else { throw StitchError.failed }
        // (What isn't known is see-through until it's painted.)
        for i in 0..<(ww * wh) where known[i] == 0 { for c in 0..<4 { canvas.pixels[i * 4 + c] = 0 } }
        var start = canvas
        _ = start.pixels.withUnsafeMutableBufferPointer { px in
            known.withUnsafeBufferPointer { k in iv_content_aware_fill(px.baseAddress, k.baseAddress, nil, Int32(ww), Int32(wh), seed, nil, nil) }
        }
        start.blur(radius: GenerativeExtend.roughBlur)
        do {
            try await GenerativeExtend.paint(&canvas, known: &known, start: start, prompt: prompt, seed: seed, strength: GenerativeExtend.strength,
                                             steps: GenerativeExtend.steps, overlap: GenerativeExtend.overlap) { progress?(0.45 * $0) ?? false }
            guard let coarse = canvas.makeImage(space: sRGB) else { throw StitchError.failed }

            // Second pass, at up to twice that: detail at nearer the pictures' own scale, and a band just inside
            // their edges for them to fade into.
            let up = max(1, min(2, CGFloat(min(w, h)) / CGFloat(min(ww, wh))))
            let rw = max(n, Int((CGFloat(ww) * up).rounded())), rh = max(n, Int((CGFloat(wh) * up).rounded()))
            let fine = CGRect(x: 0, y: 0, width: rw, height: rh)
            var own = RGBABitmap(width: rw, height: rh)
            own.draw(stitched.image, topLeftRect: fine, space: sRGB, quality: .high)
            // (A few pixels, not the wide band Extend redraws inside a photo's edges: stitched pictures have long
            // edges, and redrawn that far in they showed it. They're kept as they are almost to their edges, and
            // what's new is given their texture instead.)
            let band = max(3, Int((bandFraction * CGFloat(min(rw, rh))).rounded()))
            var inner = covered(own, inset: band)
            // (Pictures too thin to have an inside keep what they have.)
            if !inner.contains(1) { inner = covered(own, inset: 1) }
            var refined = RGBABitmap(width: rw, height: rh)
            refined.draw(coarse, topLeftRect: fine, space: sRGB, quality: .high)
            refined.draw(stitched.image, topLeftRect: fine, space: sRGB, quality: .high)
            var painted = inner
            try await GenerativeExtend.paint(&refined, known: &painted, start: nil, prompt: prompt, seed: seed, strength: GenerativeExtend.refineStrength,
                                             steps: GenerativeExtend.refineSteps, overlap: GenerativeExtend.refineOverlap) { progress?(0.45 + 0.5 * $0) ?? false }

            // In the pictures' own color space, meeting them without an edge or a cast.
            guard let made = refined.makeImage(space: sRGB) else { throw StitchError.failed }
            var filled = RGBABitmap(width: rw, height: rh)
            filled.draw(made, topLeftRect: fine, space: space, quality: .none)
            var reference = RGBABitmap(width: rw, height: rh)
            reference.draw(stitched.image, topLeftRect: fine, space: space, quality: .high)
            let status = filled.pixels.withUnsafeMutableBufferPointer { out in
                reference.pixels.withUnsafeBufferPointer { ref in
                    inner.withUnsafeBufferPointer { k in iv_seam_blend(out.baseAddress, ref.baseAddress, k.baseAddress, Int32(rw), Int32(rh)) }
                }
            }
            guard Int(status) == IV_FILL_OK, let image = filled.makeImage(space: space) else { throw StitchError.failed }
            _ = progress?(1)
            return Filling(image: image, scale: stitched.scale * Double(rw) / Double(w), origin: stitched.origin, band: Double(band), method: .generate,
                           detail: Detail(filling: filled, pictures: reference, band: band))
        } catch ExtendError.cancelled {
            throw StitchError.cancelled
        }
    }

    /// 1 where `bitmap` is covered (opaque) and so is everything within `inset` pixels of it, up and down and
    /// to each side; 0 elsewhere. (Past the bitmap's own edge counts as covered: there's nothing there to meet.)
    static func covered(_ bitmap: RGBABitmap, inset: Int) -> [UInt8] {
        let w = bitmap.width, h = bitmap.height, r = max(inset, 0)
        var open = [Int32](repeating: 0, count: w * h)
        bitmap.pixels.withUnsafeBufferPointer { px in
            for i in 0..<(w * h) where px[i * 4 + 3] != 255 { open[i] = 1 }
        }
        guard r > 0 else { return open.map { $0 == 0 ? 1 : 0 } }
        // How many uncovered pixels lie within `r` along each row, then along each column of that.
        var rows = [Int32](repeating: 0, count: w * h), out = [UInt8](repeating: 0, count: w * h)
        open.withUnsafeBufferPointer { o in
            rows.withUnsafeMutableBufferPointer { sums in
                for y in 0..<h {
                    var running: Int32 = 0
                    for x in 0..<min(r, w) { running += o[y * w + x] }
                    for x in 0..<w {
                        if x + r < w { running += o[y * w + x + r] }
                        if x - r - 1 >= 0 { running -= o[y * w + x - r - 1] }
                        sums[y * w + x] = running
                    }
                }
            }
        }
        rows.withUnsafeBufferPointer { sums in
            out.withUnsafeMutableBufferPointer { result in
                for x in 0..<w {
                    var running: Int32 = 0
                    for y in 0..<min(r, h) { running += sums[y * w + x] }
                    for y in 0..<h {
                        if y + r < h { running += sums[(y + r) * w + x] }
                        if y - r - 1 >= 0 { running -= sums[(y - r - 1) * w + x] }
                        result[y * w + x] = running == 0 ? 1 : 0
                    }
                }
            }
        }
        return out
    }

    /// `stitched` with what it doesn't cover taken from `filling` (enlarged to its size, and given the pictures'
    /// own fine texture, unless `texture` is false); the pictures fade into the filling just inside their edges,
    /// which the filling was made to carry on from.
    static func filled(_ stitched: Stitched, with filling: Filling, texture: Bool = true) -> CGImage? {
        guard let detail = filling.detail else { return laid(stitched, over: filling) }
        let w = stitched.image.width, h = stitched.image.height
        let space = stitched.image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let s = stitched.scale / filling.scale
        let dx = (filling.origin.x - stitched.origin.x) * stitched.scale, dy = (filling.origin.y - stitched.origin.y) * stitched.scale
        guard let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let made = out.data else { return nil }
        let status = withPixels(of: stitched.image, space: space) { top in
            iv_detail_finish(detail.plan, top, Int32(w), Int32(h), s, dx, dy, texture ? 1 : 0, made.assumingMemoryBound(to: UInt8.self), nil, nil)
        }
        guard let status, Int(status) == IV_FILL_OK else { return laid(stitched, over: filling) }
        return out.makeImage()
    }

    /// `image`'s pixels as the engine takes them (RGBA, rows top to bottom, alpha 255 where it's covered):
    /// its own where it holds them that way, else a copy.
    private static func withPixels<T>(of image: CGImage, space: CGColorSpace, _ body: (UnsafePointer<UInt8>) -> T) -> T? {
        let w = image.width, h = image.height
        if image.bitsPerPixel == 32, image.bitsPerComponent == 8, image.bytesPerRow == w * 4, image.alphaInfo == .premultipliedLast,
           image.byteOrderInfo == .orderDefault || image.byteOrderInfo == .order32Big,
           let data = image.dataProvider?.data, CFDataGetLength(data) >= w * h * 4, let bytes = CFDataGetBytePtr(data) {
            return body(bytes)
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return body(UnsafePointer(data.assumingMemoryBound(to: UInt8.self)))
    }

    /// The same without the pictures' texture in the filling, by Core Image (for when there's no `detail`).
    private static func laid(_ stitched: Stitched, over filling: Filling) -> CGImage? {
        let top = CIImage(cgImage: stitched.image)
        let ext = top.extent
        let s = stitched.scale / filling.scale
        // (Both hang from their top left corners; Core Image counts up from the bottom.)
        let dx = (filling.origin.x - stitched.origin.x) * stitched.scale, dy = (filling.origin.y - stitched.origin.y) * stitched.scale
        let under = CIImage(cgImage: filling.image).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: dx, y: ext.height - CGFloat(filling.image.height) * s - dy))
            .cropped(to: ext)
        let band = max(1.5, filling.band * s)
        // Where the pictures show: all of them but a band inside their edges, the edge of that softened.
        let mask = EditRenderer.alphaMask(of: top).cropped(to: ext).clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: band * 0.6])
            .applyingGaussianBlur(sigma: band * 0.2)
            .cropped(to: ext)
        let result = top.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: under, kCIInputMaskImageKey: mask])
            .settingAlphaOne(in: ext)
        let space = stitched.image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ImageDecoder.ciContext.createCGImage(result, from: ext, format: .RGBA8, colorSpace: space)
    }

    /// The stitched picture as it's kept: cropped to what's covered, or with the rest filled.
    static func finished(_ stitched: Stitched, edges: StitchEdges, filling: Filling?, texture: Bool = true) -> CGImage? {
        switch edges {
        case .crop:
            guard let covered = stitched.covered, covered.width >= 2, covered.height >= 2 else { return nil }
            return stitched.image.cropping(to: covered).flatMap(opaque)
        case .fill:
            guard let filling else { return nil }
            return filled(stitched, with: filling, texture: texture)
        }
    }

    /// `image` (covered everywhere) without its alpha channel.
    private static func opaque(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
