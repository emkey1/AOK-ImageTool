import CoreLocation
import Foundation
import ImageIO

nonisolated struct MetadataRow: Identifiable, Hashable, Sendable {
    let label: String
    let value: String
    var id: String { label }
}

nonisolated struct MetadataSection: Identifiable, Sendable {
    let title: String
    let rows: [MetadataRow]
    var id: String { title }
}

nonisolated enum MetadataFormatting {
    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func exifDate(_ string: String) -> Date? {
        exifFormatter.date(from: String(string.prefix(19)))
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    static func megapixels(_ size: CGSize) -> String {
        String(format: "%.1f MP", size.width * size.height / 1_000_000)
    }

    static func date(_ date: Date?) -> String? {
        date?.formatted(date: .abbreviated, time: .shortened)
    }

    private static func dict(_ props: [String: Any], _ key: CFString) -> [String: Any] {
        props[key as String] as? [String: Any] ?? [:]
    }

    static func gpsCoordinate(_ props: [String: Any]) -> CLLocationCoordinate2D? {
        let gps = dict(props, kCGImagePropertyGPSDictionary)
        guard var lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude as String] as? Double else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" { lat = -lat }
        if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" { lon = -lon }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return CLLocationCoordinate2DIsValid(c) && !(lat == 0 && lon == 0) ? c : nil
    }

    static func dateTaken(_ props: [String: Any]) -> Date? {
        let exif = dict(props, kCGImagePropertyExifDictionary)
        let tiff = dict(props, kCGImagePropertyTIFFDictionary)
        let raw = (exif[kCGImagePropertyExifDateTimeOriginal as String] ?? tiff[kCGImagePropertyTIFFDateTime as String]) as? String
        return raw.flatMap(exifDate)
    }

    static func cameraName(_ props: [String: Any]) -> String? {
        let tiff = dict(props, kCGImagePropertyTIFFDictionary)
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespaces)
        switch (make, model) {
        case let (make?, model?):
            return model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
        case let (nil, model?): return model
        case let (make?, nil): return make
        default: return nil
        }
    }

    /// "24 mm  ƒ/1.8  1/120 s  ISO 80"
    static func exposureSummary(_ props: [String: Any]) -> String? {
        let exif = dict(props, kCGImagePropertyExifDictionary)
        var parts: [String] = []
        if let f35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double {
            parts.append("\(Int(f35)) mm")
        } else if let f = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            parts.append(String(format: "%.0f mm", f))
        }
        if let a = exif[kCGImagePropertyExifFNumber as String] as? Double {
            parts.append(String(format: "ƒ/%.1f", a).replacingOccurrences(of: ".0", with: ""))
        }
        if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double, t > 0 {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first {
            parts.append("ISO \(iso)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    static func sections(for decoded: DecodedImage?, item: ImageItem) -> [MetadataSection] {
        var sections: [MetadataSection] = []
        let props = decoded?.properties ?? [:]

        var file: [MetadataRow] = [
            MetadataRow(label: "Name", value: item.name),
            MetadataRow(label: "Kind", value: item.kindDescription),
            MetadataRow(label: "Size", value: fileSize(item.fileSize)),
        ]
        if let d = decoded {
            file.append(MetadataRow(label: "Dimensions", value: dimensions(d.pixelSize) + "  (" + megapixels(d.pixelSize) + ")"))
            if d.pageCount > 1 { file.append(MetadataRow(label: "Pages", value: "\(d.pageCount)")) }
        }
        if let created = date(item.creationDate) { file.append(MetadataRow(label: "Created", value: created)) }
        if let modified = date(item.modificationDate) { file.append(MetadataRow(label: "Modified", value: modified)) }
        sections.append(MetadataSection(title: "File", rows: file))

        var image: [MetadataRow] = []
        if let model = props[kCGImagePropertyColorModel as String] as? String { image.append(MetadataRow(label: "Color Model", value: model)) }
        if let profile = props[kCGImagePropertyProfileName as String] as? String { image.append(MetadataRow(label: "Profile", value: profile)) }
        if let depth = props[kCGImagePropertyDepth as String] as? Int { image.append(MetadataRow(label: "Bit Depth", value: "\(depth) bits")) }
        if let dpi = props[kCGImagePropertyDPIWidth as String] as? Double { image.append(MetadataRow(label: "Resolution", value: "\(Int(dpi)) dpi")) }
        if let d = decoded {
            image.append(MetadataRow(label: "Transparency", value: d.hasTransparentPixels ? "Yes" : d.hasAlpha ? "No (opaque alpha channel)" : "No"))
            if d.isHDR { image.append(MetadataRow(label: "Dynamic Range", value: "HDR")) }
            if d.isAnimated { image.append(MetadataRow(label: "Animated", value: "Yes")) }
        }
        if !image.isEmpty { sections.append(MetadataSection(title: "Image", rows: image)) }

        let exif = dict(props, kCGImagePropertyExifDictionary)
        let exifAux = dict(props, kCGImagePropertyExifAuxDictionary)
        var camera: [MetadataRow] = []
        if let name = cameraName(props) { camera.append(MetadataRow(label: "Camera", value: name)) }
        if let lens = (exif[kCGImagePropertyExifLensModel as String] ?? exifAux[kCGImagePropertyExifAuxLensModel as String]) as? String {
            camera.append(MetadataRow(label: "Lens", value: lens))
        }
        if let summary = exposureSummary(props) { camera.append(MetadataRow(label: "Exposure", value: summary)) }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue as String] as? Double, bias != 0 {
            camera.append(MetadataRow(label: "Exposure Bias", value: String(format: "%+.1f EV", bias)))
        }
        if let flash = exif[kCGImagePropertyExifFlash as String] as? Int {
            camera.append(MetadataRow(label: "Flash", value: flash & 1 == 1 ? "Fired" : "Off"))
        }
        if let taken = date(dateTaken(props)) { camera.append(MetadataRow(label: "Taken", value: taken)) }
        let tiff = dict(props, kCGImagePropertyTIFFDictionary)
        if let software = tiff[kCGImagePropertyTIFFSoftware as String] as? String { camera.append(MetadataRow(label: "Software", value: software)) }
        if !camera.isEmpty { sections.append(MetadataSection(title: "Camera", rows: camera)) }

        let iptc = dict(props, kCGImagePropertyIPTCDictionary)
        var desc: [MetadataRow] = []
        if let caption = iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String { desc.append(MetadataRow(label: "Caption", value: caption)) }
        if let keywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String], !keywords.isEmpty {
            desc.append(MetadataRow(label: "Keywords", value: keywords.joined(separator: ", ")))
        }
        if let artist = (tiff[kCGImagePropertyTIFFArtist as String] ?? iptc[kCGImagePropertyIPTCByline as String]) as? String {
            desc.append(MetadataRow(label: "Artist", value: artist))
        }
        if let copyright = (tiff[kCGImagePropertyTIFFCopyright as String] ?? iptc[kCGImagePropertyIPTCCopyrightNotice as String]) as? String {
            desc.append(MetadataRow(label: "Copyright", value: copyright))
        }
        if !desc.isEmpty { sections.append(MetadataSection(title: "Description", rows: desc)) }

        return sections
    }

    /// Flattened view of every metadata key, for the "All Metadata" disclosure.
    static func allRows(_ props: [String: Any]) -> [MetadataRow] {
        var rows: [MetadataRow] = []
        func walk(_ dict: [String: Any], prefix: String) {
            for key in dict.keys.sorted() {
                let value = dict[key]!
                let label = prefix.isEmpty ? key : "\(prefix) › \(key)"
                if let nested = value as? [String: Any] {
                    walk(nested, prefix: label.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""))
                } else if let array = value as? [Any] {
                    rows.append(MetadataRow(label: label, value: array.map { "\($0)" }.joined(separator: ", ")))
                } else if value is Data {
                    continue
                } else {
                    rows.append(MetadataRow(label: label, value: "\(value)"))
                }
            }
        }
        walk(props, prefix: "")
        return rows
    }
}
