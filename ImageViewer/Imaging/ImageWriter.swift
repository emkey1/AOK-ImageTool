import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum MetadataPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case keepAll, removeLocation, removeAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepAll: "Keep All Metadata"
        case .removeLocation: "Remove Location"
        case .removeAll: "Remove All Metadata"
        }
    }
}

nonisolated enum ImageWriteError: LocalizedError {
    case cannotCreateDestination(String)
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case .cannotCreateDestination(let type): "Can't write \(type) files."
        case .finalizeFailed: "The image couldn't be written."
        }
    }
}

nonisolated enum ImageWriter {
    static func write(_ image: CGImage, to url: URL, format: ExportFormat, quality: Double,
                      sourceProperties: [String: Any], metadata: MetadataPolicy) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ImageWriteError.cannotCreateDestination(format.displayName)
        }
        var props: [CFString: Any] = metadata == .removeAll ? [:] : sanitized(sourceProperties, removeLocation: metadata == .removeLocation)
        props[kCGImagePropertyOrientation] = 1
        if format.supportsQuality {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        var output = image
        if !format.supportsAlpha, hasAlpha(image), let flat = flattened(image) {
            output = flat
        }
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageWriteError.finalizeFailed }
    }

    /// Overwrites `original` atomically. When `trashOriginal` is set the previous version goes to the
    /// Trash (so it can be recovered) instead of being destroyed.
    static func replace(original: URL, with image: CGImage, format: ExportFormat, quality: Double,
                        sourceProperties: [String: Any], trashOriginal: Bool) throws {
        let fm = FileManager.default
        let temp = original.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)")
            .appendingPathExtension(original.pathExtension)
        try write(image, to: temp, format: format, quality: quality, sourceProperties: sourceProperties, metadata: .keepAll)
        let label = (try? original.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber
        do {
            if trashOriginal {
                try fm.trashItem(at: original, resultingItemURL: nil)
                try fm.moveItem(at: temp, to: original)
            } else {
                _ = try fm.replaceItemAt(original, withItemAt: temp)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        if let label, label != 0 {
            var values = URLResourceValues()
            values.labelNumber = label
            var u = original
            try? u.setResourceValues(values)
        }
    }

    static func sanitized(_ props: [String: Any], removeLocation: Bool) -> [CFString: Any] {
        let keep: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary,
        ]
        var out: [CFString: Any] = [:]
        for key in keep {
            if let v = props[key as String] { out[key] = v }
        }
        if removeLocation { out[kCGImagePropertyGPSDictionary] = nil }
        if var exif = out[kCGImagePropertyExifDictionary] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = nil
            exif[kCGImagePropertyExifPixelYDimension as String] = nil
            exif[kCGImagePropertyExifSubjectArea as String] = nil
            out[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = out[kCGImagePropertyTIFFDictionary] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        return out
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Composites over white for formats without an alpha channel (JPEG, BMP).
    static func flattened(_ image: CGImage) -> CGImage? {
        let cs = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// A non-colliding URL next to `url`, e.g. "Photo (Edited).jpg", "Photo (Edited 2).jpg".
    static func uniqueURL(in folder: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
