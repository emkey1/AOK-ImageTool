import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum FolderScanner {
    static let resourceKeys: [URLResourceKey] = [
        .contentTypeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey,
        .isHiddenKey, .isDirectoryKey, .isPackageKey, .labelNumberKey, .isRegularFileKey,
    ]

    static let maxRecursiveItems = 50_000

    static func scan(folder: URL, recursive: Bool, showHidden: Bool) throws -> [ImageItem] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }

        var results: [ImageItem] = []
        if recursive {
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: resourceKeys, options: options) else {
                return []
            }
            for case let url as URL in enumerator {
                if let item = item(for: url) { results.append(item) }
                if results.count >= maxRecursiveItems { break }
            }
        } else {
            options.insert(.skipsSubdirectoryDescendants)
            let urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: resourceKeys, options: options)
            results = urls.compactMap(item(for:))
        }
        return results
    }

    static func item(for rawURL: URL) -> ImageItem? {
        // One canonical form for every URL in the app (e.g. "/private/tmp" vs "/tmp"), so lookups match.
        let url = rawURL.standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        if values.isDirectory == true && values.isPackage != true { return nil }
        guard values.isRegularFile == true, SupportedFormats.isSupported(values.contentType) else { return nil }
        return ImageItem(
            url: url,
            name: url.lastPathComponent,
            contentType: values.contentType,
            fileSize: Int64(values.fileSize ?? 0),
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            flag: Flag(labelNumber: values.labelNumber),
            dateTaken: nil,
            source: ImageStacks.source(of: url),
            dateAdded: values.addedToDirectoryDate
        )
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Width × height, from the header (upright or not, the same). Cheap.
    static func pixelCount(for url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return w * h
    }

    /// Reads the EXIF capture date (falls back to nil). Header-only read; cheap.
    static func dateTaken(for url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String
        return raw.flatMap(MetadataFormatting.exifDate)
    }

    static func sort(_ items: [ImageItem], by key: SortKey, ascending: Bool, scores: [URL: Float] = [:]) -> [ImageItem] {
        var sorted: [ImageItem]
        switch key {
        case .name:
            sorted = items.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        case .dateModified:
            sorted = items.sorted { ($0.modificationDate ?? .distantPast, $0.name) < ($1.modificationDate ?? .distantPast, $1.name) }
        case .dateCreated:
            sorted = items.sorted { ($0.creationDate ?? .distantPast, $0.name) < ($1.creationDate ?? .distantPast, $1.name) }
        case .dateTaken:
            sorted = items.sorted {
                ($0.dateTaken ?? $0.creationDate ?? .distantPast, $0.name) < ($1.dateTaken ?? $1.creationDate ?? .distantPast, $1.name)
            }
        case .dateAdded:
            sorted = items.sorted {
                ($0.dateAdded ?? $0.creationDate ?? .distantPast, $0.name) < ($1.dateAdded ?? $1.creationDate ?? .distantPast, $1.name)
            }
        case .size:
            sorted = items.sorted { ($0.fileSize, $0.name) < ($1.fileSize, $1.name) }
        case .dimensions:
            sorted = items.sorted { ($0.pixelCount ?? 0, $0.name) < ($1.pixelCount ?? 0, $1.name) }
        case .kind:
            sorted = items.sorted { ($0.kindDescription, $0.name) < ($1.kindDescription, $1.name) }
        case .rating:
            // (Best first, like Best Shots.)
            sorted = items.sorted { ($0.rating ?? 0, $1.name) > ($1.rating ?? 0, $0.name) }
        case .quality:
            // Highest score first when "ascending" is off feels backwards; treat ascending as best-first.
            sorted = items.sorted { (scores[$0.url] ?? -2) > (scores[$1.url] ?? -2) }
        case .random:
            return items.shuffled()
        }
        return ascending ? sorted : sorted.reversed()
    }
}

/// Watches a folder for pictures added, taken away, renamed or written to by anything (Finder, an export, a
/// download, this app), in its subfolders too when those are shown, and calls back on the main actor a moment
/// after.
///
/// (With the file system's own record of changes, not a watch on the folder itself: that says nothing of what
/// happens in a subfolder, so pictures dropped into one never showed up, nor of a file that's finished being
/// written, so one listed while it was arriving stayed half a picture.)
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var watching: (path: String, subfolders: Bool, hidden: Bool)?
    private var generation = 0
    private var debounce: Task<Void, Never>?
    private var waitingSince: ContinuousClock.Instant?
    private var lastCall: ContinuousClock.Instant?
    private let onChange: () -> Void
    /// The least time from one call to the next: a folder that takes long to read isn't read over and over
    /// while something keeps writing in it.
    var spacing: Duration = .zero

    private static let queue = DispatchQueue(label: "com.oneopa.AOK-ImageTool.folder-watcher", qos: .utility)

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Watches `folder` (nil: nothing), with what's in its subfolders and hidden files when those are shown.
    /// Asked again for what's already watched, it carries on.
    func watch(_ folder: URL?, subfolders: Bool = false, hidden: Bool = false) {
        guard let folder else { return stop() }
        if let watching, watching == (folder.path, subfolders, hidden), stream != nil { return }
        stop()
        // (Changes are told by the folder's real path: "/private/tmp/…", whatever it was opened as.)
        guard let real = realpath(folder.path, nil) else { return }
        let filter = Filter(root: String(cString: real), subfolders: subfolders, hidden: hidden)
        free(real)
        generation += 1
        let mine = generation
        filter.changed = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // (Not a last word from the folder watched before.)
                    guard let self, self.generation == mine else { return }
                    self.scheduleChange()
                }
            }
        }
        // (The stream keeps the filter, and lets go of it when it goes itself.)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(filter).toOpaque(), retain: nil, release: Filter.release,
                                           copyDescription: nil)
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
        guard let made = FSEventStreamCreate(nil, Filter.callback, &context, [filter.root] as CFArray,
                                             FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, FSEventStreamCreateFlags(flags)) else {
            Unmanaged.passUnretained(filter).release()
            return
        }
        FSEventStreamSetDispatchQueue(made, Self.queue)
        guard FSEventStreamStart(made) else {
            FSEventStreamInvalidate(made)
            FSEventStreamRelease(made)
            return
        }
        stream = made
        watching = (folder.path, subfolders, hidden)
    }

    private func scheduleChange() {
        let now = ContinuousClock.now
        let since = waitingSince ?? now
        waitingSince = since
        // A moment after the last change, so a burst of them is read once; but within a second and a half of
        // the first, since something may go on writing for minutes.
        var at = min(now + .milliseconds(300), since + .milliseconds(1500))
        if let lastCall { at = max(at, lastCall + spacing) }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(until: at, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.waitingSince = nil
            self.lastCall = .now
            self.onChange()
        }
    }

    func stop() {
        if let stream {
            // (On its own queue: never while it's telling of a change there.)
            Self.queue.async {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
        stream = nil
        watching = nil
        generation += 1
        debounce?.cancel()
        waitingSince = nil
    }

    isolated deinit {
        stop()
    }

    /// Which changes are worth reading the folder again for: to pictures and folders that are listed. Not to
    /// other files (a download in progress, `.DS_Store`), nor to what's inside a package or a hidden folder (a
    /// Photos library syncing, `~/Library`), which would have a big folder read again and again for nothing.
    nonisolated final class Filter: @unchecked Sendable {
        let root: String
        private let subfolders: Bool
        private let hidden: Bool
        /// (Set once, before the stream starts.)
        var changed: @Sendable () -> Void = {}
        // (Only on the watcher's queue.)
        private var skipped: [String: Bool] = [:]
        private var pictures: [String: Bool] = [:]

        init(root: String, subfolders: Bool, hidden: Bool) {
            self.root = root
            self.subfolders = subfolders
            self.hidden = hidden
        }

        static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
            let filter = Unmanaged<Filter>.fromOpaque(info).takeUnretainedValue()
            for i in 0..<min(count, paths.count) where filter.concerns(paths[i], flags[i]) { return filter.changed() }
        }

        static let release: CFAllocatorReleaseCallBack = { info in
            if let info { Unmanaged<Filter>.fromOpaque(info).release() }
        }

        func concerns(_ path: String, _ flags: FSEventStreamEventFlags) -> Bool {
            let flags = Int(flags)
            // Changes lost count of, or the folder itself moved or gone: read it again.
            if flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                        | kFSEventStreamEventFlagRootChanged) != 0 { return true }
            // (Not a change of tags, permissions or the like alone.)
            guard flags & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
                           | kFSEventStreamEventFlagItemModified) != 0 else { return false }
            guard path.count > root.count + 1, path.range(of: root + "/", options: [.anchored, .caseInsensitive]) != nil else { return false }
            var parts = path.dropFirst(root.count + 1).split(separator: "/")
            guard let name = parts.popLast() else { return false }
            if !subfolders, !parts.isEmpty { return false }
            if !hidden, name.hasPrefix(".") || parts.contains(where: { $0.hasPrefix(".") }) { return false }
            var folder = root
            for part in parts {
                folder += "/" + part
                if isSkipped(folder) { return false }
            }
            // A folder made, moved in or out, or renamed: its pictures with it.
            if flags & kFSEventStreamEventFlagItemIsDir != 0 { return subfolders }
            return isPicture((String(name) as NSString).pathExtension.lowercased())
        }

        /// A package, or a hidden folder when hidden files aren't shown: what's in it isn't listed.
        private func isSkipped(_ folder: String) -> Bool {
            if let known = skipped[folder] { return known }
            let values = try? URL(fileURLWithPath: folder, isDirectory: true).resourceValues(forKeys: [.isPackageKey, .isHiddenKey])
            let skip = values?.isPackage == true || (!hidden && values?.isHidden == true)
            if skipped.count > 4096 { skipped.removeAll() }
            // (One that's gone can't be asked: not remembered, in case it comes back as something else.)
            if values != nil { skipped[folder] = skip }
            return skip
        }

        private func isPicture(_ ext: String) -> Bool {
            if let known = pictures[ext] { return known }
            let known = !ext.isEmpty && SupportedFormats.isSupported(UTType(filenameExtension: ext))
            pictures[ext] = known
            return known
        }
    }
}
