import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

/// Apple's on-device machine-learning upscaler (VideoToolbox super resolution): 4×. The model takes up to
/// 1920 × 1920 pixels at a time; bigger images go through it in overlapping tiles. Its model is a one-time
/// download from Apple, which the user starts.
nonisolated enum SuperResolution {
    /// The model's only scale; 2× and 3× are made by resampling its output.
    static let factor = 4
    /// The most the model takes in one pass.
    static let maxSide = 1920
    /// The largest result (Core Image and most apps handle up to this on a side).
    static let maxOutputSide = 16384
    private static let tileSide = 1024
    private static let tileOverlap = 64
    static let offeredScales = [2, 3, 4]

    enum ModelState: Sendable {
        case unsupported, needsDownload, downloading, ready
    }

    enum Failure: LocalizedError {
        case unsupported, tooLarge, modelMissing, failed

        var errorDescription: String? {
            switch self {
            case .unsupported: "AI upscaling isn't available on this Mac."
            case .tooLarge: "The upscaled image would be more than \(SuperResolution.maxOutputSide) pixels on a side. Try a smaller scale."
            case .modelMissing: "The AI upscaling model hasn't been downloaded yet."
            case .failed: "The image couldn't be upscaled."
            }
        }
    }

    /// Whether this Mac and macOS version can upscale at all (macOS 26+, supported hardware). The menus
    /// hide AI upscaling otherwise.
    static let isSupported: Bool = modelState != .unsupported

    static var modelState: ModelState {
        guard #available(macOS 26, *) else { return .unsupported }
        guard VTSuperResolutionScalerConfiguration.isSupported,
              VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(factor),
              let config = configuration(width: 64, height: 64) else { return .unsupported }
        switch config.configurationModelStatus {
        case .ready: return .ready
        case .downloading: return .downloading
        default: return .needsDownload
        }
    }

    /// How much of the model is on this Mac, 0...1.
    static var downloadProgress: Double {
        guard #available(macOS 26, *) else { return 0 }
        return Double(configuration(width: 64, height: 64)?.configurationModelPercentageAvailable ?? 0)
    }

    static func downloadModel() async throws {
        guard #available(macOS 26, *), let config = configuration(width: 64, height: 64) else { throw Failure.unsupported }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            config.downloadConfigurationModel { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Whether the model takes the image in one pass.
    static func fits(width: Int, height: Int) -> Bool {
        width >= 1 && height >= 1 && width <= maxSide && height <= maxSide
    }

    /// Whether `upscale` can make a `scale`× copy (in tiles if need be).
    static func canUpscale(width: Int, height: Int, scale: CGFloat) -> Bool {
        width >= 1 && height >= 1 && CGFloat(max(width, height)) * min(scale, CGFloat(factor)) <= CGFloat(maxOutputSide)
    }

    /// Upscales `image` 4× with the model, then resamples to `scale` (at most 4) times its size.
    /// Transparency is upscaled conventionally and put back over the upscaled colors.
    static func upscale(_ image: CGImage, scale: CGFloat = CGFloat(factor)) async throws -> CGImage {
        guard #available(macOS 26, *) else { throw Failure.unsupported }
        return try await upscaleWithModel(image, scale: scale)
    }

    @available(macOS 26, *)
    private static func upscaleWithModel(_ image: CGImage, scale: CGFloat) async throws -> CGImage {
        let width = image.width, height = image.height
        guard canUpscale(width: width, height: height, scale: scale) else { throw Failure.tooLarge }
        let single = fits(width: width, height: height)
        let frame = single ? (width, height) : (tileSide, tileSide)
        guard let config = configuration(width: frame.0, height: frame.1) else { throw Failure.unsupported }
        guard config.configurationModelStatus == .ready else { throw Failure.modelMissing }

        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let input = CIImage(cgImage: image)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // (Rendered images always have an alpha channel; only real transparency needs carrying over.)
        let alpha = !(image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast)
            && ImageDecoder.containsTransparency(image)
        let deep = image.bitsPerComponent > 8
        let colors = (alpha ? input.unpremultiplyingAlpha().settingAlphaOne(in: extent) : input).clampedToExtent()

        let source = try pixelBuffer(width: frame.0, height: frame.1, attributes: config.sourcePixelBufferAttributes)
        let destination = try pixelBuffer(width: frame.0 * factor, height: frame.1 * factor, attributes: config.destinationPixelBufferAttributes)
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }

        /// The model's 4× output for `region` (source pixels, Core Image coordinates), placed at 4× its position.
        func scaled(_ region: CGRect) async throws -> CIImage {
            context.render(colors.transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY)), to: source,
                           bounds: CGRect(x: 0, y: 0, width: region.width, height: region.height), colorSpace: space)
            guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: .zero),
                  let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: .zero),
                  let parameters = VTSuperResolutionScalerParameters(sourceFrame: sourceFrame, previousFrame: nil, previousOutputFrame: nil,
                                                                     opticalFlow: nil, submissionMode: .random, destinationFrame: destinationFrame)
            else { throw Failure.failed }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                processor.process(parameters: parameters) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let f = CGFloat(factor)
            return CIImage(cvPixelBuffer: destination, options: [.colorSpace: space])
                .transformed(by: CGAffineTransform(translationX: region.minX * f, y: region.minY * f))
        }

        var output: CIImage
        if single {
            output = try await scaled(extent)
        } else {
            // Overlapping tiles; each keeps the part up to the middle of its overlaps, so every join is where
            // both neighbors had context. They're drawn into one bitmap as they're made (each tile's output is
            // over 100 MB).
            let outW = width * factor, outH = height * factor
            let bitmapInfo = deep
                ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order16Little.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue
            guard let canvas = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: bitmapInfo) else { throw Failure.failed }
            let xs = tileStarts(width), ys = tileStarts(height)
            let f = factor
            for (i, x) in xs.enumerated() {
                for (j, y) in ys.enumerated() {
                    let up = try await scaled(CGRect(x: x, y: y, width: tileSide, height: tileSide))
                    let keepX0 = i == 0 ? 0 : (x + xs[i - 1] + tileSide) / 2, keepX1 = i == xs.count - 1 ? width : (xs[i + 1] + x + tileSide) / 2
                    let keepY0 = j == 0 ? 0 : (y + ys[j - 1] + tileSide) / 2, keepY1 = j == ys.count - 1 ? height : (ys[j + 1] + y + tileSide) / 2
                    let keep = CGRect(x: keepX0 * f, y: keepY0 * f, width: (keepX1 - keepX0) * f, height: (keepY1 - keepY0) * f)
                    guard let piece = context.createCGImage(up, from: keep, format: deep ? .RGBAh : .RGBA8, colorSpace: space,
                                                            deferred: false) else { throw Failure.failed }
                    canvas.draw(piece, in: keep)   // Core Image and Core Graphics are both y-up here
                }
            }
            guard let whole = canvas.makeImage() else { throw Failure.failed }
            output = CIImage(cgImage: whole)
        }

        output = output.settingAlphaOne(in: output.extent)
        if alpha {
            let mask = input.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
            output = output.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        let resample = min(scale, CGFloat(factor)) / CGFloat(factor)
        if resample < 0.999 {
            output = output.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: resample, kCIInputAspectRatioKey: 1])
        }
        let rect = CGRect(x: 0, y: 0, width: (CGFloat(width) * CGFloat(factor) * resample).rounded(),
                          height: (CGFloat(height) * CGFloat(factor) * resample).rounded())
        guard let result = context.createCGImage(output.cropped(to: rect), from: rect, format: deep ? .RGBAh : .RGBA8,
                                                 colorSpace: space, deferred: false) else { throw Failure.failed }
        return result
    }

    /// Where tiles start along a side, overlapping by `tileOverlap`, the last one flush with the end.
    private static func tileStarts(_ length: Int) -> [Int] {
        guard length > tileSide else { return [0] }
        let step = tileSide - tileOverlap
        let count = Int((Double(length - tileSide) / Double(step)).rounded(.up)) + 1
        return (0..<count).map { min($0 * step, length - tileSide) }
    }

    // MARK: - Private

    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "SuperResolution"])

    @available(macOS 26, *)
    private static func configuration(width: Int, height: Int) -> VTSuperResolutionScalerConfiguration? {
        VTSuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: factor, inputType: .image,
                                             usePrecomputedFlow: false, qualityPrioritization: .normal,
                                             revision: VTSuperResolutionScalerConfiguration.defaultRevision)
    }

    /// An IOSurface-backed buffer in the format the scaler asks for.
    private static func pixelBuffer(width: Int, height: Int, attributes: [String: any Sendable]) throws -> CVPixelBuffer {
        let format = (attributes[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber])?.first?.uint32Value
            ?? kCVPixelFormatType_64RGBAHalf
        var attrs: [String: Any] = attributes
        attrs[kCVPixelBufferWidthKey as String] = width
        attrs[kCVPixelBufferHeightKey as String] = height
        attrs[kCVPixelBufferPixelFormatTypeKey as String] = format
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure.failed }
        return buffer
    }
}
