import Foundation

/// Unsaved edits kept in Application Support so they survive a relaunch. Each entry remembers the
/// file's modification date and is only restored while the file is unchanged.
final class PendingEdits {
    static let shared = PendingEdits()

    private struct Entry: Codable {
        var modDate: Date
        var edits: EditState
    }

    private struct File: Codable {
        var version = 1
        var entries: [String: Entry]
    }

    private let fileURL: URL
    /// Keyed by standardized file path.
    private lazy var entries: [String: Entry] = load()
    private var isDirty = false
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL = PendingEdits.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        AppStorageLocation.support.appendingPathComponent("PendingEdits.json")
    }

    // MARK: - Recording

    /// Records the edits for `url`, or forgets them when `edits` is nil. `modificationDate` is only read
    /// for a new entry, so an entry keeps the date of the file it was first edited against.
    func set(_ edits: EditState?, for url: URL, modificationDate: @autoclosure () -> Date?) {
        let key = url.standardizedFileURL.path
        if let edits, let modDate = entries[key]?.modDate ?? modificationDate() {
            guard entries[key]?.edits != edits else { return }
            entries[key] = Entry(modDate: modDate, edits: edits)
        } else {
            guard entries.removeValue(forKey: key) != nil else { return }
        }
        scheduleSave()
    }

    /// Follows a rename (the content, and so the modification date, is unchanged).
    func move(from old: URL, to new: URL) {
        guard let entry = entries.removeValue(forKey: old.standardizedFileURL.path) else { return }
        entries[new.standardizedFileURL.path] = entry
        scheduleSave()
    }

    // MARK: - Restoring

    /// Edits for the images `folder` shows (direct children, or all descendants when `recursive`,
    /// limited to `restrictedTo` when given). Entries whose file changed or is gone are dropped.
    func restore(in folder: URL, recursive: Bool, restrictedTo: Set<URL>?) -> [URL: EditState] {
        let base = folder.standardizedFileURL.path + "/"
        var result: [URL: EditState] = [:]
        for (path, entry) in entries where path.hasPrefix(base) {
            if !recursive, path.dropFirst(base.count).contains("/") { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if let restrictedTo, !restrictedTo.contains(url) { continue }
            let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            var edits = entry.edits
            // Object masks come from a click-to-select session that's gone; subject masks are recomputed on demand.
            if case .object = edits.cutout { edits.removeCutout() }
            // A missing Extend fill is simply made again (same seed, same result).
            if let fill = edits.extendFill, !FileManager.default.fileExists(atPath: fill.path) { edits.extendFill = nil }
            if case .image(let picture) = edits.background, !FileManager.default.fileExists(atPath: picture) {
                edits.background = nil
                edits.matchLighting = nil
            }
            guard modDate == entry.modDate, !edits.isIdentity else {
                entries[path] = nil
                scheduleSave()
                continue
            }
            result[url] = edits
        }
        return result
    }

    /// Background pictures that pending edits draw behind cutouts.
    var backdropPaths: Set<String> {
        Set(entries.values.compactMap { entry in
            if case .image(let path) = entry.edits.background { path } else { nil }
        })
    }

    /// Extend fills that pending edits use.
    var extendFillPaths: Set<String> {
        Set(entries.values.compactMap { $0.edits.extendFill?.path })
    }

    // MARK: - Storage

    /// Writes pending changes now (at quit).
    func flush() {
        saveTask?.cancel()
        if isDirty { write() }
    }

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == 1 else { return [:] }
        return file.entries
    }

    private func write() {
        isDirty = false
        let fm = FileManager.default
        if entries.isEmpty {
            try? fm.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(File(entries: entries)) else { return }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension MaskStore {
    /// Masks aren't saved with pending edits, so a restored background removal recomputes its
    /// subject mask before rendering.
    nonisolated func prepare(_ edits: EditState, for decoded: DecodedImage) async throws {
        guard edits.cutout == .subject, subjectMask(for: decoded.url) == nil else { return }
        setSubjectMask(try await VisionServices.subjectMask(for: decoded.cgImage), for: decoded.url)
    }
}
