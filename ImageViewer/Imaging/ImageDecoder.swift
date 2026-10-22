import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// A fully decoded, display-oriented image plus the source metadata we need for the inspector and saving.
nonisolated final class DecodedImage: @unchecked Sendable {
    let url: URL
    let cgImage: CGImage
    let pixelSize: CGSize
    let isHDR: Bool
    let hasAlpha: Bool
    /// Some pixels are actually see-through (an alpha channel alone doesn't mean that — many PNGs are opaque).
    let hasTransparentPixels: Bool
    let isAnimated: Bool
    let pageCount: Int
    let pageIndex: Int
    let typeIdentifier: String?
    let properties: [String: Any]
    let sourceOrientation: CGImagePropertyOrientation
    let isVector: Bool
    /// Smaller than the file (past what the display can show), so it mustn't be saved over it.
    let isReduced: Bool
    /// Frames, for an animation (1 otherwise).
    let frameCount: Int

    var cost: Int { cgImage.bytesPerRow * cgImage.height }
    var contentType: UTType? { typeIdentifier.flatMap(UTType.init) }

    init(url: URL, cgImage: CGImage, isHDR: Bool, isAnimated: Bool, pageCount: Int, pageIndex: Int,
         typeIdentifier: String?, properties: [String: Any], sourceOrientation: CGImagePropertyOrientation, isVector: Bool,
         isReduced: Bool = false, frameCount: Int = 1) {
        self.url = url
        self.cgImage = cgImage
        self.pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        self.isHDR = isHDR
        let alpha = cgImage.alphaInfo
        let alphaChannel = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        self.hasAlpha = alphaChannel
        self.hasTransparentPixels = alphaChannel && ImageDecoder.containsTransparency(cgImage)
        self.isAnimated = isAnimated
        self.pageCount = pageCount
        self.pageIndex = pageIndex
        self.typeIdentifier = typeIdentifier
        self.properties = properties
        self.sourceOrientation = sourceOrientation
        self.isVector = isVector
        self.isReduced = isReduced
        self.frameCount = frameCount
    }
}

nonisolated struct ImageHeader: Sendable {
    let pixelSize: CGSize
    let isRAW: Bool
    var megapixels: Double { pixelSize.width * pixelSize.height / 1_000_000 }
}

nonisolated enum ImageDecodeError: LocalizedError {
    case unreadable
    case noImage

    var errorDescription: String? {
        switch self {
        case .unreadable: "The file couldn't be read as an image."
        case .noImage: "The file doesn't contain a displayable image."
        }
    }
}

nonisolated enum ImageDecoder {
    static let ciContext = CIContext(options: [.cacheIntermediates: false, .name: "ImageDecoder"])

    private static let animatedTypes: Set<String> = [
        "com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics", "public.avis",
    ]
    private static let multiSizeTypes: Set<String> = ["com.microsoft.ico", "com.apple.icns", "com.microsoft.cur"]

    static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
    }

    // MARK: - Header

    static func header(url: URL) -> ImageHeader? {
        let type = contentType(of: url)
        if SupportedFormats.isVector(type) {
            return nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let index = primaryIndex(src)
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
        let size = orientation.swapsDimensions ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        return ImageHeader(pixelSize: size, isRAW: SupportedFormats.isRAW(type))
    }

    private static func primaryIndex(_ src: CGImageSource) -> Int {
        let type = CGImageSourceGetType(src) as String? ?? ""
        let count = CGImageSourceGetCount(src)
        if multiSizeTypes.contains(type), count > 1 {
            var best = 0
            var bestArea = 0
            for i in 0..<count {
                guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { continue }
                let area = (p[kCGImagePropertyPixelWidth] as? Int ?? 0) * (p[kCGImagePropertyPixelHeight] as? Int ?? 0)
                if area > bestArea { bestArea = area; best = i }
            }
            return best
        }
        return CGImageSourceGetPrimaryImageIndex(src)
    }

    // MARK: - Full decode

    static func decode(url: URL, page: Int = 0, allowHDR: Bool) throws -> DecodedImage {
        let type = contentType(of: url)
        if SupportedFormats.isVector(type) {
            return try decodeVector(url: url, type: type, page: page, maxDimension: 4096)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageDecodeError.unreadable
        }
        let typeID = CGImageSourceGetType(src) as String?
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw ImageDecodeError.noImage }

        let isAnimated = count > 1 && animatedTypes.contains(typeID ?? "")
        let isMultiSize = multiSizeTypes.contains(typeID ?? "")
        let pageCount = (isAnimated || isMultiSize) ? 1 : count
        let index = isMultiSize ? primaryIndex(src) : (pageCount > 1 ? min(max(page, 0), count - 1) : CGImageSourceGetPrimaryImageIndex(src))

        let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any]) ?? [:]
        let orientation = (props[kCGImagePropertyOrientation as String] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up

        var options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true,
        ]
        if allowHDR {
            options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        }
        guard var image = CGImageSourceCreateImageAtIndex(src, index, options as CFDictionary) else {
            throw ImageDecodeError.noImage
        }

        let isHDR = allowHDR && Self.isHDR(image)
        image = oriented(image, orientation, deep: isHDR || image.bitsPerComponent > 8)
        let fullWidth = image.width
        image = clampedForDisplay(image)

        return DecodedImage(
            url: url, cgImage: image, isHDR: isHDR, isAnimated: isAnimated,
            pageCount: pageCount, pageIndex: pageCount > 1 ? index : 0,
            typeIdentifier: typeID, properties: props, sourceOrientation: orientation, isVector: false,
            isReduced: image.width != fullWidth, frameCount: isAnimated ? count : 1
        )
    }

    /// True if any pixel is less than fully opaque (a GPU reduction to the single least-opaque pixel).
    static func containsTransparency(_ image: CGImage) -> Bool {
        let ci = CIImage(cgImage: image)
        let minimum = ci.applyingFilter("CIAreaMinimumAlpha", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var pixel = [UInt8](repeating: 255, count: 4)
        ciContext.render(minimum, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
        return pixel[3] < 250
    }

    static func isHDR(_ image: CGImage) -> Bool {
        if image.contentHeadroom > 1.01 { return true }
        guard let cs = image.colorSpace else { return false }
        return CGColorSpaceUsesITUR_2100TF(cs)
    }

    /// Applies an EXIF orientation by rendering through Core Image (GPU). No-op for `.up`.
    static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation, deep: Bool) -> CGImage {
        guard orientation != .up else { return image }
        let ci = CIImage(cgImage: image).oriented(orientation)
        let moved = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.createCGImage(moved, from: moved.extent, format: deep ? .RGBAh : .RGBA8, colorSpace: colorSpace, deferred: false) ?? image
    }

    /// Core Animation can't display textures larger than the GPU limit; downscale only in that rare case.
    private static func clampedForDisplay(_ image: CGImage) -> CGImage {
        let limit = 16_384
        guard max(image.width, image.height) > limit else { return image }
        let scale = Double(limit) / Double(max(image.width, image.height))
        let ci = CIImage(cgImage: image).clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let rect = CGRect(x: 0, y: 0, width: (Double(image.width) * scale).rounded(), height: (Double(image.height) * scale).rounded())
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.createCGImage(ci, from: rect, format: image.bitsPerComponent > 8 ? .RGBAh : .RGBA8, colorSpace: colorSpace) ?? image
    }

    // MARK: - Vector (PDF / SVG)

    static func pageCount(ofPDF url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 1
    }

    static func decodeVector(url: URL, type: UTType?, page: Int, maxDimension: CGFloat) throws -> DecodedImage {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        if type?.conforms(to: .pdf) == true {
            guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw ImageDecodeError.unreadable }
            let pageNumber = min(max(page, 0), doc.numberOfPages - 1) + 1
            guard let pdfPage = doc.page(at: pageNumber) else { throw ImageDecodeError.noImage }
            var size = pdfPage.getBoxRect(.cropBox).size
            if pdfPage.rotationAngle % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            let scale = min(maxDimension / max(size.width, size.height), 6)
            let px = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
            guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw ImageDecodeError.noImage }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(origin: .zero, size: px))
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            ctx.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(pdfPage)
            guard let image = ctx.makeImage() else { throw ImageDecodeError.noImage }
            return DecodedImage(url: url, cgImage: image, isHDR: false, isAnimated: false, pageCount: doc.numberOfPages,
                                pageIndex: pageNumber - 1, typeIdentifier: type?.identifier, properties: [:],
                                sourceOrientation: .up, isVector: true)
        }

        guard let ns = NSImage(contentsOf: url), ns.size.width > 0, ns.size.height > 0 else { throw ImageDecodeError.unreadable }
        let longest = max(ns.size.width, ns.size.height)
        let scale = min(maxDimension / longest, max(1, 2048 / longest))
        let px = CGSize(width: max(1, (ns.size.width * scale).rounded()), height: max(1, (ns.size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ImageDecodeError.noImage }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        ns.draw(in: CGRect(origin: .zero, size: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { throw ImageDecodeError.noImage }
        return DecodedImage(url: url, cgImage: image, isHDR: false, isAnimated: false, pageCount: 1, pageIndex: 0,
                            typeIdentifier: type?.identifier, properties: [:], sourceOrientation: .up, isVector: true)
    }

    // MARK: - Previews & thumbnails

    /// A fast, screen-sized preview for formats that are slow to decode (RAW, very large images).
    /// Uses the embedded preview when the file has one. Returns nil when a preview wouldn't help.
    static func quickPreview(url: URL, header: ImageHeader?) -> CGImage? {
        guard let header, header.isRAW || header.megapixels > 40 else { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, primaryIndex(src), opts as CFDictionary)
    }

    static func thumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        let type = contentType(of: url)
        if SupportedFormats.isVector(type) {
            return try? decodeVector(url: url, type: type, page: 0, maxDimension: CGFloat(maxPixelSize)).cgImage
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let index = primaryIndex(src)
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        // Prefer an embedded thumbnail when it's big enough; it's dramatically faster.
        if let embedded = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary),
           Double(max(embedded.width, embedded.height)) >= Double(maxPixelSize) * 0.8 || SupportedFormats.isRAW(type) {
            return embedded
        }
        opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary)
    }
}

nonisolated extension CGImagePropertyOrientation {
    var swapsDimensions: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: true
        default: false
        }
    }
}
