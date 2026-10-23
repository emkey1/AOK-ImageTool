import Foundation

/// Copies made from an image (upscaled, colorized, black and white, from Image Playground, exported next to it)
/// stack with it in the filmstrip and grid: the newest copy on top, the original at the bottom. A copy names
/// the file it was made from in an extended attribute; copies without one (made before it existed, or whose
/// attribute was lost on the way) are recognized by the names this app gives them, like "Beach (Colorized).heic".
nonisolated enum ImageStacks {
    static let attribute = "com.oneopa.AOK-ImageTool.source"

    /// Records that `copy` was made from `original`, by name (a stack lives in one folder).
    static func markDerived(_ copy: URL, from original: URL) {
        guard copy.deletingLastPathComponent().standardizedFileURL == original.deletingLastPathComponent().standardizedFileURL
        else { return }
        setSource(original.lastPathComponent, of: copy)
    }

    /// Records the name of the file `copy` was made from.
    static func setSource(_ name: String, of copy: URL) {
        let bytes = Array(name.utf8)
        _ = bytes.withUnsafeBytes { setxattr(copy.path, attribute, $0.baseAddress, $0.count, 0, 0) }
    }

    /// The name of the file `url` was made from, if it records one.
    static func source(of url: URL) -> String? {
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0, size < 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, attribute, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// "Beach (Colorized)" or "Beach (2×) 2" → "Beach": the names this app gives its copies.
    static func sourceStem(fromName stem: String) -> String? {
        (try? #/(.+) \((?:Colorized|Black & White|Sharpened|Cropped|Extended|Retouched|Playground|\d+×)\)(?: \d+)?/#.wholeMatch(in: stem)).map { String($0.1) }
    }

    /// What each copy among `items` was made from (when that's among them too).
    static func parents(_ items: [ImageItem]) -> [URL: URL] {
        var byName: [String: URL] = [:]
        var byStem: [String: [URL]] = [:]
        for item in items {
            let folder = item.url.deletingLastPathComponent().path
            byName[folder + "/" + item.url.lastPathComponent] = item.url
            byStem[folder + "/" + item.url.deletingPathExtension().lastPathComponent, default: []].append(item.url)
        }
        var parents: [URL: URL] = [:]
        for item in items {
            let folder = item.url.deletingLastPathComponent().path
            if let source = item.source, let parent = byName[folder + "/" + source], parent != item.url {
                parents[item.url] = parent
            } else if let stem = sourceStem(fromName: item.url.deletingPathExtension().lastPathComponent),
                      let candidates = byStem[folder + "/" + stem] {
                let sameKind = candidates.first { $0.pathExtension == item.url.pathExtension }
                parents[item.url] = sameKind ?? candidates.min { $0.path < $1.path }
            }
        }
        return parents
    }

    /// The stacks among `items`, each by its bottom (the original), with its members newest copy first and the
    /// original last. Items that aren't in a stack aren't included.
    static func stacks(_ items: [ImageItem]) -> [URL: [ImageItem]] {
        let parents = parents(items)
        guard !parents.isEmpty else { return [:] }
        func root(_ url: URL) -> URL {
            var root = url, seen: Set<URL> = [url]
            while let p = parents[root], seen.insert(p).inserted { root = p }
            return root
        }
        let originals = Set(parents.values)
        var stacks: [URL: [ImageItem]] = [:]
        for item in items {
            let r = root(item.url)
            if r != item.url || originals.contains(item.url) { stacks[r, default: []].append(item) }
        }
        for (r, members) in stacks {
            stacks[r] = members.sorted { a, b in
                if (a.url == r) != (b.url == r) { return b.url == r }
                let da = a.creationDate ?? a.modificationDate ?? .distantPast
                let db = b.creationDate ?? b.modificationDate ?? .distantPast
                return da != db ? da > db : a.name.localizedStandardCompare(b.name) == .orderedDescending
            }
        }
        return stacks.filter { $0.value.count > 1 }
    }
}
