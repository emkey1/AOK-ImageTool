import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO

/// How Remove Objects fills what's removed.
nonisolated enum RemovalMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// LaMa, a model made for this: it paints in what was behind the object (a one-time download).
    case erase
    /// Texture copied from the photo itself, like Extend's Match Photo (always available).
    case match
    /// Stable Diffusion paints what's described in place of what's marked (replacing rather than removing: on
    /// its own it paints a new object into the gap).
    case generate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .erase: "Erase"
        case .match: "Match Photo"
        case .generate: "Generate"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .erase: RemovalModel.isInstalled
        case .match: true
        case .generate: GenerativeModel.isInstalled
        }
    }
}

nonisolated enum RemovalError: LocalizedError {
    case nothingMarked, noDescription, cancelled, failed

    var errorDescription: String? {
        switch self {
        case .nothingMarked: "Nothing is marked to remove."
        case .noDescription: "Describe what Generate should put there, or choose Erase to just remove it."
        case .cancelled: "Removing was cancelled."
        case .failed: "That couldn't be removed."
        }
    }
}

/// Remove Objects' Erase model: Big LaMa (Apache-2.0, github.com/advimman/lama), converted to Core ML by
/// scripts/convert-removal-model.sh and installed per user like the other models. It looks at 800 × 800 pixels
/// and a mask, and paints the masked area in from what's around it.
nonisolated enum RemovalModel {
    static let displayName = "LaMa"
    static let side = 800
    static let modelName = "LaMa.mlmodelc"

    enum Failure: LocalizedError {
        case missingModel, badOutput

        var errorDescription: String? {
            switch self {
            case .missingModel: "The object removal model isn't installed."
            case .badOutput: "The object removal model returned an unexpected result."
            }
        }
    }

    static var directory: URL {
        AppStorageLocation.models.appendingPathComponent("Remove")
    }

    static var isInstalled: Bool {
        GenerativeModel.isSupported && FileManager.default.fileExists(atPath: directory.appendingPathComponent(modelName).path)
    }

    /// Installs a converted model: LaMa.mlmodelc itself or a folder holding it.
    static func install(from source: URL) throws {
        try InstalledModel.install(modelName, from: source, into: directory) { unload() }
    }

    static func remove() throws {
        unload()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static var sizeOnDisk: Int64 { InstalledModel.size(of: directory) }

    // MARK: Model (loaded on first use, released after a few idle minutes)

    private static let queue = DispatchQueue(label: "RemovalModel", qos: .userInitiated)
    nonisolated(unsafe) private static var model: MLModel?    // queue only
    nonisolated(unsafe) private static var jobs = 0           // queue only

    private static func unload() {
        queue.async {
            model = nil
            jobs += 1
        }
    }

    /// `image` (`side` × `side`, drawn in `space`) with the pixels `mask` marks (`side` × `side` bytes, rows
    /// top-down, nonzero = fill) painted in.
    static func inpaint(_ image: CGImage, mask: [UInt8], space: CGColorSpace) async throws -> CGImage {
        guard isInstalled else { throw Failure.missingModel }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if model == nil {
                        let config = MLModelConfiguration()
                        // (Full precision on the GPU: its Fourier convolutions overflow in half precision.)
                        config.computeUnits = .cpuAndGPU
                        model = try MLModel(contentsOf: directory.appendingPathComponent(modelName), configuration: config)
                    }
                    let input = try MLDictionaryFeatureProvider(dictionary: [
                        "image": MLFeatureValue(pixelBuffer: try pixelBuffer(image, space: space)),
                        "mask": MLFeatureValue(pixelBuffer: try maskBuffer(mask)),
                    ])
                    let output = try model!.prediction(from: input)
                    guard let buffer = output.featureValue(for: "output")?.imageBufferValue else { throw Failure.badOutput }
                    continuation.resume(returning: try picture(buffer, space: space))
                } catch {
                    continuation.resume(throwing: error)
                }
                jobs += 1
                let job = jobs
                queue.asyncAfter(deadline: .now() + 180) { if jobs == job { model = nil } }
            }
        }
    }

    private static func newBuffer(_ format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, side, side, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure.badOutput }
        return buffer
    }

    private static func pixelBuffer(_ image: CGImage, space: CGColorSpace) throws -> CVPixelBuffer {
        let buffer = try newBuffer(kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure.badOutput }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }

    private static func maskBuffer(_ mask: [UInt8]) throws -> CVPixelBuffer {
        let buffer = try newBuffer(kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.badOutput }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        mask.withUnsafeBufferPointer { m in
            for y in 0..<side {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<side { row[x] = m[y * side + x] != 0 ? 255 : 0 }
            }
        }
        return buffer
    }

    /// The model's output as a picture in `space` (copied out: Core ML reuses its buffers).
    private static func picture(_ buffer: CVPixelBuffer, space: CGColorSpace) throws -> CGImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let order: CGBitmapInfo
        switch format {
        case kCVPixelFormatType_32BGRA: order = .byteOrder32Little
        case kCVPixelFormatType_32ARGB: order = .byteOrder32Big
        default: throw Failure.badOutput
        }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.badOutput }
        let data = Data(bytes: base, count: rowBytes * h)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | order.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw Failure.badOutput }
        return image
    }
}

/// Remove Objects' patches, kept in Application Support so an edit keeps working across relaunches (with
/// pending edits).
nonisolated enum RemovalStore {
    static var directory: URL {
        AppStorageLocation.support.appendingPathComponent("Removals")
    }

    static func save(_ image: CGImage) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try ImageWriter.write(image, to: url, format: .png, quality: 1, sourceProperties: [:], metadata: .removeAll)
        return url.path
    }

    /// Deletes patches nothing refers to any more (at launch, when only pending edits can).
    static func prune(keeping paths: Set<String>) {
        let keep = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Removes an object from a photo: the area around it is cut out at full resolution (with enough of its
/// surroundings to continue), filled, and what changed is kept as a patch that fades out just past it.
nonisolated enum ObjectRemover {
    /// The area worked on is at least this big (when the image is), so small objects are removed at full
    /// resolution with plenty around them; LaMa looks at it at this size.
    static let minRegion: CGFloat = 800
    /// Match Photo works on bigger areas at this size, then enlarges the fill.
    static let matchMaxSide = 2048

    /// Removes what `mask` marks (white = remove; Core Image, the image's pixel size, origin at 0) from
    /// `decoded` as the `earlier` removals left it. The marked area, grown by `grow` pixels, is filled with
    /// `method` (Generate paints `prompt` there); the patch that covers it is saved in `RemovalStore`.
    /// `progress` gets 0...1 and returns true to cancel.
    @concurrent
    static func remove(_ decoded: DecodedImage, after earlier: [Removal], mask: CIImage, grow: CGFloat, method: RemovalMethod,
                       seed: UInt64, prompt: String? = nil, progress: (@Sendable (Double) -> Bool)? = nil) async throws -> Removal {
        let text = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if method == .generate, text.isEmpty { throw RemovalError.noDescription }
        let renderer = EditRenderer.shared
        var e = EditState()
        e.removals = earlier.isEmpty ? nil : earlier
        let source = renderer.makeImage(decoded, edits: e, maxDimension: nil, stage: .source)
        let full = source.extent
        guard let marked = VisionServices.maskBounds(mask, imageSize: full.size) else { throw RemovalError.nothingMarked }
        let grow = max(1, grow.rounded())
        let feather = max(1.5, (grow / 2).rounded())
        let grown = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow])
        // The patch: everything the grown mark covers, and its fade.
        let reach = grow + 3 * feather + 2
        let patchRect = marked.insetBy(dx: -reach, dy: -reach).intersection(full).integral
        let region = Self.region(around: patchRect, in: full.size)
        let w = Int(region.width), h = Int(region.height)
        guard w > 8, h > 8 else { throw RemovalError.nothingMarked }
        // (8-bit buffers can't use an extended-range space, such as an HDR photo's.)
        let space = CGColorSpaceCreateCopyWithStandardRange(renderer.outputColorSpace(for: decoded))

        // The area and what to fill in it (1), rows top-down.
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        renderer.context.render(source, toBitmap: &pixels, rowBytes: w * 4, bounds: region, format: .RGBA8, colorSpace: space)
        var hole = [UInt8](repeating: 0, count: w * h)
        renderer.context.render(grown, toBitmap: &hole, rowBytes: w, bounds: region, format: .L8, colorSpace: nil)
        hole = hole.map { $0 > 127 ? 1 : 0 }
        guard hole.contains(1) else { throw RemovalError.nothingMarked }

        let filled: [UInt8]
        do {
            switch method {
            case .erase:
                filled = try await erase(pixels, hole: hole, width: w, height: h, space: space)
            case .match:
                filled = try match(pixels, hole: hole, width: w, height: h, seed: seed, space: space, progress: progress)
            case .generate:
                let start = RemovalModel.isInstalled
                    ? try await erase(pixels, hole: hole, width: w, height: h, space: space)
                    : try match(pixels, hole: hole, width: w, height: h, seed: seed, space: space, progress: { progress?(0.1 * $0) ?? false })
                filled = try await generate(pixels, start: start, hole: hole, width: w, height: h, prompt: text, seed: seed, space: space,
                                            progress: { progress?(0.1 + 0.9 * $0) ?? false })
            }
        } catch ExtendError.cancelled {
            throw RemovalError.cancelled
        } catch StableDiffusionInpainter.Failure.cancelled {
            throw RemovalError.cancelled
        } catch ExtendError.nothingToCopy {
            throw RemovalError.failed
        }

        // The fill where the mark is and the photo around it, fading from one to the other just past the mark.
        guard let fillImage = image(filled, width: w, height: h, space: space) else { throw RemovalError.failed }
        let fill = CIImage(cgImage: fillImage).transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
        let patch = fill
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: grown])
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: patchRect),
                kCIInputMaskImageKey: grown.clampedToExtent().applyingGaussianBlur(sigma: feather),
            ])
            .cropped(to: patchRect)
        guard let picture = renderer.context.createCGImage(patch, from: patchRect, format: .RGBA8, colorSpace: space) else {
            throw RemovalError.failed
        }
        let path = try RemovalStore.save(picture)
        let rect = CGRect(x: patchRect.minX / full.width, y: 1 - patchRect.maxY / full.height,
                          width: patchRect.width / full.width, height: patchRect.height / full.height)
        return Removal(path: path, rect: rect)
    }

    /// The area worked on (Core Image pixels): `marked` with room around it, square where the image allows,
    /// at least `minRegion` on a side, inside the image.
    static func region(around marked: CGRect, in size: CGSize) -> CGRect {
        let long = max(marked.width, marked.height)
        let pad = max(0.4 * long, 0.03 * max(size.width, size.height), 48)
        let side = max(long + 2 * pad, minRegion)
        let w = min(side, size.width), h = min(side, size.height)
        let x = min(max(marked.midX - w / 2, 0), size.width - w)
        let y = min(max(marked.midY - h / 2, 0), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h).integral.intersection(CGRect(origin: .zero, size: size))
    }

    /// A mask drawn over the image as `e` turns and flips it, in the image's own pixel space (`size`): the turn
    /// undone, then the flips (the pipeline flips first, then turns).
    static func sourceMask(_ mask: CIImage, shownWith e: EditState, size: CGSize) -> CIImage {
        func origin(_ m: CIImage) -> CIImage { m.transformed(by: CGAffineTransform(translationX: -m.extent.minX, y: -m.extent.minY)) }
        var m = origin(mask)
        switch ((e.quarterTurns % 4) + 4) % 4 {
        case 1: m = origin(m.oriented(.left))
        case 2: m = origin(m.oriented(.down))
        case 3: m = origin(m.oriented(.right))
        default: break
        }
        if e.flipVertical { m = origin(m.oriented(.downMirrored)) }
        if e.flipHorizontal { m = origin(m.oriented(.upMirrored)) }
        guard m.extent.width > 0, m.extent.height > 0 else { return m }
        return m.transformed(by: CGAffineTransform(scaleX: size.width / m.extent.width, y: size.height / m.extent.height))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: Fills (all `width` × `height` RGBA, rows top-down; `hole` 1 = fill)

    /// LaMa, at its 800 × 800: the area scaled to fit, the rest of the square its mirror image.
    private static func erase(_ pixels: [UInt8], hole: [UInt8], width w: Int, height h: Int, space: CGColorSpace) async throws -> [UInt8] {
        let n = RemovalModel.side
        let scale = CGFloat(n) / CGFloat(max(w, h))
        let sw = min(n, max(1, Int((CGFloat(w) * scale).rounded()))), sh = min(n, max(1, Int((CGFloat(h) * scale).rounded())))
        guard let picture = image(pixels, width: w, height: h, space: space) else { throw RemovalError.failed }
        var square = RGBABitmap(width: n, height: n)
        square.draw(picture, topLeftRect: CGRect(x: 0, y: 0, width: sw, height: sh), space: space, quality: .high)
        square.mirror(beyondWidth: sw, height: sh)
        let small = scaledMask(hole, width: w, height: h, to: sw, sh)
        var mask = [UInt8](repeating: 0, count: n * n)
        for y in 0..<sh { mask.replaceSubrange((y * n)..<(y * n + sw), with: small[(y * sw)..<((y + 1) * sw)]) }
        guard let input = square.makeImage(space: space) else { throw RemovalError.failed }
        let output = try await RemovalModel.inpaint(input, mask: mask, space: space)
        guard let painted = output.cropping(to: CGRect(x: 0, y: 0, width: sw, height: sh)) else { throw RemovalError.failed }
        var result = RGBABitmap(width: w, height: h)
        result.draw(painted, topLeftRect: CGRect(x: 0, y: 0, width: w, height: h), space: space, quality: .high)
        return result.pixels
    }

    /// The photo's own texture (the C engine), at most `matchMaxSide` on a side.
    private static func match(_ pixels: [UInt8], hole: [UInt8], width w: Int, height h: Int, seed: UInt64, space: CGColorSpace,
                              progress: (@Sendable (Double) -> Bool)?) throws -> [UInt8] {
        let longest = max(w, h)
        guard longest > matchMaxSide else {
            var rgba = pixels
            try ContentAwareFill.fill(&rgba, known: hole.map { $0 == 0 ? 1 : 0 }, width: w, height: h, seed: seed, progress: progress)
            return rgba
        }
        let scale = CGFloat(matchMaxSide) / CGFloat(longest)
        let sw = max(1, Int((CGFloat(w) * scale).rounded())), sh = max(1, Int((CGFloat(h) * scale).rounded()))
        guard let picture = image(pixels, width: w, height: h, space: space) else { throw RemovalError.failed }
        var small = RGBABitmap(width: sw, height: sh)
        small.draw(picture, topLeftRect: CGRect(x: 0, y: 0, width: sw, height: sh), space: space, quality: .high)
        let known = scaledMask(hole, width: w, height: h, to: sw, sh).map { $0 == 0 ? UInt8(1) : 0 }
        try ContentAwareFill.fill(&small.pixels, known: known, width: sw, height: sh, seed: seed, progress: progress)
        guard let made = small.makeImage(space: space) else { throw RemovalError.failed }
        var result = RGBABitmap(width: w, height: h)
        result.draw(made, topLeftRect: CGRect(x: 0, y: 0, width: w, height: h), space: space, quality: .high)
        return result.pixels
    }

    /// Stable Diffusion painting `prompt` at its working size (short side 512), as Extend's Generate does: from
    /// the area emptied first (blurred, so only its colors carry over), and for a big area a second, finer pass
    /// that keeps the first one's layout.
    private static func generate(_ pixels: [UInt8], start: [UInt8], hole: [UInt8], width w: Int, height h: Int, prompt: String,
                                 seed: UInt64, space: CGColorSpace, progress: (@Sendable (Double) -> Bool)?) async throws -> [UInt8] {
        let n = GenerativeExtend.window
        let text = GenerativeExtend.prompt(prompt)
        guard let photo = image(pixels, width: w, height: h, space: space),
              let rough = image(start, width: w, height: h, space: space) else { throw RemovalError.failed }
        let fine = min(w, h) > 900
        func pass(_ scale: CGFloat, base: CGImage, start: CGImage?, strength: Float, steps: Int, overlap: Int,
                  report: (@Sendable (Double) -> Bool)?) async throws -> CGImage {
            let cw = max(n, Int((CGFloat(w) * scale).rounded())), ch = max(n, Int((CGFloat(h) * scale).rounded()))
            let rect = CGRect(x: 0, y: 0, width: cw, height: ch)
            var canvas = RGBABitmap(width: cw, height: ch)
            canvas.draw(photo, topLeftRect: rect, space: space, quality: .high)
            var known = scaledMask(hole, width: w, height: h, to: cw, ch).map { $0 == 0 ? UInt8(1) : 0 }
            // Inside the mark, what to start from.
            var under = RGBABitmap(width: cw, height: ch)
            under.draw(base, topLeftRect: rect, space: space, quality: .high)
            for i in 0..<(cw * ch) where known[i] == 0 { for c in 0..<4 { canvas.pixels[i * 4 + c] = under.pixels[i * 4 + c] } }
            var startBitmap: RGBABitmap?
            if let start {
                var s = RGBABitmap(width: cw, height: ch)
                s.draw(start, topLeftRect: rect, space: space, quality: .high)
                s.blur(radius: GenerativeExtend.roughBlur)
                startBitmap = s
            }
            try await GenerativeExtend.paint(&canvas, known: &known, start: startBitmap, prompt: text, seed: seed, strength: strength,
                                             steps: steps, overlap: overlap, progress: report)
            guard let made = canvas.makeImage(space: space) else { throw RemovalError.failed }
            return made
        }
        var made = try await pass(CGFloat(n) / CGFloat(min(w, h)), base: rough, start: rough, strength: GenerativeExtend.strength,
                                  steps: GenerativeExtend.steps, overlap: GenerativeExtend.overlap) { progress?((fine ? 0.6 : 1) * $0) ?? false }
        if fine {
            made = try await pass(min(1, 1024 / CGFloat(min(w, h))), base: made, start: nil, strength: GenerativeExtend.refineStrength,
                                  steps: GenerativeExtend.refineSteps, overlap: GenerativeExtend.refineOverlap) { progress?(0.6 + 0.4 * $0) ?? false }
        }
        var result = RGBABitmap(width: w, height: h)
        result.draw(made, topLeftRect: CGRect(x: 0, y: 0, width: w, height: h), space: space, quality: .high)
        return result.pixels
    }

    // MARK: Helpers

    private static func image(_ pixels: [UInt8], width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        var bitmap = RGBABitmap(width: width, height: height)
        bitmap.pixels = pixels
        return bitmap.makeImage(space: space)
    }

    /// `mask` (1 = marked) at another size; a pixel the mark touches at all counts as marked.
    private static func scaledMask(_ mask: [UInt8], width w: Int, height h: Int, to sw: Int, _ sh: Int) -> [UInt8] {
        if sw == w, sh == h { return mask }
        var bytes = mask.map { $0 != 0 ? UInt8(255) : 0 }
        let gray = CGColorSpaceCreateDeviceGray()
        let source = bytes.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: gray,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
        var out = [UInt8](repeating: 0, count: sw * sh)
        guard let source else { return out }
        out.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw, space: gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        }
        return out.map { $0 > 24 ? 1 : 0 }
    }
}

nonisolated extension RGBABitmap {
    /// Fills everything right of `width` and below `height` with the picture there, mirrored (so a model sees
    /// surroundings that continue rather than an edge).
    mutating func mirror(beyondWidth cw: Int, height ch: Int) {
        guard cw < width || ch < height, cw > 0, ch > 0 else { return }
        func reflect(_ i: Int, _ n: Int) -> Int {
            let period = 2 * n, m = i % period
            return m < n ? m : period - 1 - m
        }
        let w = width
        pixels.withUnsafeMutableBufferPointer { px in
            for y in 0..<height {
                let sy = reflect(y, ch)
                for x in 0..<w where x >= cw || y >= ch {
                    let s = (sy * w + reflect(x, cw)) * 4, d = (y * w + x) * 4
                    px[d] = px[s]; px[d + 1] = px[s + 1]; px[d + 2] = px[s + 2]; px[d + 3] = px[s + 3]
                }
            }
        }
    }
}
