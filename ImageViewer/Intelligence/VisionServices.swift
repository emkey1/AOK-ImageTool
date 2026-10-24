import CoreImage
import Foundation
import Vision

nonisolated enum VisionError: LocalizedError {
    case noSubject
    case noSelection
    case noDocument
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noSubject: "No subject was found in this image."
        case .noSelection: "Nothing was found at that point. Try clicking closer to the object."
        case .noDocument: "No document or rectangle was found in this image."
        case .modelUnavailable(let s): s
        }
    }
}

/// Results of the one-pass analysis used for folder search, quality ranking and duplicate detection.
nonisolated struct ImageAnalysisResult: Sendable {
    var labels: [String] = []
    var text: String = ""
    var score: Float?
    var isUtility: Bool?
    var featurePrint: Data?
}

nonisolated enum VisionServices {
    // MARK: - Helpers

    @concurrent
    static func downscaled(_ image: CGImage, maxDimension: Int) async -> CGImage {
        downscaledSync(image, maxDimension: maxDimension)
    }

    static func downscaledSync(_ image: CGImage, maxDimension: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(longest)
        // (Clamped first, so the edges don't fade to transparent.)
        let ci = CIImage(cgImage: image).clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
        ])
        let rect = CGRect(x: 0, y: 0, width: (Double(image.width) * scale).rounded(), height: (Double(image.height) * scale).rounded())
        return ImageDecoder.ciContext.createCGImage(ci, from: rect, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) ?? image
    }

    /// An ordinary 8-bit sRGB copy of `image` in memory of its own (at most `maxDimension` on a side), for
    /// handing to the system's analyzers. They draw the picture to convert it, and a decoded HDR photo (floating
    /// point, in ImageIO's memory) read that way while Core Image reads it too has crashed Live Text, reading
    /// past the end of the picture.
    @concurrent
    static func plainCopy(_ image: CGImage, maxDimension: Int? = nil) async -> CGImage {
        plainCopySync(image, maxDimension: maxDimension)
    }

    static func plainCopySync(_ image: CGImage, maxDimension: Int? = nil) -> CGImage {
        let longest = max(image.width, image.height)
        let scale = maxDimension.map { min(1, Double($0) / Double(longest)) } ?? 1
        var ci = CIImage(cgImage: image)
        if scale < 1 {
            ci = ci.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        let rect = CGRect(x: 0, y: 0, width: (Double(image.width) * scale).rounded(), height: (Double(image.height) * scale).rounded())
        return ImageDecoder.ciContext.createCGImage(ci.cropped(to: rect), from: rect, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false) ?? image
    }

    // MARK: - Subjects & objects

    /// Mask (white = keep) of all foreground subjects, at the image's pixel size.
    @concurrent
    static func subjectMask(for image: CGImage) async throws -> CIImage {
        let handler = ImageRequestHandler(plainCopySync(image))
        guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()),
              !observation.allInstances.isEmpty
        else { throw VisionError.noSubject }
        let buffer = try observation.generateScaledMask(for: observation.allInstances, scaledToImageFrom: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    /// Mask of the subject instance under `point` (normalized, lower-left origin). Fallback for click-to-select.
    @concurrent
    static func instanceMask(for image: CGImage, at point: CGPoint) async throws -> CIImage {
        let handler = ImageRequestHandler(image)
        guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()) else {
            throw VisionError.noSelection
        }
        var value = observation.allInstancesMask.pixel(at: NormalizedPoint(x: point.x, y: point.y))
        if value > 0, value < 1 { value *= 255 }
        let index = Int(value.rounded())
        guard index > 0, observation.allInstances.contains(index) else { throw VisionError.noSelection }
        let buffer = try observation.generateScaledMask(for: IndexSet(integer: index), scaledToImageFrom: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    /// Click-to-select segmentation (macOS 27): include/exclude points refine the selection. The request is
    /// iterative: it's run on the first point, then again after each point added (adding them all before the
    /// first run fails).
    @available(macOS 27, *)
    @concurrent
    static func objectMask(for image: CGImage, included: [CGPoint], excluded: [CGPoint]) async throws -> CIImage {
        guard let first = included.first else { throw VisionError.noSelection }
        let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: first.x, y: first.y))
        request.qualityLevel = .accurate
        switch await request.assetStatus {
        case .ready:
            break
        case .error(let error):
            throw error
        default:
            let progress = ProgressManager(totalCount: 1)
            try await request.downloadAssets(progress: progress.subprogress(assigningCount: 1))
        }
        let handler = ImageRequestHandler(plainCopySync(image))
        var observation = try await handler.perform(request)
        for p in included.dropFirst() {
            try request.addIncludedPoint(NormalizedPoint(x: p.x, y: p.y))
            observation = try await handler.perform(request)
        }
        for p in excluded {
            try request.addExcludedPoint(NormalizedPoint(x: p.x, y: p.y))
            observation = try await handler.perform(request)
        }
        guard let observation else { throw VisionError.noSelection }
        return CIImage(cgImage: try observation.cgImage)
    }

    /// Bounding box (pixel coordinates, lower-left origin) of the opaque part of a mask.
    static func maskBounds(_ mask: CIImage, imageSize: CGSize) -> CGRect? {
        let sample = 512.0
        let ext = mask.extent
        guard ext.width > 0, ext.height > 0 else { return nil }
        let scale = min(1, sample / max(ext.width, ext.height))
        let small = mask.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(ceil(ext.width * scale))
        let h = Int(ceil(ext.height * scale))
        var buffer = [UInt8](repeating: 0, count: w * h)
        ImageDecoder.ciContext.render(small, toBitmap: &buffer, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                      format: .L8, colorSpace: nil)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where buffer[y * w + x] > 25 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Bitmap rows are top-down; convert to lower-left origin and to the image's pixel size.
        let sx = imageSize.width / Double(w)
        let sy = imageSize.height / Double(h)
        let rect = CGRect(x: Double(minX) * sx, y: Double(h - 1 - maxY) * sy,
                          width: Double(maxX - minX + 1) * sx, height: Double(maxY - minY + 1) * sy)
        return rect.insetBy(dx: -4, dy: -4).intersection(CGRect(origin: .zero, size: imageSize)).integral
    }

    // MARK: - Understanding

    @concurrent
    static func hasFaces(_ image: CGImage) async -> Bool {
        !((try? await DetectFaceRectanglesRequest().perform(on: image, orientation: nil)) ?? []).isEmpty
    }

    @concurrent
    static func classify(_ image: CGImage) async -> [String] {
        guard let observations = try? await ClassifyImageRequest().perform(on: image, orientation: nil) else { return [] }
        return labels(from: observations)
    }

    static func labels(from observations: [ClassificationObservation]) -> [String] {
        observations
            .filter { $0.confidence >= 0.15 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(20)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    @concurrent
    static func recognizeText(_ image: CGImage, fast: Bool) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: image, orientation: nil) else { return "" }
        return text(from: observations)
    }

    static func text(from observations: [RecognizedTextObservation]) -> String {
        observations
            .sorted { a, b in
                let ay = a.boundingBox.origin.y + a.boundingBox.height / 2
                let by = b.boundingBox.origin.y + b.boundingBox.height / 2
                if abs(ay - by) > 0.012 { return ay > by }
                return a.boundingBox.origin.x < b.boundingBox.origin.x
            }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    @concurrent
    static func aesthetics(_ image: CGImage) async -> (score: Float, isUtility: Bool)? {
        guard let o = try? await CalculateImageAestheticsScoresRequest().perform(on: image, orientation: nil) else { return nil }
        return (o.overallScore, o.isUtility)
    }

    /// One pass of everything the folder index needs.
    @concurrent
    static func analyzeForIndex(_ image: CGImage) async -> ImageAnalysisResult {
        let handler = ImageRequestHandler(image)
        var ocr = RecognizeTextRequest()
        ocr.recognitionLevel = .fast
        ocr.usesLanguageCorrection = false
        var result = ImageAnalysisResult()
        if let (classes, text, aesthetic, print) = try? await handler.perform(
            ClassifyImageRequest(), ocr, CalculateImageAestheticsScoresRequest(), GenerateImageFeaturePrintRequest()
        ) {
            result.labels = labels(from: classes)
            result.text = self.text(from: text)
            result.score = aesthetic.overallScore
            result.isUtility = aesthetic.isUtility
            result.featurePrint = try? JSONEncoder().encode(print)
            return result
        }
        // A single failing request shouldn't sink the others.
        if let classes = try? await handler.perform(ClassifyImageRequest()) { result.labels = labels(from: classes) }
        if let text = try? await handler.perform(ocr) { result.text = self.text(from: text) }
        if let a = try? await handler.perform(CalculateImageAestheticsScoresRequest()) {
            result.score = a.overallScore
            result.isUtility = a.isUtility
        }
        if let p = try? await handler.perform(GenerateImageFeaturePrintRequest()) {
            result.featurePrint = try? JSONEncoder().encode(p)
        }
        return result
    }

    // MARK: - Geometry helpers

    /// Degrees to turn the picture clockwise to level it: from its long straight lines (a horizon, or walls
    /// and door frames), with Vision's horizon detector as a second opinion. nil when it has neither a clear
    /// horizon nor upright lines. (Vision alone finds no horizon in a level photo, and misses many tilts.)
    @concurrent
    static func straightenAngle(_ image: CGImage) async -> Double? {
        let lines = tiltFromLines(image)
        var vision: Double?
        if let o = try? await DetectHorizonRequest().perform(on: image, orientation: nil) {
            vision = -atan2(Double(o.transform.b), Double(o.transform.a)) * 180 / .pi
        }
        switch (lines, vision) {
        case let (l?, v?): return abs(l.degrees - v) < 1.5 || l.strength >= 0.4 ? l.degrees : v
        case let (l?, nil): return l.degrees
        case let (nil, v?): return v
        case (nil, nil): return nil
        }
    }

    /// The C line finder (Imaging/Straighten) on a small grayscale copy.
    static func tiltFromLines(_ image: CGImage, maxDegrees: Double = 20) -> (degrees: Double, strength: Double)? {
        let scale = min(1, 640 / Double(max(image.width, image.height)))
        let w = max(16, Int(Double(image.width) * scale)), h = max(16, Int(Double(image.height) * scale))
        var gray = [UInt8](repeating: 0, count: w * h)
        let drew = gray.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var degrees = 0.0, strength = 0.0, kind: Int32 = 0
        guard iv_estimate_tilt(gray, Int32(w), Int32(h), maxDegrees, &degrees, &strength, &kind) == 1 else { return nil }
        return (degrees, strength)
    }

    /// Union of attention-salient regions (normalized, lower-left origin).
    @concurrent
    static func salientRegion(_ image: CGImage) async -> CGRect? {
        guard let observation = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: image, orientation: nil) else { return nil }
        let rects = observation.salientObjects.map { o -> CGRect in
            let b = o.boundingBox
            return CGRect(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height)
        }
        guard var union = rects.first else { return nil }
        for r in rects.dropFirst() { union = union.union(r) }
        return union
    }

    @concurrent
    static func documentQuad(_ image: CGImage) async -> Quad? {
        guard let o = try? await DetectDocumentSegmentationRequest().perform(on: image, orientation: nil) else { return nil }
        func p(_ n: NormalizedPoint) -> CGPoint { CGPoint(x: n.x, y: n.y) }
        return Quad(topLeft: p(o.topLeft), topRight: p(o.topRight), bottomRight: p(o.bottomRight), bottomLeft: p(o.bottomLeft))
    }

    // MARK: - Similarity

    private static func decodePrints(_ prints: [(URL, Data)]) -> [(URL, FeaturePrintObservation)] {
        let decoder = JSONDecoder()
        return prints.compactMap { url, data in
            (try? decoder.decode(FeaturePrintObservation.self, from: data)).map { (url, $0) }
        }
    }

    static func distances(from reference: Data, to prints: [(URL, Data)]) -> [URL: Float] {
        guard let ref = try? JSONDecoder().decode(FeaturePrintObservation.self, from: reference) else { return [:] }
        var result: [URL: Float] = [:]
        for (url, print) in decodePrints(prints) {
            if let d = try? ref.distance(to: print) { result[url] = Float(d) }
        }
        return result
    }

    /// Groups images whose feature-print distance is below `threshold` (single-linkage via union-find).
    static func clusterDuplicates(_ prints: [(URL, Data)], threshold: Float) -> [[URL]] {
        let decoded = decodePrints(prints)
        let n = decoded.count
        guard n > 1 else { return [] }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in 0..<n {
            for j in (i + 1)..<n {
                guard let d = try? decoded[i].1.distance(to: decoded[j].1), Float(d) < threshold else { continue }
                let a = find(i), b = find(j)
                if a != b { parent[b] = a }
            }
        }
        var groups: [Int: [URL]] = [:]
        for i in 0..<n { groups[find(i), default: []].append(decoded[i].0) }
        return groups.values.filter { $0.count > 1 }
    }
}
