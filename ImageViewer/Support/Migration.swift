import Foundation

/// AOK-ImageTool was first built as "ImageViewer" (bundle ID com.oneopa.ImageViewer). The first time this one
/// runs, that copy's settings, unsaved edits, installed models and caches move over.
nonisolated enum LegacyMigration {
    static let oldID = "com.oneopa.ImageViewer"
    static let newID = "com.oneopa.AOK-ImageTool"
    private static let doneKey = "migratedFromImageViewer"

    static func runIfNeeded() {
        guard Bundle.main.bundleIdentifier == newID, !AppStorageLocation.isIsolated else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        if let old = defaults.persistentDomain(forName: oldID) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        let fm = FileManager.default
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            let base = fm.urls(for: directory, in: .userDomainMask)[0]
            merge(base.appendingPathComponent(oldID), into: base.appendingPathComponent(newID))
        }
        // Pending edits refer to their backgrounds and fills by path.
        let pending = AppStorageLocation.support.appendingPathComponent("PendingEdits.json")
        if let text = try? String(contentsOf: pending, encoding: .utf8) {
            let escapedOld = "\\/\(oldID)\\/", escapedNew = "\\/\(newID)\\/"
            let moved = text
                .replacingOccurrences(of: escapedOld, with: escapedNew)
                .replacingOccurrences(of: "/\(oldID)/", with: "/\(newID)/")
            if moved != text { try? moved.write(to: pending, atomically: true, encoding: .utf8) }
        }
        defaults.set(true, forKey: doneKey)
    }

    /// Moves `old` to `new`, or, when both exist, whatever `new` doesn't have yet.
    private static func merge(_ old: URL, into new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        guard fm.fileExists(atPath: new.path) else {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: new)
            return
        }
        for child in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
            let dest = new.appendingPathComponent(child.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: child, to: dest)
            } else if FolderScanner.isDirectory(child), FolderScanner.isDirectory(dest) {
                merge(child, into: dest)
            }
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
    }
}
