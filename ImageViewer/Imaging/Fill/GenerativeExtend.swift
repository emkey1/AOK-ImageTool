import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// Extend's generative fill model (Stable Diffusion 1.5 Inpainting for Core ML), installed per user.
nonisolated enum GenerativeModel {
    static let displayName = "Stable Diffusion 1.5 Inpainting"

    enum InstallError: LocalizedError {
        case notAModel

        var errorDescription: String? {
            "That folder doesn't contain a converted inpainting model (TextEncoder, Unet, VAEEncoder and VAEDecoder .mlmodelc, vocab.json and merges.txt)."
        }
    }

    static var directory: URL {
        AppStorageLocation.models.appendingPathComponent("StableDiffusionInpainting")
    }

    /// Apple silicon only: on an Intel Mac one fill would take many minutes.
    static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    static var isInstalled: Bool { isSupported && StableDiffusionInpainter.isComplete(directory) }

    /// Copies a converted model into place: a folder holding the model files, or the converter's output
    /// folder (which has them in "Resources").
    static func install(from folder: URL) throws {
        let source = StableDiffusionInpainter.isComplete(folder) ? folder : folder.appendingPathComponent("Resources")
        guard StableDiffusionInpainter.isComplete(source) else { throw InstallError.notAModel }
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".installing-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            // Same volume: APFS clones these instantly instead of copying 2 GB.
            for item in StableDiffusionInpainter.modelFiles {
                try fm.copyItem(at: source.appendingPathComponent(item), to: staging.appendingPathComponent(item))
            }
            GenerativeEngine.shared.unload()
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            try fm.moveItem(at: staging, to: directory)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func remove() throws {
        GenerativeEngine.shared.unload()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static var sizeOnDisk: Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// The loaded model, shared by every window and run one job at a time; released after a few idle minutes
/// (it holds about 2.5 GB).
nonisolated final class GenerativeEngine: @unchecked Sendable {
    static let shared = GenerativeEngine(directory: GenerativeModel.directory)
    static let idleUnload: TimeInterval = 180

    private let directory: URL
    private let queue = DispatchQueue(label: "GenerativeEngine", qos: .userInitiated)
    private var inpainter: StableDiffusionInpainter?   // queue only
    private var jobCount = 0                            // queue only

    init(directory: URL) { self.directory = directory }

    func run<T: Sendable>(_ body: @escaping @Sendable (StableDiffusionInpainter) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.inpainter == nil { self.inpainter = try StableDiffusionInpainter(directory: self.directory) }
                    continuation.resume(returning: try body(self.inpainter!))
                } catch {
                    continuation.resume(throwing: error)
                }
                self.jobCount += 1
                let job = self.jobCount
                self.queue.asyncAfter(deadline: .now() + Self.idleUnload) {
                    if self.jobCount == job { self.inpainter = nil }
                }
            }
        }
    }

    func unload() {
        queue.async {
            self.inpainter = nil
            self.jobCount += 1
        }
    }
}

/// Extend with generated content: the canvas is worked on at Stable Diffusion's size (short side 512),
/// in overlapping 512 × 512 windows along the long side, each continuing what's known so far; the result
/// is then enlarged to the final canvas and blended into the original's edges.
nonisolated enum GenerativeExtend {
    static let window = StableDiffusionInpainter.size
    static let overlap = 160
    static let steps = 20
    /// How much the model redraws the rough start (1 = everything, from pure noise).
    nonisolated(unsafe) static var strength: Float = 0.9
    nonisolated(unsafe) static var guidance: Float = 7.5
    /// Blur applied to the rough start, so only its layout and colors carry over.
    nonisolated(unsafe) static var roughBlur = 12
    enum RoughStart: String { case content, smooth, mix }
    /// What the first pass starts from: a content-aware fill (copied texture), the photo's edge colors
    /// carried smoothly outward, or half of each.
    nonisolated(unsafe) static var roughStart = RoughStart.content
    /// Skips the second pass (for comparing).
    nonisolated(unsafe) static var refines = true
    /// The second pass redraws texture at a finer scale but keeps the first pass's layout.
    nonisolated(unsafe) static var refineStrength: Float = 0.3
    /// Of which it runs `refineStrength` × this many (DPM-Solver++ needs few at low strength).
    nonisolated(unsafe) static var refineSteps = 14
    static let refineOverlap = 128
    /// The band just inside the photo's extended edges that the second pass redraws and the photo then
    /// cross-fades into, as a fraction of the photo's shorter side.
    nonisolated(unsafe) static var bandFraction: CGFloat = 0.04
    nonisolated(unsafe) static var negativePrompt = "frame, border, edge, margin, vignette, text, letters, caption, watermark, signature, logo, "
        + "blurry, low quality, jpeg artifacts, distorted, deformed, collage, split image, panel, grid, duplicate"

    /// What to ask for: the user's words, else the photo's setting as Apple Intelligence described it.
    /// (Never the subject: naming it makes the model paint more of it beside the original.)
    static func prompt(_ text: String?, setting: String? = nil) -> String {
        let typed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = typed.isEmpty ? (setting ?? "") : typed
        return scene.isEmpty ? "a high quality photo" : "a high quality photo of \(scene)"
    }

    /// Generates whatever `image` (top-left corner at `origin` on a `width` × `height` canvas, canvas
    /// pixels) doesn't cover. Returns the whole canvas at the working size, sRGB.
    /// `rough` is an optional quick fill of the whole canvas to start from (else one is made here).
    static func generate(_ image: CGImage, width: Int, height: Int, origin: CGPoint, prompt: String, seed: UInt64,
                         rough: CGImage? = nil, engine: GenerativeEngine = .shared,
                         progress: (@Sendable (Double) -> Bool)? = nil) async throws -> CGImage {
        let n = window
        guard width > 0, height > 0 else { throw ExtendError.failed }
        let scale = CGFloat(n) / CGFloat(min(width, height))
        let ww = max(n, Int((CGFloat(width) * scale).rounded())), wh = max(n, Int((CGFloat(height) * scale).rounded()))
        let rect = CGRect(x: origin.x * scale, y: origin.y * scale,
                          width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var canvas = RGBABitmap(width: ww, height: wh)
        canvas.draw(image, topLeftRect: rect, space: sRGB, quality: .high)
        // Known: pixels the picture covers completely (its resampled edge row counts as new).
        var known = [UInt8](repeating: 0, count: ww * wh)
        let kx0 = max(0, Int(rect.minX.rounded(.up)) + 1), kx1 = min(ww, Int(rect.maxX.rounded(.down)) - 1)
        let ky0 = max(0, Int(rect.minY.rounded(.up)) + 1), ky1 = min(wh, Int(rect.maxY.rounded(.down)) - 1)
        if kx0 < kx1, ky0 < ky1 { for y in ky0..<ky1 { for x in kx0..<kx1 { known[y * ww + x] = 1 } } }

        // The rough start: a content-aware fill (copied from the picture itself), and/or the edge colors
        // carried outward (a membrane solve from black), blurred.
        var start = canvas
        if roughStart != .smooth {
            if let rough {
                start.draw(rough, topLeftRect: CGRect(x: 0, y: 0, width: ww, height: wh), space: sRGB, quality: .high)
            } else {
                _ = start.pixels.withUnsafeMutableBufferPointer { px in
                    known.withUnsafeBufferPointer { k in iv_content_aware_fill(px.baseAddress, k.baseAddress, nil, Int32(ww), Int32(wh), seed, nil, nil) }
                }
            }
        }
        if roughStart != .content {
            var smooth = RGBABitmap(width: ww, height: wh)
            _ = smooth.pixels.withUnsafeMutableBufferPointer { out in
                canvas.pixels.withUnsafeBufferPointer { ref in
                    known.withUnsafeBufferPointer { k in iv_seam_blend(out.baseAddress, ref.baseAddress, k.baseAddress, Int32(ww), Int32(wh)) }
                }
            }
            if roughStart == .smooth {
                start = smooth
            } else {
                for i in 0..<start.pixels.count { start.pixels[i] = UInt8((Int(start.pixels[i]) + Int(smooth.pixels[i])) / 2) }
            }
        }
        start.blur(radius: roughBlur)

        try await paint(&canvas, known: &known, start: start, prompt: prompt, seed: seed, strength: strength, steps: steps,
                        overlap: overlap, engine: engine, progress: progress)
        guard let result = canvas.makeImage(space: sRGB) else { throw ExtendError.failed }
        return result
    }

    /// Second pass: redraws the generated area, and a band just inside the photo's extended edges, at
    /// `scale` × the working size, starting from the first pass (`coarse`: the whole canvas at the working
    /// size). Each 512 × 512 window sees the original nearby at that size, so the new area gets detail at
    /// the original's scale instead of being an enlargement. Returns the refined canvas and the band's width
    /// in its pixels.
    static func refine(_ coarse: CGImage, original image: CGImage, width: Int, height: Int, origin: CGPoint,
                       prompt: String, seed: UInt64, scale: CGFloat, engine: GenerativeEngine = .shared,
                       progress: (@Sendable (Double) -> Bool)? = nil) async throws -> (image: CGImage, band: Int) {
        let n = window
        let rw = max(n, Int((CGFloat(coarse.width) * scale).rounded())), rh = max(n, Int((CGFloat(coarse.height) * scale).rounded()))
        let s = CGFloat(rw) / CGFloat(width)
        let rect = CGRect(x: origin.x * s, y: origin.y * s, width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var canvas = RGBABitmap(width: rw, height: rh)
        canvas.draw(coarse, topLeftRect: CGRect(x: 0, y: 0, width: rw, height: rh), space: sRGB, quality: .high)
        canvas.draw(image, topLeftRect: rect, space: sRGB, quality: .high)
        let band = bandWidth(photo: rect.size)
        let inner = innerRect(rect, band: CGFloat(band), width: rw, height: rh)
        var known = [UInt8](repeating: 0, count: rw * rh)
        let kx0 = max(0, Int(inner.minX.rounded(.up))), kx1 = min(rw, Int(inner.maxX.rounded(.down)))
        let ky0 = max(0, Int(inner.minY.rounded(.up))), ky1 = min(rh, Int(inner.maxY.rounded(.down)))
        if kx0 < kx1, ky0 < ky1 { for y in ky0..<ky1 { for x in kx0..<kx1 { known[y * rw + x] = 1 } } }

        try await paint(&canvas, known: &known, start: nil, prompt: prompt, seed: seed, strength: refineStrength, steps: refineSteps,
                        overlap: refineOverlap, engine: engine, progress: progress)
        guard let result = canvas.makeImage(space: sRGB) else { throw ExtendError.failed }
        return (result, band)
    }

    /// The windowed painter under every generation: redraws the pixels of `canvas` that aren't `known`, in
    /// overlapping 512 × 512 windows, the one with the most context first, each continuing what's known by
    /// then (so they agree with each other). Each window starts from `start` (nil: the canvas itself), kept
    /// as much as `1 - strength`, and is seam-blended into what was there. Marks everything painted known.
    static func paint(_ canvas: inout RGBABitmap, known: inout [UInt8], start: RGBABitmap?, prompt: String, negative: String? = nil,
                      seed: UInt64, strength: Float, steps: Int, overlap: Int, engine: GenerativeEngine = .shared,
                      progress: (@Sendable (Double) -> Bool)? = nil) async throws {
        let n = window, cw = canvas.width, ch = canvas.height
        guard cw >= n, ch >= n else { throw ExtendError.failed }
        func starts(_ length: Int) -> [Int] {
            guard length > n else { return [0] }
            let count = Int((Double(length - n) / Double(n - overlap)).rounded(.up)) + 1
            return (0..<count).map { Int((Double($0) * Double(length - n) / Double(count - 1)).rounded()) }
        }
        let snapshot = known
        func unknown(_ w: (x: Int, y: Int), in mask: [UInt8]) -> Int {
            var total = 0
            for y in w.y..<(w.y + n) {
                let row = y * cw
                for x in w.x..<(w.x + n) where mask[row + x] == 0 { total += 1 }
            }
            return total
        }
        var pending = starts(cw).flatMap { x in starts(ch).map { (x: x, y: $0) } }.filter { unknown($0, in: snapshot) > 0 }
        let windows = max(pending.count, 1)
        var finished = 0
        while !pending.isEmpty {
            let current = known
            let w = pending.min { unknown($0, in: current) < unknown($1, in: current) }!
            let pixels = canvas.crop(x: w.x, y: w.y, width: n, height: n)
            var windowKnown = [UInt8](repeating: 0, count: n * n)
            for y in 0..<n { for x in 0..<n { windowKnown[y * n + x] = known[(w.y + y) * cw + w.x + x] } }
            var initial = pixels
            if let start {
                initial = start.crop(x: w.x, y: w.y, width: n, height: n)
                for i in 0..<(n * n) where windowKnown[i] != 0 { for c in 0..<4 { initial[i * 4 + c] = pixels[i * 4 + c] } }
            }
            let request = StableDiffusionInpainter.Request(
                rgba: pixels, mask: dilatedUnknown(windowKnown, size: n, radius: 4), prompt: prompt, negativePrompt: negative ?? negativePrompt,
                seed: seed &+ UInt64(w.x * 7919 + w.y) &* 0x9E37_79B9_7F4A_7C15, steps: steps, guidance: guidance,
                initial: strength < 1 ? initial : nil, strength: strength)
            let base = Double(finished) / Double(windows), span = 1 / Double(windows)
            var made: [UInt8]
            do {
                made = try await engine.run { sd in
                    try sd.inpaint(request) { p in progress?(base + span * p) ?? false }
                }
            } catch StableDiffusionInpainter.Failure.cancelled {
                throw ExtendError.cancelled
            }
            // Meet what's known exactly (the model's own version of it drifts a little in color).
            let status = made.withUnsafeMutableBufferPointer { out in
                pixels.withUnsafeBufferPointer { ref in
                    windowKnown.withUnsafeBufferPointer { k in iv_seam_blend(out.baseAddress, ref.baseAddress, k.baseAddress, Int32(n), Int32(n)) }
                }
            }
            guard Int(status) == IV_FILL_OK else { throw ExtendError.failed }
            canvas.paste(made, x: w.x, y: w.y, width: n, height: n)
            for y in w.y..<(w.y + n) { for x in w.x..<(w.x + n) { known[y * cw + x] = 1 } }
            finished += 1
            let now = known
            pending = pending.filter { unknown($0, in: now) > 0 }
        }
    }

    /// The cross-fade band for a photo this size (pixels).
    static func bandWidth(photo size: CGSize) -> Int {
        max(8, Int((bandFraction * min(size.width, size.height)).rounded()))
    }

    /// The photo's rectangle on the canvas, pulled in by `band` on the sides the canvas extends past.
    static func innerRect(_ rect: CGRect, band: CGFloat, width: Int, height: Int) -> CGRect {
        var r = rect
        if rect.minX > 0.5 { r.origin.x += band; r.size.width -= band }
        if rect.maxX < CGFloat(width) - 0.5 { r.size.width -= band }
        if rect.minY > 0.5 { r.origin.y += band; r.size.height -= band }
        if rect.maxY < CGFloat(height) - 0.5 { r.size.height -= band }
        return r
    }

    /// The generated canvas (or an enlargement of it) at the final `width` × `height`, in `image`'s color
    /// space. The original's pixels are in it except in a `band` (final pixels) just inside its extended
    /// edges, where the generated version is kept for the photo to cross-fade into; the generated area meets
    /// the original without an edge or color cast.
    static func finish(_ generated: CGImage, original image: CGImage, width: Int, height: Int, origin: CGPoint,
                       band: Int = 0) throws -> CGImage {
        let origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var fill = RGBABitmap(width: width, height: height)
        fill.draw(generated, topLeftRect: CGRect(x: 0, y: 0, width: width, height: height), space: space, quality: .high)
        var reference = RGBABitmap(width: width, height: height)
        let rect = CGRect(origin: origin, size: CGSize(width: image.width, height: image.height))
        reference.draw(image, topLeftRect: rect, space: space, quality: .none)
        var known = [UInt8](repeating: 0, count: width * height)
        let inner = innerRect(rect, band: CGFloat(band), width: width, height: height)
        let x0 = max(0, Int(inner.minX.rounded(.up))), y0 = max(0, Int(inner.minY.rounded(.up)))
        let x1 = min(width, Int(inner.maxX.rounded(.down))), y1 = min(height, Int(inner.maxY.rounded(.down)))
        if x0 < x1, y0 < y1 { for y in y0..<y1 { for x in x0..<x1 { known[y * width + x] = 1 } } }
        let status = fill.pixels.withUnsafeMutableBufferPointer { out in
            reference.pixels.withUnsafeBufferPointer { ref in
                known.withUnsafeBufferPointer { k in iv_seam_blend(out.baseAddress, ref.baseAddress, k.baseAddress, Int32(width), Int32(height)) }
            }
        }
        guard Int(status) == IV_FILL_OK, let result = fill.makeImage(space: space) else { throw ExtendError.failed }
        return result
    }

    /// The model's mask: everything not known, grown a little into the known area so the model blends
    /// across the seam instead of butting up against it.
    private static func dilatedUnknown(_ known: [UInt8], size n: Int, radius: Int) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n where known[y * n + x] == 0 {
                for yy in max(0, y - radius)...min(n - 1, y + radius) {
                    for xx in max(0, x - radius)...min(n - 1, x + radius) { mask[yy * n + xx] = 1 }
                }
            }
        }
        return mask
    }
}

/// 8-bit RGBA pixels, rows top to bottom, for handing to the C engine and the model.
nonisolated struct RGBABitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Draws `image` into `rect` (top-left origin, pixels).
    mutating func draw(_ image: CGImage, topLeftRect rect: CGRect, space: CGColorSpace, quality: CGInterpolationQuality) {
        let w = width, h = height
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = quality
            ctx.draw(image, in: CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height))
        }
    }

    func crop(x: Int, y: Int, width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let src = ((y + row) * width + x) * 4
            out.replaceSubrange((row * w * 4)..<((row + 1) * w * 4), with: pixels[src..<(src + w * 4)])
        }
        return out
    }

    mutating func paste(_ block: [UInt8], x: Int, y: Int, width w: Int, height h: Int) {
        for row in 0..<h {
            let dst = ((y + row) * width + x) * 4
            pixels.replaceSubrange(dst..<(dst + w * 4), with: block[(row * w * 4)..<((row + 1) * w * 4)])
        }
    }

    /// A tent blur (about a Gaussian), edges extended.
    mutating func blur(radius: Int) {
        guard radius > 0 else { return }
        var source = pixels
        let w = width, h = height
        let size = UInt32(2 * radius + 1)
        source.withUnsafeMutableBytes { src in
            pixels.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                vImageTentConvolve_ARGB8888(&s, &d, nil, 0, 0, size, size, nil, vImage_Flags(kvImageEdgeExtend))
            }
        }
    }

    func makeImage(space: CGColorSpace) -> CGImage? {
        var copy = pixels
        let w = width, h = height
        return copy.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

/// Generated canvases, so the crop tool's preview and the final fill share one generation (and a
/// generation still running when the tool closes is joined rather than started again).
nonisolated final class GenerativeFillCache: @unchecked Sendable {
    static let shared = GenerativeFillCache()

    struct Entry: @unchecked Sendable {
        let image: CGImage     // the whole canvas, working size
        let canvas: CGRect     // normalized, like EditState.crop
    }

    private final class Job: @unchecked Sendable {
        let canvas: CGRect
        var task: Task<Entry, Error>?
        var waiters = 0
        var listeners: [UUID: @Sendable (Double) -> Void] = [:]
        init(canvas: CGRect) { self.canvas = canvas }
    }

    private let lock = NSLock()
    private var finished: [(key: String, entry: Entry)] = []
    private var jobs: [String: Job] = [:]
    private static let keep = 6

    /// A finished or running generation for `key` covering `crop`, else a new one from `make` over `crop`.
    /// Cancelling the caller only stops the generation when nobody else is waiting for it.
    func entry(key: String, crop: CGRect, progress: (@Sendable (Double) -> Void)? = nil,
               make: @escaping @Sendable (_ report: @escaping @Sendable (Double) -> Bool) async throws -> CGImage) async throws -> Entry {
        let id = UUID()
        let (job, hit): (Job?, Entry?) = lock.withLock {
            if let e = finished.last(where: { $0.key == key && Self.covers($0.entry.canvas, crop) })?.entry { return (nil, e) }
            if let running = jobs[key], running.task?.isCancelled == false, Self.covers(running.canvas, crop) {
                running.waiters += 1
                if let progress { running.listeners[id] = progress }
                return (running, nil)
            }
            let job = Job(canvas: crop)
            job.waiters = 1
            if let progress { job.listeners[id] = progress }
            let flag = CancelFlag()
            let lock = self.lock
            job.task = Task.detached(priority: .userInitiated) { [job] in
                let image = try await withTaskCancellationHandler {
                    try await make { fraction in
                        let listeners = lock.withLock { Array(job.listeners.values) }
                        for listener in listeners { listener(fraction) }
                        return flag.isSet
                    }
                } onCancel: { flag.set() }
                return Entry(image: image, canvas: crop)
            }
            jobs[key] = job
            return (job, nil)
        }
        if let hit { return hit }
        guard let job, let task = job.task else { throw ExtendError.failed }
        let leave = { [weak self] in
            self?.lock.withLock {
                job.listeners[id] = nil
                job.waiters -= 1
                if job.waiters == 0 { job.task?.cancel() }
            }
        }
        do {
            let entry = try await withTaskCancellationHandler { try await task.value } onCancel: { leave() }
            lock.withLock {
                if jobs[key] === job {
                    jobs[key] = nil
                    finished.append((key, entry))
                    if finished.count > Self.keep { finished.removeFirst(finished.count - Self.keep) }
                }
            }
            if !Task.isCancelled { leave() }
            return entry
        } catch {
            lock.withLock { if jobs[key] === job { jobs[key] = nil } }
            if !Task.isCancelled { leave() }
            throw error
        }
    }

    private static func covers(_ canvas: CGRect, _ crop: CGRect) -> Bool {
        canvas.insetBy(dx: -0.002, dy: -0.002).contains(crop)
    }
}
