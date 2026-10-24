import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Image ▸ Fix Blur, on this Mac: camera shake or soft focus taken out by Restormer (MIT,
/// github.com/swz30/Restormer), and faces restored by GFPGAN v1.4 (Apache-2.0, github.com/TencentARC/GFPGAN).
/// They're converted to Core ML by scripts/convert-sharpen-models.sh and installed per user like the other
/// models. (NAFNet was tried first: on some pictures it gave colored noise, and it roughened sharp photos.)
nonisolated enum BlurFixer {
    /// What kind of blur to take out of the whole picture.
    enum Blur: String, CaseIterable, Identifiable, Codable, Sendable {
        case focus, shake, none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .focus: "Out of Focus"
            case .shake: "Camera Shake"
            case .none: "None"
            }
        }

        var model: ImageModel? {
            switch self {
            case .focus: BlurFixer.focusModel
            case .shake: BlurFixer.shakeModel
            case .none: nil
            }
        }
    }

    struct Options: Codable, Equatable, Sendable {
        var blur = Blur.focus
        /// 0...1: how much of the sharpened picture replaces the original.
        var blurStrength = 1.0
        var faces = true
        var faceStrength = 0.6

        /// What can run: what's chosen and installed.
        var available: Options {
            var o = self
            if blur.model?.isInstalled != true { o.blur = .none }
            o.faces = faces && BlurFixer.faceModel.isInstalled
            return o
        }

        var doesSomething: Bool { (blur != .none && blurStrength > 0) || (faces && faceStrength > 0) }

        /// The choice used last (Fix Blur starts from it).
        static var last: Options {
            get {
                UserDefaults.standard.data(forKey: PrefKey.fixBlur).flatMap { try? JSONDecoder().decode(Options.self, from: $0) } ?? Options()
            }
            set { Prefs.set(try? JSONEncoder().encode(newValue), PrefKey.fixBlur) }
        }
    }

    enum Failure: LocalizedError {
        case nothingToDo, cancelled, failed

        var errorDescription: String? {
            switch self {
            case .nothingToDo: "Choose a kind of blur or Faces (and get its model) first."
            case .cancelled: "Fixing the blur was cancelled."
            case .failed: "The blur couldn't be fixed."
            }
        }
    }

    static let shakeModel = ImageModel(purpose: "camera shake", folder: "Shake", modelName: "Shake.mlmodelc", side: 384)
    static let focusModel = ImageModel(purpose: "focus", folder: "Focus", modelName: "Focus.mlmodelc", side: 384)
    static let faceModel = ImageModel(purpose: "face restoration", folder: "Faces", modelName: "Faces.mlmodelc", side: 512)
    static let blurModelName = "Restormer"
    static let facesModelName = "GFPGAN"
    /// Both blur models are one download (see `DownloadableModel.fixBlur`).
    static var blurModelsInstalled: Bool { shakeModel.isInstalled && focusModel.isInstalled }

    /// Installs the blur models from a folder holding Shake.mlmodelc and Focus.mlmodelc (the converter's
    /// output folder, or the download's).
    static func installBlurModels(from folder: URL) throws {
        try shakeModel.install(from: folder)
        try focusModel.install(from: folder)
    }

    static func removeBlurModels() throws {
        try shakeModel.remove()
        try focusModel.remove()
    }
    /// How much neighboring tiles overlap; they're blended across it (a tile's edges see less around them).
    static let tileOverlap = 48
    /// GFPGAN's face template (FFHQ, 512 × 512, top-left origin): the eyes, the nose and the mouth's corners.
    static let template: [CGPoint] = [CGPoint(x: 192.98, y: 239.95), CGPoint(x: 318.90, y: 240.19), CGPoint(x: 256.63, y: 314.02),
                                      CGPoint(x: 201.26, y: 371.41), CGPoint(x: 313.09, y: 371.15)]

    /// `picture` with its camera shake taken out and its faces restored, as `options` say. `progress` gets
    /// 0...1 and returns true to cancel.
    @concurrent
    static func fix(_ picture: CGImage, _ options: Options, progress: (@Sendable (Double) -> Bool)? = nil) async throws -> CGImage {
        let options = options.available
        guard options.doesSomething else { throw Failure.nothingToDo }
        let size = CGSize(width: picture.width, height: picture.height)
        let rect = CGRect(origin: .zero, size: size)
        // (8-bit buffers can't use an extended-range space, such as an HDR photo's.)
        let pictureSpace = picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let space = CGColorSpaceCreateCopyWithStandardRange(pictureSpace)
        let original = CIImage(cgImage: picture)
        var result = original
        let blurShare = options.blur != .none && options.faces ? 0.85 : 1.0
        if let model = options.blur.model, options.blurStrength > 0 {
            let sharp = try await deblur(picture, with: model, space: space) { progress?(blurShare * $0) ?? false }
            result = blend(CIImage(cgImage: sharp), over: original, amount: options.blurStrength)
        }
        if options.faces, options.faceStrength > 0 {
            if progress?(blurShare) == true { throw Failure.cancelled }
            result = try await restoreFaces(result, size: size, space: space, strength: options.faceStrength)
        }
        // (The models make every pixel opaque: a see-through picture keeps its own transparency.)
        if ![.none, .noneSkipFirst, .noneSkipLast].contains(picture.alphaInfo) {
            result = result.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect), kCIInputMaskImageKey: original,
            ])
        }
        let deep = picture.bitsPerComponent > 8
        guard let made = EditRenderer.shared.context.createCGImage(result.cropped(to: rect), from: rect, format: deep ? .RGBAh : .RGBA8,
                                                                   colorSpace: pictureSpace)
        else { throw Failure.failed }
        return made
    }

    private static func blend(_ top: CIImage, over bottom: CIImage, amount: Double) -> CIImage {
        amount >= 0.999 ? top : top.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: bottom, kCIInputTimeKey: 1 - amount])
    }

    // MARK: Blur

    /// A blur model over the whole picture in overlapping tiles, each blended into the ones before it.
    private static func deblur(_ picture: CGImage, with model: ImageModel, space: CGColorSpace,
                               progress: (@Sendable (Double) -> Bool)?) async throws -> CGImage {
        let n = model.side, w = picture.width, h = picture.height
        func starts(_ length: Int) -> [Int] {
            guard length > n else { return [0] }
            var s = Array(stride(from: 0, to: length - n, by: n - tileOverlap))
            s.append(length - n)
            return s
        }
        let xs = starts(w), ys = starts(h)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.failed }
        ctx.interpolationQuality = .none
        let total = Double(xs.count * ys.count)
        var done = 0.0
        var masks: [String: CGImage] = [:]
        // Rows top-down (in the picture's own top-left coordinates); the context is y-up.
        for (yi, y) in ys.enumerated() {
            for (xi, x) in xs.enumerated() {
                if progress?(done / total) == true { throw Failure.cancelled }
                let tw = min(n, w), th = min(n, h)
                guard let tile = picture.cropping(to: CGRect(x: x, y: y, width: tw, height: th)) else { throw Failure.failed }
                var input = tile
                if tw < n || th < n {
                    // A picture smaller than a tile: the rest of the tile is its mirror image.
                    var square = RGBABitmap(width: n, height: n)
                    square.draw(tile, topLeftRect: CGRect(x: 0, y: 0, width: tw, height: th), space: space, quality: .none)
                    square.mirror(beyondWidth: tw, height: th)
                    guard let made = square.makeImage(space: space) else { throw Failure.failed }
                    input = made
                }
                let output = try await model.predict(input, space: space)
                guard var sharp = output.cropping(to: CGRect(x: 0, y: 0, width: tw, height: th)) else { throw Failure.failed }
                // (A tile the model got wrong, black or noise, keeps the picture as it was.)
                if Self.differ(sharp, tile) { sharp = tile }
                // Overlaps with the tiles already drawn (left and above) fade in.
                let left = xi > 0 ? xs[xi - 1] + n - x : 0
                let top = yi > 0 ? ys[yi - 1] + n - y : 0
                let place = CGRect(x: x, y: h - y - th, width: tw, height: th)
                if left == 0 && top == 0 {
                    ctx.draw(sharp, in: place)
                } else {
                    let key = "\(tw)x\(th)|\(left)|\(top)"
                    let mask = masks[key] ?? fadeMask(width: tw, height: th, left: left, top: top)
                    masks[key] = mask
                    ctx.saveGState()
                    if let mask { ctx.clip(to: place, mask: mask) }
                    ctx.draw(sharp, in: place)
                    ctx.restoreGState()
                }
                done += 1
            }
        }
        guard let made = ctx.makeImage() else { throw Failure.failed }
        return made
    }

    /// Whether two pictures of the same place differ by far more than sharpening changes (compared small).
    static func differ(_ a: CGImage, _ b: CGImage) -> Bool {
        let n = 16
        func small(_ image: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: n * n * 4)
            px.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            }
            return px
        }
        let pa = small(a), pb = small(b)
        var total = 0
        for i in 0..<(n * n) { for c in 0..<3 { total += abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c])) } }
        return Double(total) / Double(n * n * 3) > 24
    }

    /// White, ramping up from black over `left` pixels at the left and `top` at the top (rows top-down).
    private static func fadeMask(width w: Int, height h: Int, left: Int, top: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            let fy = top > 0 ? min(1, Double(y) / Double(top)) : 1
            for x in 0..<w {
                let fx = left > 0 ? min(1, Double(x) / Double(left)) : 1
                bytes[y * w + x] = UInt8((fx * fy * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        // (A grayscale image, which clip(to:mask:) reads as coverage: white draws.)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Faces

    /// Each face Vision finds, aligned to GFPGAN's template, restored, and laid back where it was with soft edges.
    private static func restoreFaces(_ image: CIImage, size: CGSize, space: CGColorSpace, strength: Double) async throws -> CIImage {
        let renderer = EditRenderer.shared
        // Found on a smaller copy (the landmarks are relative to the picture).
        let scale = min(1, 2048 / max(size.width, size.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let smallRect = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
        guard let probe = renderer.context.createCGImage(small, from: smallRect, format: .RGBA8, colorSpace: space) else { throw Failure.failed }
        let faces = (try? await DetectFaceLandmarksRequest().perform(on: probe)) ?? []
        var result = image
        let crop = CGRect(x: 0, y: 0, width: 512, height: 512)
        for face in faces {
            guard let points = Self.anchors(face, imageSize: size) else { continue }
            // Too small to have anything to restore from.
            guard hypot(points[1].x - points[0].x, points[1].y - points[0].y) >= 10 else { continue }
            // The picture → the face crop (Core Image coordinates, y up, in both).
            let target = template.map { CGPoint(x: $0.x, y: 512 - $0.y) }
            guard let toCrop = similarity(from: points, to: target) else { continue }
            let aligned = result.clampedToExtent().transformed(by: toCrop).cropped(to: crop)
            guard let input = renderer.context.createCGImage(aligned, from: crop, format: .RGBA8, colorSpace: space) else { continue }
            let restored = try await faceModel.predict(input, space: space)
            let back = toCrop.inverted()
            // Laid back over the face with soft edges, as much as `strength`.
            let edge = CIImage(color: .white).cropped(to: crop.insetBy(dx: 40, dy: 40))
                .applyingGaussianBlur(sigma: 14).cropped(to: crop)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
            let face = CIImage(cgImage: restored).transformed(by: back)
            let mask = edge.transformed(by: back)
            result = face.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask])
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        return result
    }

    /// A face's eyes, nose and mouth corners in the picture's pixels (y up), in the template's order (the
    /// eye and mouth corner on the left of the picture first).
    static func anchors(_ face: FaceObservation, imageSize size: CGSize) -> [CGPoint]? {
        guard let marks = face.landmarks else { return nil }
        func center(_ region: FaceObservation.Landmarks2D.Region) -> CGPoint? {
            let p = region.pointsInImageCoordinates(size, origin: .lowerLeft)
            guard !p.isEmpty else { return nil }
            return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        guard let a = center(marks.leftPupil) ?? center(marks.leftEye), let b = center(marks.rightPupil) ?? center(marks.rightEye),
              let nose = center(marks.nose) else { return nil }
        let lips = marks.outerLips.pointsInImageCoordinates(size, origin: .lowerLeft)
        guard let mouthLeft = lips.min(by: { $0.x < $1.x }), let mouthRight = lips.max(by: { $0.x < $1.x }) else { return nil }
        let eyes = a.x <= b.x ? [a, b] : [b, a]
        return [eyes[0], eyes[1], nose, mouthLeft, mouthRight]
    }

    /// The rotation, uniform scale and shift that best take `from` onto `to` (least squares).
    static func similarity(from: [CGPoint], to: [CGPoint]) -> CGAffineTransform? {
        let n = CGFloat(from.count)
        guard from.count == to.count, n >= 2 else { return nil }
        let fc = CGPoint(x: from.map(\.x).reduce(0, +) / n, y: from.map(\.y).reduce(0, +) / n)
        let tc = CGPoint(x: to.map(\.x).reduce(0, +) / n, y: to.map(\.y).reduce(0, +) / n)
        var a: CGFloat = 0, b: CGFloat = 0, norm: CGFloat = 0
        for (p, q) in zip(from, to) {
            let px = p.x - fc.x, py = p.y - fc.y, qx = q.x - tc.x, qy = q.y - tc.y
            a += px * qx + py * qy
            b += px * qy - py * qx
            norm += px * px + py * py
        }
        guard norm > 0 else { return nil }
        a /= norm
        b /= norm
        // x' = a x - b y + tx, y' = b x + a y + ty
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tc.x - (a * fc.x - b * fc.y), ty: tc.y - (b * fc.x + a * fc.y))
    }
}
