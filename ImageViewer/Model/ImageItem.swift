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
    var modificationDate: Date?
    var flag: Flag
    /// Stars (0.5...5, 0 unrated), from the file's XMP or sidecar; nil until read.
    var rating: Double? = nil
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
    case name, dateModified, dateCreated, dateTaken, size, kind, rating, quality, random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .dateTaken: "Date Taken"
        case .size: "File Size"
        case .kind: "Kind"
        case .rating: "Rating"
        case .quality: "Best Shots (AI)"
        case .random: "Shuffle"
        }
    }
}

nonisolated enum FlagFilter: String, CaseIterable, Identifiable, Sendable {
    case all, picks, rejects, unflagged, edited, oneStar, twoStars, threeStars, fourStars, fiveStars

    static let byFlag: [FlagFilter] = [.all, .picks, .rejects, .unflagged, .edited]
    static let byRating: [FlagFilter] = [.oneStar, .twoStars, .threeStars, .fourStars, .fiveStars]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Images"
        case .picks: "Picks"
        case .rejects: "Rejects"
        case .unflagged: "Unflagged"
        case .edited: "Edited Images"
        case .fiveStars: "★★★★★"
        default: String(repeating: "★", count: Int(minimumStars ?? 0)) + " or More"
        }
    }

    /// The fewest stars a rating filter shows.
    var minimumStars: Double? {
        switch self {
        case .oneStar: 1
        case .twoStars: 2
        case .threeStars: 3
        case .fourStars: 4
        case .fiveStars: 5
        default: nil
        }
    }

    func includes(_ item: ImageItem) -> Bool {
        if let stars = minimumStars { return (item.rating ?? 0) >= stars }
        switch self {
        case .picks: return item.flag == .pick
        case .rejects: return item.flag == .reject
        case .unflagged: return item.flag == .none
        default: return true   // (all; edited is by its edits: ViewerModel filters those)
        }
    }
}

/// Stars as text: "★★★½".
nonisolated func starsText(_ rating: Double) -> String {
    String(repeating: "★", count: Int(rating)) + (rating.truncatingRemainder(dividingBy: 1) >= 0.5 ? "½" : "")
}
