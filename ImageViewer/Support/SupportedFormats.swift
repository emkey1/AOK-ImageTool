import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum SupportedFormats {
    /// Every type ImageIO can decode, plus vector formats rendered through AppKit.
    static let readableTypes: [UTType] = {
        var ids = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        ids += [UTType.pdf.identifier, UTType.svg.identifier]
        return ids.compactMap { UTType($0) }
    }()

    private static let readableIdentifiers: Set<String> = Set(readableTypes.map(\.identifier))

    static func isSupported(_ type: UTType?) -> Bool {
        guard let type else { return false }
        if readableIdentifiers.contains(type.identifier) { return true }
        if type.conforms(to: .rawImage) { return true }
        return readableTypes.contains { type.conforms(to: $0) }
    }

    static func isVector(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .svg)
    }

    static func isRAW(_ type: UTType?) -> Bool {
        type?.conforms(to: .rawImage) == true
    }

    /// Formats that a Save (overwrite in place) can write back without changing type.
    static func writableFormat(for type: UTType?) -> ExportFormat? {
        guard let type else { return nil }
        return ExportFormat.allCases.first { type.conforms(to: $0.utType) }
    }

    static var readableExtensionsSummary: String {
        let exts = Set(readableTypes.compactMap { $0.preferredFilenameExtension?.uppercased() })
        return exts.sorted().joined(separator: ", ")
    }
}

nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case jpeg, heic, avif, png, tiff, gif, bmp, jpeg2000

    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .heic
        case .png: .png
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .jpeg2000: UTType("public.jpeg-2000") ?? .jpeg
        }
    }

    var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .jpeg2000: "JPEG 2000"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .jpeg2000: "jp2"
        default: utType.preferredFilenameExtension ?? rawValue
        }
    }

    var supportsQuality: Bool { [.jpeg, .heic, .avif, .jpeg2000].contains(self) }
    var supportsAlpha: Bool { [.png, .heic, .avif, .tiff, .gif, .jpeg2000].contains(self) }
}
