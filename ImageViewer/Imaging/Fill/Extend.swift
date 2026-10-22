import CoreGraphics
import CoreImage
import Foundation
import UniformTypeIdentifiers

nonisolated enum ExtendError: LocalizedError {
    case cancelled
    case nothingToCopy
    case failed

    var errorDescription: String? {
        switch self {
        case .cancelled: "Extend was cancelled."
        case .nothingToCopy: "This image is too small to extend."
        case .failed: "The image couldn't be extended."
        }
    }
}

/// Swift face of the C engine in ContentAwareFill.c.
nonisolated enum ContentAwareFill {
    nonisolated private final class Reporter {
        let report: @Sendable (Double) -> Bool
        init(_ report: @escaping @Sendable (Double) -> Bool) { self.report = report }
    }

    /// Places `image` on a `width` × `height` canvas with its top-left corner at `origin` (canvas pixels,
    /// top-left origin; negative where the canvas crops it) and synthesizes every canvas pixel it doesn't cover.
    /// `avoid` (white = don't copy from here, e.g. the subject) is a mask in `image`'s pixel space.
    /// `progress` receives 0...1 and returns true to cancel.
    static func extend(_ image: CGImage, width: Int, height: Int, origin: CGPoint, avoid: CIImage?,
                       seed: UInt64, progress: (@Sendable (Double) -> Bool)? = nil) throws -> CGImage {
        guard width > 0, height > 0 else { throw ExtendError.failed }
        // Whole pixels, so the original's edge isn't a half-covered (darkened) column.
        let origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let imageRect = CGRect(x: origin.x, y: CGFloat(height) - origin.y - CGFloat(image.height),
                               width: CGFloat(image.width), height: CGFloat(image.height))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var known = [UInt8](repeating: 0, count: width * height)
        var avoidMask: [UInt8]?

        let drew = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: imageRect)
            return true
        }
        guard drew else { throw ExtendError.failed }
        let x0 = max(0, Int(origin.x.rounded())), y0 = max(0, Int(origin.y.rounded()))
        let x1 = min(width, Int(origin.x.rounded()) + image.width), y1 = min(height, Int(origin.y.rounded()) + image.height)
        if x0 < x1, y0 < y1 {
            for y in y0..<y1 { for x in x0..<x1 { known[y * width + x] = 1 } }
        }

        if let avoid, avoid.extent.width > 0, avoid.extent.height > 0 {
            // The mask scaled onto the image, placed on the canvas (Core Image is y-up; bitmap rows top-down).
            let placed = avoid
                .transformed(by: CGAffineTransform(translationX: -avoid.extent.minX, y: -avoid.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: imageRect.width / avoid.extent.width, y: imageRect.height / avoid.extent.height))
                .transformed(by: CGAffineTransform(translationX: imageRect.minX, y: imageRect.minY))
            var gray = [UInt8](repeating: 0, count: width * height)
            gray.withUnsafeMutableBytes { buf in
                ImageDecoder.ciContext.render(placed, toBitmap: buf.baseAddress!, rowBytes: width,
                                              bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .L8, colorSpace: nil)
            }
            avoidMask = gray.map { $0 > 64 ? 1 : 0 }
        }

        let reporter = progress.map(Reporter.init)
        let context = reporter.map { Unmanaged.passUnretained($0).toOpaque() }
        let callback: iv_fill_progress? = reporter == nil ? nil : { ctx, fraction in
            guard let ctx else { return 0 }
            return Unmanaged<Reporter>.fromOpaque(ctx).takeUnretainedValue().report(fraction) ? 1 : 0
        }
        let status: Int32 = rgba.withUnsafeMutableBufferPointer { pixels in
            known.withUnsafeBufferPointer { k in
                if let avoidMask {
                    return avoidMask.withUnsafeBufferPointer { a in
                        iv_content_aware_fill(pixels.baseAddress, k.baseAddress, a.baseAddress, Int32(width), Int32(height), seed, callback, context)
                    }
                }
                return iv_content_aware_fill(pixels.baseAddress, k.baseAddress, nil, Int32(width), Int32(height), seed, callback, context)
            }
        }
        withExtendedLifetime(reporter) {}
        switch Int(status) {
        case IV_FILL_OK: break
        case IV_FILL_CANCELLED: throw ExtendError.cancelled
        case IV_FILL_NO_SOURCE: throw ExtendError.nothingToCopy
        default: throw ExtendError.failed
        }

        let made = rgba.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let made else { throw ExtendError.failed }
        return made
    }
}

/// Extend fills, kept in Application Support so an edit keeps working across relaunches (with pending edits).
nonisolated enum ExtendFillStore {
    static var directory: URL {
        AppStorageLocation.support.appendingPathComponent("Extensions")
    }

    static func save(_ image: CGImage) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("heic")
        try ImageWriter.write(image, to: url, format: .heic, quality: 0.92, sourceProperties: [:], metadata: .removeAll)
        return url.path
    }

    /// Deletes fills nothing refers to any more (at launch, when only pending edits can).
    static func prune(keeping paths: Set<String>) {
        let keep = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

nonisolated enum ExtendRenderer {
    /// Longest side of the canvas the fill is synthesized at; the original stays full resolution on top.
    static let finalCanvas: CGFloat = 2048
    static let previewCanvas: CGFloat = 640
    /// The subject isn't copied into the new area (no duplicated flowers or faces) unless it fills nearly
    /// the whole frame; the engine falls back on its own if that leaves nothing to copy.
    static let avoidSubjectUpTo = 0.85

    /// Makes the fill for `edits.crop` (which reaches past the image) from the image at its current geometry:
    /// generated by the on-device model when the edits ask for that and it's installed, else content-aware.
    /// The main subject isn't copied into the new area when it's a reasonable part of the frame.
    struct Fill: @unchecked Sendable {
        let fill: CGImage
        let canvas: CGRect
        /// See ExtendFill.feather.
        var feather: Double?
        /// See ExtendFill.content.
        var content: CGRect?

        var extendFill: (_ path: String) -> ExtendFill { { ExtendFill(path: $0, canvas: canvas, feather: feather, content: content) } }
    }

    /// `draft` gets a generated fill's quick first version (the preview's quality) as soon as there is one.
    static func makeFill(_ decoded: DecodedImage, edits: EditState, maxCanvas: CGFloat = finalCanvas,
                         progress: (@Sendable (Double) -> Bool)? = nil, draft: (@Sendable (Fill) -> Void)? = nil) async throws -> Fill {
        guard let crop = edits.crop, edits.cropExtendsBeyondImage else { throw ExtendError.failed }
        if edits.effectiveExtendMethod == .generate, GenerativeModel.isInstalled {
            return try await makeGenerativeFill(decoded, edits: edits, crop: crop, maxCanvas: maxCanvas, progress: progress, draft: draft)
        }
        let geometry = try await geometryImage(decoded, edits: edits, canvas: crop, maxCanvas: maxCanvas)
        let gw = CGFloat(geometry.width), gh = CGFloat(geometry.height)
        let width = Int((crop.width * gw).rounded()), height = Int((crop.height * gh).rounded())
        let origin = CGPoint(x: -crop.minX * gw, y: -crop.minY * gh)

        // Continue the picture, not a print's border; keep the subject out of the copy sources (no stray
        // duplicated faces or limbs).
        let content = await pictureContent(decoded, edits: edits)
        let picture = PhotoBorder.picture(geometry, origin: origin, content: content)
        let avoid = await Self.subjectAvoidance(picture.image, crop: crop)
        let seed = edits.extendSeed ?? 1
        let fill = try await Task.detached(priority: .userInitiated) {
            try ContentAwareFill.extend(picture.image, width: width, height: height, origin: picture.origin, avoid: avoid, seed: seed, progress: progress)
        }.value
        return Fill(fill: fill, canvas: crop, content: content)
    }

    /// The image at its current geometry (no adjustments), scaled so that `canvas` (normalized, past 0...1)
    /// is at most `maxCanvas` pixels on its longest side.
    static func geometryImage(_ decoded: DecodedImage, edits: EditState, canvas: CGRect, maxCanvas: CGFloat) async throws -> CGImage {
        let renderer = EditRenderer.shared
        let full = renderer.makeImage(decoded, edits: edits, maxDimension: nil, stage: .geometry).extent.size
        let canvasLongest = max(canvas.width * full.width, canvas.height * full.height)
        let scale = min(1, maxCanvas / max(canvasLongest, 1))
        let sourceLongest = max(decoded.pixelSize.width, decoded.pixelSize.height)
        guard let geometry = await renderer.render(decoded, edits: edits, maxDimension: scale < 1 ? sourceLongest * scale : nil,
                                                   stage: .geometry)?.image else { throw ExtendError.failed }
        return geometry
    }

    /// The picture inside a scanned print's border, if the photo has one (normalized, in the image at its
    /// current geometry). Found on a small render, so the preview and the final fill agree.
    static func pictureContent(_ decoded: DecodedImage, edits: EditState) async -> CGRect? {
        var g = edits
        g.crop = nil
        guard let small = await EditRenderer.shared.render(decoded, edits: g, maxDimension: 600, stage: .geometry)?.image else { return nil }
        return PhotoBorder.content(of: small)
    }

    // MARK: Generated fills

    /// The generated canvas (working size) for these edits covering `crop`. One generation serves the crop
    /// tool's preview and the final fill, and the same edits and seed make the same picture again.
    static func generatedCanvas(_ decoded: DecodedImage, edits: EditState, crop: CGRect,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> GenerativeFillCache.Entry {
        let key = decoded.url.path + "|" + edits.extendSourceKey
        return try await GenerativeFillCache.shared.entry(key: key, crop: crop, progress: progress) { report in
            // The source at about twice the working size (short side 512), to draw down from.
            let shortSide = min(crop.width * decoded.pixelSize.width, crop.height * decoded.pixelSize.height)
            let longSide = max(crop.width * decoded.pixelSize.width, crop.height * decoded.pixelSize.height)
            let target = CGFloat(GenerativeExtend.window) * 2 * longSide / max(shortSide, 1)
            let geometry = try await geometryImage(decoded, edits: edits, canvas: crop, maxCanvas: target)
            let gw = CGFloat(geometry.width), gh = CGFloat(geometry.height)
            let width = Int((crop.width * gw).rounded()), height = Int((crop.height * gh).rounded())
            let origin = CGPoint(x: -crop.minX * gw, y: -crop.minY * gh)
            let seed = edits.extendSeed ?? 1
            // A scanned print's border is replaced along with the rest of the new area.
            let content = await pictureContent(decoded, edits: edits)
            let picture = PhotoBorder.picture(geometry, origin: origin, content: content)

            // The rough start: a content-aware fill at the working size that leaves the subject alone.
            let small = await VisionServices.downscaled(geometry, maxDimension: Int(max(gw, gh) / 2))
            let sw = CGFloat(small.width), sh = CGFloat(small.height)
            let smallPicture = PhotoBorder.picture(small, origin: CGPoint(x: -crop.minX * sw, y: -crop.minY * sh), content: content)
            let avoid = await Self.subjectAvoidance(smallPicture.image, crop: crop)
            let rough = try? await Task.detached(priority: .userInitiated) {
                try ContentAwareFill.extend(smallPicture.image, width: Int((crop.width * sw).rounded()), height: Int((crop.height * sh).rounded()),
                                            origin: smallPicture.origin, avoid: avoid, seed: seed)
            }.value
            if report(0.02) { throw ExtendError.cancelled }
            let setting = await settingFor(decoded, edits: edits)
            return try await GenerativeExtend.generate(picture.image, width: width, height: height, origin: picture.origin,
                                                       prompt: GenerativeExtend.prompt(edits.extendPrompt, setting: setting), seed: seed,
                                                       rough: rough) { report(0.02 + 0.98 * $0) }
        }
    }

    private static func makeGenerativeFill(_ decoded: DecodedImage, edits: EditState, crop: CGRect, maxCanvas: CGFloat,
                                           progress: (@Sendable (Double) -> Bool)?, draft: (@Sendable (Fill) -> Void)?) async throws -> Fill {
        let entry = try await generatedCanvas(decoded, edits: edits, crop: crop) { _ = progress?(0.4 * $0) }
        try Task.checkCancellation()
        let geometry = try await geometryImage(decoded, edits: edits, canvas: entry.canvas, maxCanvas: maxCanvas)
        let gw = CGFloat(geometry.width), gh = CGFloat(geometry.height)
        let width = Int((entry.canvas.width * gw).rounded()), height = Int((entry.canvas.height * gh).rounded())
        let content = await pictureContent(decoded, edits: edits)
        let picture = PhotoBorder.picture(geometry, origin: CGPoint(x: -entry.canvas.minX * gw, y: -entry.canvas.minY * gh), content: content)
        let original = picture.image, origin = picture.origin
        if let draft {
            let coarse = entry.image
            let quick = try await Task.detached(priority: .userInitiated) {
                try GenerativeExtend.finish(coarse, original: original, width: width, height: height, origin: origin)
            }.value
            draft(Fill(fill: quick, canvas: entry.canvas, content: content))
        }

        // Second pass at up to twice the working size: detail at the photo's own scale, and a band just inside
        // its extended edges for the photo to cross-fade into.
        var generated = entry.image
        var band = 0
        // (At least the working size, for the band, even when the photo is no bigger than that.)
        let refineScale = max(1, min(2, CGFloat(min(width, height)) / CGFloat(max(min(generated.width, generated.height), 1))))
        if GenerativeExtend.refines {
            // Cached like the first pass, so undo, redo and relaunching don't redo it.
            let coarse = generated
            let setting = await settingFor(decoded, edits: edits)
            let key = decoded.url.path + "|" + edits.extendSourceKey + "|refined"
            let refined = try await GenerativeFillCache.shared.entry(key: key, crop: entry.canvas, progress: { _ = progress?($0) }) { report in
                try await GenerativeExtend.refine(coarse, original: original, width: width, height: height, origin: origin,
                                                  prompt: GenerativeExtend.prompt(edits.extendPrompt, setting: setting), seed: edits.extendSeed ?? 1,
                                                  scale: refineScale) { report(0.4 + 0.55 * $0) }.image
            }
            generated = refined.image
            let s = CGFloat(refined.image.width) / CGFloat(width)
            let refinedBand = GenerativeExtend.bandWidth(photo: CGSize(width: CGFloat(original.width) * s, height: CGFloat(original.height) * s))
            band = Int((CGFloat(refinedBand) / s).rounded())
        }
        // Apple's super resolution, where it's on this Mac, enlarges the generated detail better than resampling.
        let enlargement = CGFloat(width) / CGFloat(max(generated.width, 1))
        if enlargement > 1.5, SuperResolution.modelState == .ready, SuperResolution.fits(width: generated.width, height: generated.height),
           let upscaled = try? await SuperResolution.upscale(generated, scale: min(CGFloat(SuperResolution.factor), enlargement.rounded(.up))) {
            generated = upscaled
        }
        let source = generated, edge = band
        let fill = try await Task.detached(priority: .userInitiated) {
            try GenerativeExtend.finish(source, original: original, width: width, height: height, origin: origin, band: edge)
        }.value
        _ = progress?(1)
        let feather = band > 0 ? Double(band) / Double(min(geometry.width, geometry.height)) : nil
        return Fill(fill: fill, canvas: entry.canvas, feather: feather, content: content)
    }

    /// The crop tool's preview of a generated fill: the generated canvas with the edits' adjustments, like
    /// the rest of what the tool shows.
    static func previewGenerativeFill(_ decoded: DecodedImage, edits: EditState, crop: CGRect,
                                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> (image: CGImage, canvas: CGRect, content: CGRect?) {
        let entry = try await generatedCanvas(decoded, edits: edits, crop: crop, progress: progress)
        let content = await pictureContent(decoded, edits: edits)
        let full = EditRenderer.shared.makeImage(decoded, edits: edits, maxDimension: nil, stage: .geometry).extent.size
        let scale = CGFloat(entry.image.width) / max(entry.canvas.width * full.width, 1) * full.width / max(decoded.pixelSize.width, 1)
        let image = await Task.detached(priority: .userInitiated) {
            EditRenderer.shared.adjusted(entry.image, like: decoded, edits: edits, scale: scale) ?? entry.image
        }.value
        return (image, entry.canvas, content)
    }

    /// A quick fill for the crop tool's live preview, made from what the tool shows (`base`, adjustments
    /// included) at low resolution. Returns the whole canvas (`crop`), original area included.
    static func previewFill(base: CGImage, crop: CGRect, seed: UInt64) async throws -> (image: CGImage, content: CGRect?) {
        let bw = CGFloat(base.width), bh = CGFloat(base.height)
        let scale = min(1, previewCanvas / max(crop.width * bw, crop.height * bh, 1))
        let small = scale < 1 ? await VisionServices.downscaled(base, maxDimension: Int(max(bw, bh) * scale)) : base
        let sw = CGFloat(small.width), sh = CGFloat(small.height)
        let content = PhotoBorder.content(of: small)
        let picture = PhotoBorder.picture(small, origin: CGPoint(x: -crop.minX * sw, y: -crop.minY * sh), content: content)
        let avoid = await subjectAvoidance(picture.image, crop: crop)
        let width = Int((crop.width * sw).rounded()), height = Int((crop.height * sh).rounded())
        let image = try await Task.detached(priority: .userInitiated) {
            try ContentAwareFill.extend(picture.image, width: width, height: height, origin: picture.origin, avoid: avoid, seed: seed)
        }.value
        return (image, content)
    }

    /// What the content-aware engine mustn't copy from `image`: its subject, except (for things other than
    /// people) the parts near the edges being extended, which run on out of frame (petals, branches). Bits of
    /// a person are never copied: a stray piece of shirt or hair in the background looks absurd.
    static func subjectAvoidance(_ image: CGImage, crop: CGRect) async -> CIImage? {
        guard let mask = try? await VisionServices.subjectMask(for: image) else { return nil }
        return avoidMask(fromSubject: mask, crop: crop, keepEdges: !(await VisionServices.hasFaces(image)))
    }

    /// What Generate continues when nothing's typed: the photo's setting, as Apple Intelligence describes it
    /// ("a restaurant with wooden tables, dark chairs and a light wood floor"). Made once per photo (and
    /// geometry) and shared by the crop tool's preview and the final fill. nil without Apple Intelligence.
    static func settingDescription(_ decoded: DecodedImage, edits: EditState) async -> String? {
        var g = edits
        g.extendSeed = nil
        g.extendMethod = nil
        g.extendPrompt = nil
        let source = g
        return await SettingDescriptions.shared.description(for: decoded.url.path + "|" + source.extendSourceKey) {
            guard let image = await EditRenderer.shared.render(decoded, edits: source, maxDimension: 1024, stage: .geometry)?.image
            else { return nil }
            let labels = ImageDescriber.support == .vision ? [] : await VisionServices.classify(image)
            return await ImageDescriber.describeSetting(image, labels: labels)
        }
    }

    /// The setting, unless the user typed what they want.
    private static func settingFor(_ decoded: DecodedImage, edits: EditState) async -> String? {
        let typed = (edits.extendPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? await settingDescription(decoded, edits: edits) : nil
    }

    /// The subject mask as an "avoid" mask for extending through `crop`: the subject's body isn't copied, but
    /// with `keepEdges` its parts near the edges being extended are, since those are what run out of frame.
    static func avoidMask(fromSubject mask: CIImage, crop: CGRect, keepEdges: Bool = true) -> CIImage? {
        let ext = mask.extent
        guard ext.width > 0, ext.height > 0, coverage(of: mask) < avoidSubjectUpTo else { return nil }
        guard keepEdges else { return mask }
        let band = 0.15 * min(ext.width, ext.height)
        var inner = ext
        if crop.minX < -0.001 { inner.origin.x += band; inner.size.width -= band }
        if crop.maxX > 1.001 { inner.size.width -= band }
        if crop.maxY > 1.001 { inner.origin.y += band; inner.size.height -= band }   // bottom (Core Image is y-up)
        if crop.minY < -0.001 { inner.size.height -= band }                           // top
        guard inner.width > 0, inner.height > 0 else { return nil }
        return mask.cropped(to: inner).composited(over: CIImage(color: .black).cropped(to: ext))
    }

    /// Fraction of the mask that's white.
    static func coverage(of mask: CIImage) -> Double {
        let avg = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: mask.extent)])
        var px = [Float](repeating: 0, count: 4)
        ImageDecoder.ciContext.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(px[0])
    }
}

/// Setting descriptions by photo, so each is asked for once (concurrent askers share the answer).
actor SettingDescriptions {
    static let shared = SettingDescriptions()
    private var done: [String: String] = [:]   // "" when there's none
    private var running: [String: Task<String, Never>] = [:]

    func description(for key: String, make: @escaping @Sendable () async -> String?) async -> String? {
        if let known = done[key] { return known.isEmpty ? nil : known }
        let task = running[key] ?? Task { await make() ?? "" }
        running[key] = task
        let value = await task.value
        done[key] = value
        running[key] = nil
        return value.isEmpty ? nil : value
    }
}

/// A scanned print's margin: an even white (or black) border around the picture. Extend continues the
/// picture inside it, and the border goes, instead of treating the print as an object in a scene.
nonisolated enum PhotoBorder {
    /// The picture inside the border (normalized, top-left origin), or nil when the image doesn't have one
    /// on at least three sides (one even edge is more likely a sky or a wall).
    static func content(of image: CGImage) -> CGRect? {
        let scale = min(1, 600 / Double(max(image.width, image.height)))
        let w = max(16, Int(Double(image.width) * scale)), h = max(16, Int(Double(image.height) * scale))
        var bitmap = RGBABitmap(width: w, height: h)
        bitmap.draw(image, topLeftRect: CGRect(x: 0, y: 0, width: w, height: h), space: CGColorSpace(name: CGColorSpace.sRGB)!, quality: .high)
        let px = bitmap.pixels
        func luma(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
        }
        /// Whether a row or column is margin: nearly all one light (paper) or dark (scanner lid) tone.
        /// A few darker pixels (a date stamp, dust) are fine.
        func marginTone(_ values: [Double]) -> Double? {
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            guard median > 0.78 || median < 0.14 else { return nil }
            let even = values.filter { abs($0 - median) < 0.08 }.count
            return Double(even) >= 0.9 * Double(values.count) ? median : nil
        }
        /// How many lines in from one side are margin (lines: 0 = the outermost). A print's margin ends at
        /// the picture's straight edge: the first lines past it differ from the paper nearly all along (a
        /// document's margin ends at scattered text instead, and isn't a border).
        func thickness(_ count: Int, _ line: (Int) -> [Double]) -> Int {
            let depth = marginDepth(count, line)
            guard depth > 0, depth + 2 < count else { return 0 }
            let margin = line(depth - 1).sorted()
            let paper = margin[margin.count / 2]
            let inside = line(depth + 1)
            let differing = inside.filter { abs($0 - paper) > 0.12 }.count
            return Double(differing) >= 0.6 * Double(inside.count) ? depth : 0
        }
        func marginDepth(_ count: Int, _ line: (Int) -> [Double]) -> Int {
            let limit = count * 15 / 100
            var depth = 0, tone: Double?
            for i in 0..<limit {
                guard let t = marginTone(line(i)) else {
                    if depth == 0, i < 4 { continue }   // a scanner's dark edge, or resampling at the image's edge
                    break
                }
                if i >= 2 {   // (the outermost lines' tone is off from resampling)
                    if let tone, abs(t - tone) > 0.08 { break }
                    tone = tone ?? t
                }
                depth = i + 1
            }
            return depth
        }
        let top = thickness(h) { y in (0..<w).map { luma($0, y) } }
        let bottom = thickness(h) { y in (0..<w).map { luma($0, h - 1 - y) } }
        let left = thickness(w) { x in (0..<h).map { luma(x, $0) } }
        let right = thickness(w) { x in (0..<h).map { luma(w - 1 - x, $0) } }
        let minimum = { (n: Int) in max(3, n * 12 / 1000) }
        let sides = [top >= minimum(h), bottom >= minimum(h), left >= minimum(w), right >= minimum(w)]
        guard sides.filter({ $0 }).count >= 3 else { return nil }
        // Past the margin, and the faint line where paper meets picture.
        func inset(_ depth: Int, _ ok: Bool, _ n: Int) -> Int { ok ? depth + 1 + n / 250 : 0 }
        let x0 = inset(left, sides[2], w), x1 = w - inset(right, sides[3], w)
        let y0 = inset(top, sides[0], h), y1 = h - inset(bottom, sides[1], h)
        guard x1 - x0 > w / 3, y1 - y0 > h / 3 else { return nil }
        return CGRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h), width: Double(x1 - x0) / Double(w), height: Double(y1 - y0) / Double(h))
    }

    /// `image` (at `origin` on a canvas) cut down to its picture, and where that sits on the canvas.
    static func picture(_ image: CGImage, origin: CGPoint, content: CGRect?) -> (image: CGImage, origin: CGPoint) {
        guard let content else { return (image, origin) }
        let r = CGRect(x: content.minX * CGFloat(image.width), y: content.minY * CGFloat(image.height),
                       width: content.width * CGFloat(image.width), height: content.height * CGFloat(image.height)).integral
        guard let cut = image.cropping(to: r) else { return (image, origin) }
        return (cut, CGPoint(x: origin.x + r.minX, y: origin.y + r.minY))
    }
}
