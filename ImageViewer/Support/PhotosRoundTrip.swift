import Foundation
import Photos

/// Photos' Image ▸ Edit With: Photos hands this app a copy of a photo inside its library package and takes
/// whatever is saved back to that file as an edit of the photo. It's non-destructive (Revert to Original in
/// Photos undoes it), and iCloud Photos carries it to the other devices.
nonisolated enum PhotosRoundTrip {
    enum Failure: LocalizedError {
        case notAllowed

        var errorDescription: String? {
            "AOK-ImageTool isn't allowed to add to your Photos library. You can allow it in System Settings ▸ Privacy & Security ▸ Photos."
        }
    }

    /// The file is one Photos is having edited (it's inside a Photos library).
    static func isFromPhotos(_ url: URL) -> Bool {
        url.path.contains(".photoslibrary/")
    }

    /// Where copies made from such a photo are written before they're added to Photos (not inside its library).
    static var copiesFolder: URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOK-ImageTool Copies for Photos")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    #if DEBUG
    /// The self-test's stand-in for the library, so it never adds to the user's.
    nonisolated(unsafe) static var addForTesting: ((URL) throws -> Void)?
    #endif

    /// Adds `file` (a copy made from a photo from Photos) to the Photos library as a new photo, and removes the
    /// file. Asks once for permission to add, the only access it needs.
    static func add(_ file: URL) async throws {
        #if DEBUG
        if let addForTesting { return try addForTesting(file) }
        #endif
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            options.originalFilename = file.lastPathComponent
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: options)
        }
    }
}
