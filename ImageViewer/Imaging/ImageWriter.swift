import CoreGraphics
import CoreImage
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
    /// Writes `image` with the metadata of the file it came from: `sourceProperties`, and the XMP of `source`
    /// (keywords, labels, panorama tags…), as `metadata` allows.
    static func write(_ image: CGImage, to url: URL, format: ExportFormat, quality: Double,
                      sourceProperties: [String: Any], metadata: MetadataPolicy, source: URL? = nil) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ImageWriteError.cannotCreateDestination(format.displayName)
        }
        var props: [CFString: Any] = metadata == .removeAll ? [:] : sanitized(sourceProperties, removeLocation: metadata == .removeLocation)
        props[kCGImagePropertyOrientation] = 1
        if format.supportsQuality {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        let (output, gainMap) = prepared(image, for: format)
        if gainMap {
            // An SDR picture with an ISO gain map, as cameras write HDR photos: it looks right everywhere.
            props[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
        }
        if metadata != .removeAll, let source, let xmp = carriedXMP(from: source, removeLocation: metadata == .removeLocation) {
            CGImageDestinationAddImageAndMetadata(dest, output, xmp, props as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, output, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ImageWriteError.finalizeFailed }
    }

    /// The image as `format` should store it: HDR as a gain map (HEIC, JPEG) or tone mapped to SDR (the
    /// rest); whole numbers rather than half floats; an alpha channel only for real transparency; and
    /// flattened onto white for formats without alpha. `gainMap`: write it with an ISO gain map.
    static func prepared(_ image: CGImage, for format: ExportFormat) -> (image: CGImage, gainMap: Bool) {
        var output = image
        var gainMap = false
        if ImageDecoder.isHDR(image) {
            if format == .heic || format == .jpeg { gainMap = true } else { output = toneMappedToSDR(image) ?? image }
        }
        let transparent = hasAlpha(output) && ImageDecoder.containsTransparency(output)
        if transparent {
            if !format.supportsAlpha { output = flattened(output) ?? output }
            else if !gainMap, output.bitmapInfo.contains(.floatComponents) { output = wholeNumbers(output, alpha: true) ?? output }
        } else if !gainMap {
            output = wholeNumbers(output, alpha: false) ?? output
        }
        return (output, gainMap)
    }

    /// HDR brought down to SDR (Display P3, 16 bits) for formats that can't hold it.
    static func toneMappedToSDR(_ image: CGImage) -> CGImage? {
        var ci = CIImage(cgImage: image)
        if let tone = CIFilter(name: "CIToneMapHeadroom") {
            tone.setValue(ci, forKey: kCIInputImageKey)
            tone.setValue(1.0, forKey: "inputTargetHeadroom")
            if let out = tone.outputImage { ci = out }
        }
        return ImageDecoder.ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                                    format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
    }

    /// 8 or 16 bits per channel as whole numbers (ImageIO writes half floats to TIFF as floating point,
    /// which many apps can't open), in a standard-range color space, with or without alpha.
    static func wholeNumbers(_ image: CGImage, alpha: Bool) -> CGImage? {
        let deep = image.bitsPerComponent > 8
        var space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        space = CGColorSpaceCreateCopyWithStandardRange(space)
        let info = (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
            | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: deep ? 16 : 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// The XMP of `source` that still holds for the new image: not its orientation or size (the pixels are
    /// upright and may be cropped), and with `removeLocation`, no place.
    static func carriedXMP(from source: URL, removeLocation: Bool) -> CGImageMetadata? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let original = CGImageSourceCopyMetadataAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil),
              let xmp = CGImageMetadataCreateMutableCopy(original) else { return nil }
        let location = ["exif:gps", "photoshop:city", "photoshop:state", "photoshop:country", "iptc4xmpcore:location",
                        "iptc4xmpcore:countrycode", "iptc4xmpext:locationshown", "iptc4xmpext:locationcreated"]
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(original, nil, nil) { path, _ in
            paths.append(path as String)
            return true
        }
        for path in paths {
            let p = path.lowercased()
            let stale = p.hasPrefix("tiff:orientation") || p.hasPrefix("exif:pixelxdimension") || p.hasPrefix("exif:pixelydimension")
                || p.hasPrefix("exif:subjectarea")
            if stale || (removeLocation && location.contains(where: p.hasPrefix)) {
                CGImageMetadataRemoveTagWithPath(xmp, nil, path as CFString)
            }
        }
        return xmp
    }

    /// Overwrites `original` atomically. When `trashOriginal` is set the previous version goes to the
    /// Trash (so it can be recovered) instead of being destroyed.
    static func replace(original: URL, with image: CGImage, format: ExportFormat, quality: Double,
                        sourceProperties: [String: Any], trashOriginal: Bool) throws {
        let fm = FileManager.default
        let temp = original.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)")
            .appendingPathExtension(original.pathExtension)
        try write(image, to: temp, format: format, quality: quality, sourceProperties: sourceProperties, metadata: .keepAll,
                  source: original)
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

    /// Writes over `original` where it is, the same file, for one another app is watching (Photos' Edit With
    /// session). It's made in full elsewhere first, so failing to make it leaves the original as it was; only
    /// failing to write the finished file (a full disk) could leave the original part rewritten.
    static func overwrite(original: URL, with image: CGImage, format: ExportFormat, quality: Double,
                          sourceProperties: [String: Any]) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(original.pathExtension)
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(image, to: temp, format: format, quality: quality, sourceProperties: sourceProperties, metadata: .keepAll, source: original)
        let data = try Data(contentsOf: temp)
        let handle = try FileHandle(forWritingTo: original)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
    }

    static func sanitized(_ props: [String: Any], removeLocation: Bool) -> [CFString: Any] {
        let keep: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
        ]
        var out: [CFString: Any] = [:]
        for key in keep {
            if let v = props[key as String] { out[key] = v }
        }
        if removeLocation {
            out[kCGImagePropertyGPSDictionary] = nil
            if var iptc = out[kCGImagePropertyIPTCDictionary] as? [String: Any] {
                for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode] {
                    iptc[key as String] = nil
                }
                out[kCGImagePropertyIPTCDictionary] = iptc
            }
        }
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

    /// Composites over white for formats without an alpha channel (JPEG, BMP), keeping the image's depth
    /// and color space (an HDR picture stays HDR).
    static func flattened(_ image: CGImage) -> CGImage? {
        let cs = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ci = CIImage(cgImage: image)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: ci.extent)
        return ImageDecoder.ciContext.createCGImage(ci.composited(over: white), from: ci.extent,
                                                    format: image.bitsPerComponent > 8 ? .RGBAh : .RGBA8, colorSpace: cs)
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
