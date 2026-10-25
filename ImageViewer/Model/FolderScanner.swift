import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum FolderScanner {
    static let resourceKeys: [URLResourceKey] = [
        .contentTypeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
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
            source: ImageStacks.source(of: url)
        )
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
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
        case .size:
            sorted = items.sorted { ($0.fileSize, $0.name) < ($1.fileSize, $1.name) }
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

/// Watches a directory for changes (files added, removed, renamed) and calls back on the main actor.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounce: Task<Void, Never>?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func watch(_ folder: URL?) {
        stop()
        guard let folder else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleChange() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleChange() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        debounce?.cancel()
    }

    isolated deinit {
        stop()
    }
}
