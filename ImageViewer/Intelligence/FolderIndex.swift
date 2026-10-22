import CryptoKit
import Foundation
import NaturalLanguage

/// Per-image analysis cached on disk so a folder only has to be analyzed once.
nonisolated struct IndexEntry: Codable, Sendable {
    var modDate: Date?
    var labels: [String] = []
    var text: String = ""
    var score: Float?
    var isUtility: Bool?
    var featurePrint: Data?
    var description: ImageDescription?
    /// True once the Vision pass (labels, OCR, quality, feature print) has run.
    var analyzed = false

    /// Lowercased text searched by the content search field.
    func searchBlob(fileName: String) -> String {
        var parts = [fileName, labels.joined(separator: " "), text]
        if let d = description {
            parts += [d.title, d.caption, d.keywords.joined(separator: " ")]
        }
        return parts.joined(separator: " ").lowercased()
    }
}

nonisolated enum FolderIndexStore {
    private struct File: Codable {
        var version = 2
        var entries: [String: IndexEntry]
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ImageViewer").appendingPathComponent("Index")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    /// Entries keyed by path relative to `folder`.
    static func load(folder: URL) -> [String: IndexEntry] {
        guard let data = try? Data(contentsOf: fileURL(for: folder)),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == 2 else { return [:] }
        return file.entries
    }

    static func save(_ entries: [String: IndexEntry], folder: URL) {
        guard let data = try? JSONEncoder().encode(File(entries: entries)) else { return }
        try? data.write(to: fileURL(for: folder), options: .atomic)
    }

    static func relativeKey(_ url: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// Expands search words with close neighbors from the system word embedding ("puppy" also finds "dog").
nonisolated final class QueryExpander: @unchecked Sendable {
    static let shared = QueryExpander()
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]
    private let embedding = NLEmbedding.wordEmbedding(for: .english)

    func variants(of word: String) -> [String] {
        if let hit = lock.withLock({ cache[word] }) { return hit }
        var result = [word]
        if word.count >= 3, let embedding {
            let neighbors = embedding.neighbors(for: word, maximumCount: 5)
            result += neighbors.filter { $0.1 < 0.86 }.map { $0.0.lowercased() }
        }
        lock.withLock { cache[word] = result }
        return result
    }
}
