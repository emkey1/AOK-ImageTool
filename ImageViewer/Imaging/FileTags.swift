import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture's star rating, title, caption and keywords, kept where other apps look for them: as XMP in the
/// file itself for JPEG, HEIC, PNG and TIFF (only the metadata is rewritten, never the picture), and in a
/// sidecar next to it ("IMG_0001.xmp") for camera RAW, DNG and formats that can't hold XMP, as Lightroom,
/// Bridge and Capture One expect.
nonisolated enum FileTags {
    struct Values: Equatable, Sendable {
        /// 0 unrated, else 0.5...5 (half stars; Lightroom and Bridge show whole ones).
        var rating: Double = 0
        var title: String?
        var caption: String?
        var keywords: [String] = []
    }

    /// What to change: nil leaves it as it is.
    struct Update: Sendable {
        var rating: Double?
        var title: String?
        var caption: String?
        var keywords: [String]?
    }

    enum Failure: LocalizedError {
        case unreadable, unwritable

        var errorDescription: String? {
            switch self {
            case .unreadable: "The file couldn't be read."
            case .unwritable: "Its metadata couldn't be written."
            }
        }
    }

    // MARK: Where

    /// The formats whose own XMP is written (ImageIO rewrites their metadata without touching the picture).
    static func embeds(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), !SupportedFormats.isRAW(type) else { return false }
        return [UTType.jpeg, .png, .heic, .tiff].contains { type.conforms(to: $0) }
    }

    /// The sidecar for a file that doesn't hold its own XMP.
    static func sidecar(for url: URL) -> URL? {
        embeds(url) ? nil : url.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: Reading

    /// The file's tags: its own XMP, with a sidecar's on top (Lightroom's edits to a RAW are there).
    static func read(_ url: URL) -> Values {
        var values = Values()
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            values = Self.values(metadata)
        }
        if let sidecar = sidecar(for: url), let data = try? Data(contentsOf: sidecar),
           let metadata = CGImageMetadataCreateFromXMPData(data as CFData) {
            let side = Self.values(metadata)
            if side.rating > 0 || CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Rating" as CFString) != nil { values.rating = side.rating }
            values.title = side.title ?? values.title
            values.caption = side.caption ?? values.caption
            if !side.keywords.isEmpty { values.keywords = side.keywords }
        }
        return values
    }

    private static func values(_ metadata: CGImageMetadata) -> Values {
        var values = Values()
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Rating" as CFString), let value = CGImageMetadataTagCopyValue(tag) {
            let rating = (value as? NSNumber)?.doubleValue ?? Double(String(describing: value)) ?? 0
            // (-1 is Bridge's "rejected"; past 5 isn't a rating.)
            values.rating = rating > 0 ? min(5, (rating * 2).rounded() / 2) : 0
        }
        values.title = text(metadata, "dc:title")
        values.caption = text(metadata, "dc:description")
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString) {
            values.keywords = strings(CGImageMetadataTagCopyValue(tag))
        }
        return values
    }

    /// A text property (a plain string, or the first of a language alternative's).
    private static func text(_ metadata: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { return nil }
        return strings(CGImageMetadataTagCopyValue(tag)).first.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func strings(_ value: CFTypeRef?) -> [String] {
        if let string = value as? String { return [string] }
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element in
            if let string = element as? String { return string }
            let tag = element as CFTypeRef
            guard CFGetTypeID(tag) == CGImageMetadataTagGetTypeID() else { return nil }
            return CGImageMetadataTagCopyValue(tag as! CGImageMetadataTag) as? String
        }
    }

    // MARK: Writing

    private static let queue = DispatchQueue(label: "FileTags", qos: .userInitiated)

    /// Writes `update` to `url` (in order with other writes). Returns the file's new modification date when the
    /// file itself was rewritten (its picture unchanged), nil when a sidecar was.
    static func write(_ update: Update, to url: URL) async throws -> Date? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try writeNow(update, to: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func writeNow(_ update: Update, to url: URL) throws -> Date? {
        if let sidecar = sidecar(for: url) {
            try writeSidecar(update, to: sidecar)
            return nil
        }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .png) == true {
            try writePNG(update, to: url)
        } else {
            try writeEmbedded(update, to: url)
        }
        // (A fresh URL: another one for this file may have cached the old date.)
        return try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func apply(_ update: Update, to metadata: CGMutableImageMetadata) {
        // (0 is XMP's "unrated": removing the property doesn't take with every format.)
        if let rating = update.rating { CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, rating as NSNumber) }
        if let title = update.title { CGImageMetadataSetValueWithPath(metadata, nil, "dc:title" as CFString, title as CFString) }
        if let caption = update.caption {
            CGImageMetadataSetValueWithPath(metadata, nil, "dc:description" as CFString, caption as CFString)
            // (The caption is written for people who can't see the picture, as its alt text.)
            CGImageMetadataSetValueWithPath(metadata, nil, "Iptc4xmpCore:AltTextAccessibility" as CFString, caption as CFString)
        }
        if let keywords = update.keywords,
           let tag = CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString, "subject" as CFString,
                                              .arrayUnordered, keywords as CFArray) {
            CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, tag)
        }
    }

    /// The file rewritten with its metadata changed, through a copy that then takes its place (keeping its
    /// Finder tags, label and other extended attributes).
    private static func writeEmbedded(_ update: Update, to url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else { throw Failure.unreadable }
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(url.lastPathComponent)
        guard let destination = CGImageDestinationCreateWithURL(copy as CFURL, type, CGImageSourceGetCount(source), nil) else {
            throw Failure.unwritable
        }
        let metadata = CGImageMetadataCreateMutable()
        apply(update, to: metadata)
        let options = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options, &error) else {
            throw error?.takeRetainedValue() ?? Failure.unwritable
        }
        _ = try fm.replaceItemAt(url, withItemAt: copy)
    }

    /// PNG: ImageIO doesn't add XMP to a PNG without any, so its XMP text chunk is written here, before the
    /// picture's data; every other chunk is copied byte for byte.
    private static func writePNG(_ update: Update, to url: URL) throws {
        let data = try Data(contentsOf: url)
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard data.count > 8, data.prefix(8) == signature else { throw Failure.unreadable }
        let keyword = Data("XML:com.adobe.xmp".utf8)
        var kept: [Range<Int>] = []
        var firstData: Int?
        var existing: Data?
        var i = 8
        while i + 12 <= data.count {
            let length = data[i..<(i + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard i + 12 + length <= data.count else { throw Failure.unreadable }
            let type = String(decoding: data[(i + 4)..<(i + 8)], as: UTF8.self)
            let body = data[(i + 8)..<(i + 8 + length)]
            if type == "iTXt", body.starts(with: keyword + [0]) {
                // keyword, NUL, compression flag and method, language, NUL, translated keyword, NUL, text.
                let fields = body.dropFirst(keyword.count + 1)
                guard fields.first == 0 else { throw Failure.unwritable }   // (a compressed one: leave the file alone)
                let afterLanguage = fields.dropFirst(2).drop { $0 != 0 }.dropFirst()
                existing = Data(afterLanguage.drop { $0 != 0 }.dropFirst())
            } else {
                if type == "IDAT", firstData == nil { firstData = kept.count }
                kept.append(i..<(i + 12 + length))
            }
            i += 12 + length
        }
        guard let firstData else { throw Failure.unreadable }
        let metadata = existing.flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }.flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        apply(update, to: metadata)
        guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) as Data? else { throw Failure.unwritable }
        let body = keyword + Data([0, 0, 0, 0, 0]) + xmp
        var chunk = Data()
        chunk.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
        let typed = Data("iTXt".utf8) + body
        chunk.append(typed)
        chunk.append(contentsOf: withUnsafeBytes(of: crc32(typed).bigEndian, Array.init))
        var result = signature
        for (n, range) in kept.enumerated() {
            if n == firstData { result.append(chunk) }
            result.append(data[range])
        }
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(url.lastPathComponent)
        try result.write(to: copy)
        _ = try fm.replaceItemAt(url, withItemAt: copy)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    /// The sidecar's XMP, changed (anything else in it, like Lightroom's settings, is kept).
    private static func writeSidecar(_ update: Update, to sidecar: URL) throws {
        let existing = (try? Data(contentsOf: sidecar)).flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
        let metadata = existing.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        apply(update, to: metadata)
        guard let data = CGImageMetadataCreateXMPData(metadata, nil) else { throw Failure.unwritable }
        try (data as Data).write(to: sidecar, options: .atomic)
    }
}
