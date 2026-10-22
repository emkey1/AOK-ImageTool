import Foundation
import UniformTypeIdentifiers

/// Culling flag stored as the file's Finder color label, so it shows up in Finder too.
nonisolated enum Flag: Int, Sendable {
    case none = 0
    case pick = 2    // Finder "Green"
    case reject = 6  // Finder "Red"

    init(labelNumber: Int?) {
        switch labelNumber {
        case 2: self = .pick
        case 6: self = .reject
        default: self = .none
        }
    }
}

nonisolated struct ImageItem: Identifiable, Hashable, Sendable {
    let url: URL
    var name: String
    let contentType: UTType?
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    var flag: Flag
    var dateTaken: Date?
    /// The file this one was made from (an upscaled, colorized… copy), by name, in the same folder.
    var source: String?

    var id: URL { url }

    var kindDescription: String {
        contentType?.localizedDescription ?? url.pathExtension.uppercased()
    }

    var isRAW: Bool { SupportedFormats.isRAW(contentType) }
}

nonisolated enum SortKey: String, CaseIterable, Identifiable, Sendable {
    case name, dateModified, dateCreated, dateTaken, size, kind, quality, random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .dateTaken: "Date Taken"
        case .size: "File Size"
        case .kind: "Kind"
        case .quality: "Best Shots (AI)"
        case .random: "Shuffle"
        }
    }
}

nonisolated enum FlagFilter: String, CaseIterable, Identifiable, Sendable {
    case all, picks, rejects, unflagged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Images"
        case .picks: "Picks"
        case .rejects: "Rejects"
        case .unflagged: "Unflagged"
        }
    }

    func includes(_ flag: Flag) -> Bool {
        switch self {
        case .all: true
        case .picks: flag == .pick
        case .rejects: flag == .reject
        case .unflagged: flag == .none
        }
    }
}
