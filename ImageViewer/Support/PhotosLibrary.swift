import CoreImage
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Photos from the library being edited here (File ▸ Open from Photos…). Each one is a working file in a
/// private folder, which everything else in the app treats like any file; this remembers which photo each
/// file stands for. Save hands the edit back to Photos as a Photos edit: revertible (Revert to Original), synced
/// by iCloud Photos, with the edit's settings attached so this app can pick them up again. A Live Photo stays
/// live: the edit is applied to every frame of its motion.
final class PhotosLibrary {
    static let shared = PhotosLibrary()

    /// What this app saves with an edit, so it can be opened again with the same settings.
    nonisolated static let formatIdentifier = "com.oneopa.AOK-ImageTool"
    nonisolated static let formatVersion = "1"

    struct Photo {
        let assetID: String
        let isLive: Bool
        /// The edit as it is in Photos (the settings last saved), if it was made here.
        var savedEdits: EditState?
    }

    enum Failure: LocalizedError {
        case notAllowed, notFound(String), unreadable, saveFailed

        var errorDescription: String? {
            switch self {
            case .notAllowed:
                "AOK-ImageTool isn't allowed to use your Photos library. You can allow it in System Settings ▸ Privacy & Security ▸ Photos."
            case .notFound(let name): "“\(name)” isn't in the Photos library any more."
            case .unreadable: "Photos couldn't provide the photo."
            case .saveFailed: "Photos didn't accept the edit."
            }
        }
    }

    private(set) var photos: [URL: Photo] = [:]

    /// Where working files live (in the caches: it's all in Photos).
    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(LegacyMigration.newID).appendingPathComponent("From Photos")
    }

    nonisolated static func isWorkingFile(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    func photo(for url: URL) -> Photo? { photos[url.standardizedFileURL] }

    #if DEBUG
    /// The self-test's stand-in for a photo opened from the library.
    func registerForTesting(_ url: URL, isLive: Bool, savedEdits: EditState?) {
        photos[url.standardizedFileURL] = Photo(assetID: "test", isLive: isLive, savedEdits: savedEdits)
    }
    #endif

    /// Working files from an earlier run (at launch: the photos are in Photos, edits not saved there are gone).
    nonisolated static func removeOldWorkingFiles() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Asks for access to the library, once.
    static func requestAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
    }

    // MARK: Opening

    struct Opened {
        let folder: URL
        let files: [URL]
        /// Settings of edits made here before, by working file.
        let edits: [URL: EditState]
    }

    /// Makes working files for these photos (downloading originals from iCloud if need be). A photo last
    /// edited here comes as its original with that edit's settings; any other, as it looks now.
    func open(assetIDs: [String], progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Opened {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        let session = Self.folder.appendingPathComponent(UUID().uuidString.prefix(8).description)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        var files: [URL] = []
        var edits: [URL: EditState] = [:]
        for (i, id) in assetIDs.enumerated() {
            progress(i, assetIDs.count)
            guard let asset = byID[id] else { continue }
            let input = try await Self.editingInput(for: asset)
            guard let source = input.fullSizeImageURL else { throw Failure.unreadable }
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? source.lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let file = ImageWriter.uniqueURL(in: session, baseName: stem.isEmpty ? "Photo" : stem, ext: source.pathExtension)
            try Self.copy(source, to: file, orientation: input.fullSizeImageOrientation)
            let saved = Self.edits(from: input.adjustmentData)
            let url = file.standardizedFileURL
            photos[url] = Photo(assetID: id, isLive: asset.mediaSubtypes.contains(.photoLive), savedEdits: saved)
            if let saved { edits[url] = saved }
            files.append(url)
        }
        return Opened(folder: session.standardizedFileURL, files: files, edits: edits)
    }

    // MARK: Importing

    /// Copies these photos out of the library into `folder` as ordinary files (File ▸ Import from Photos…):
    /// each as it looks now (its edited version if it's been edited in Photos, else its original), with its own
    /// name and its date taken as the file's date. A Live Photo comes as its still. Originals are downloaded
    /// from iCloud if need be.
    func importPhotos(_ assetIDs: [String], into folder: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [URL] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        var made: [URL] = []
        for (i, id) in assetIDs.enumerated() {
            progress(i, assetIDs.count)
            guard let asset = byID[id] else { continue }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let original = resources.first(where: { $0.type == .photo }) ?? resources.first(where: { $0.type != .pairedVideo }) else { continue }
            let current = resources.first(where: { $0.type == .fullSizePhoto }) ?? original
            let stem = (original.originalFilename as NSString).deletingPathExtension
            var ext = (current.originalFilename as NSString).pathExtension
            if ext.isEmpty { ext = UTType(current.uniformTypeIdentifier)?.preferredFilenameExtension ?? "heic" }
            let dest = ImageWriter.uniqueURL(in: folder, baseName: stem.isEmpty ? "Photo" : stem, ext: ext)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PHAssetResourceManager.default().writeData(for: current, toFile: dest, options: options)
            if let date = asset.creationDate {
                try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: dest.path)
            }
            made.append(dest)
        }
        return made
    }

    private static func editingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // (Only when the files the edit refers to are still here, e.g. not on another Mac: else Photos hands over
        // the photo as it looks now, to edit further.)
        options.canHandleAdjustmentData = { edits(from: $0)?.referencedFilesExist == true }
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? Failure.unreadable)
                }
            }
        }
    }

    /// Copies Photos' file, making sure it carries the orientation Photos says it has (it isn't always in the file).
    private static func copy(_ source: URL, to file: URL, orientation: Int32) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(src) else {
            try FileManager.default.copyItem(at: source, to: file)
            return
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let current = (props?[kCGImagePropertyOrientation] as? Int32) ?? 1
        guard current != orientation, let dest = CGImageDestinationCreateWithURL(file as CFURL, type, 1, nil) else {
            try FileManager.default.copyItem(at: source, to: file)
            return
        }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, [kCGImageDestinationOrientation: orientation] as CFDictionary, &error) else {
            try FileManager.default.copyItem(at: source, to: file)
            return
        }
    }

    nonisolated static func edits(from data: PHAdjustmentData?) -> EditState? {
        guard let data, data.formatIdentifier == formatIdentifier, data.formatVersion == formatVersion else { return nil }
        return try? JSONDecoder().decode(EditState.self, from: data.data)
    }

    // MARK: Saving

    /// Hands `edits` of the working file `url` (decoded as `decoded`) to Photos as the photo's edit. For a Live
    /// Photo, with `still` false, the edit is applied to every frame of its motion as well.
    func save(_ url: URL, decoded: DecodedImage, edits: EditState, keepLive: Bool) async throws {
        guard let photo = photo(for: url) else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.assetID], options: nil).firstObject else {
            throw Failure.notFound(url.lastPathComponent)
        }
        let input = try await Self.editingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: Self.formatIdentifier, formatVersion: Self.formatVersion,
                                                 data: try JSONEncoder().encode(edits))
        if photo.isLive && keepLive {
            try await Self.renderLive(input: input, output: output, edits: edits, still: decoded)
        } else {
            try await Task.detached(priority: .userInitiated) {
                try await MaskStore.shared.prepare(edits, for: decoded)
                guard let rendered = EditRenderer.shared.renderSync(decoded, edits: edits, maxDimension: nil) else {
                    throw ImageWriteError.finalizeFailed
                }
                let type = output.supportedRenderedContentTypes.contains(.heic) ? UTType.heic : UTType.jpeg
                let file = try output.renderedContentURL(for: type)
                try ImageWriter.write(rendered.image, to: file, format: type == .heic ? .heic : .jpeg, quality: 0.93,
                                      sourceProperties: decoded.properties, metadata: .keepAll)
            }.value
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
        photos[url.standardizedFileURL]?.savedEdits = edits
        Self.keepFiles(of: edits)
    }

    /// Files in Application Support (backgrounds, Extend fills, removal patches) that edits saved to Photos refer
    /// to: kept when those stores are cleaned up at launch, so the edits open with their settings again.
    nonisolated static var keptFiles: Set<String> { Set(UserDefaults.standard.stringArray(forKey: PrefKey.photosEditFiles) ?? []) }

    nonisolated static func keepFiles(of e: EditState) {
        var paths = e.removals?.map(\.path) ?? []
        if let path = e.extendFill?.path { paths.append(path) }
        if case .image(let path) = e.background { paths.append(path) }
        guard !paths.isEmpty else { return }
        Prefs.set(keptFiles.union(paths).sorted(), PrefKey.photosEditFiles)
    }

    /// Takes this app's edit off the photo in Photos (all of its edits were removed here).
    func revertToOriginal(_ url: URL) async throws {
        guard let photo = photo(for: url) else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.assetID], options: nil).firstObject else {
            throw Failure.notFound(url.lastPathComponent)
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
        }
        photos[url.standardizedFileURL]?.savedEdits = nil
    }

    /// Every frame of the Live Photo (and its still) through the edits that hold for every frame.
    private static func renderLive(input: PHContentEditingInput, output: PHContentEditingOutput, edits: EditState,
                                   still: DecodedImage) async throws {
        guard let context = PHLivePhotoEditingContext(livePhotoEditingInput: input) else { throw Failure.unreadable }
        let orientation = context.orientation
        let upright = Self.inverse(orientation)
        context.frameProcessor = { frame, _ in
            let image = frame.image.oriented(orientation)
            let edited = EditRenderer.shared.applyToFrame(image, edits: edits, still: still, renderScale: frame.renderScale)
            return edited.oriented(upright)
        }
        try await context.saveLivePhoto(to: output)
    }

    /// The orientation that undoes `o`.
    nonisolated static func inverse(_ o: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch o {
        case .right: .left
        case .left: .right
        default: o   // the rest undo themselves
        }
    }

    /// Edits a Live Photo's motion can't take: they're for one picture (a cutout, a background, Extend,
    /// removed objects).
    nonisolated static func stillOnly(_ e: EditState) -> Bool {
        e.cutout != nil || e.background != nil || e.cropExtendsBeyondImage || e.removals != nil
    }
}
