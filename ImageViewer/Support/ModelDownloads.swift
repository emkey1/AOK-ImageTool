import AppKit
import CryptoKit
import Foundation

/// A model the app can download: zip archives in the app's GitHub "Models" release, each checked against
/// the SHA-256 recorded here before it's unpacked and installed.
nonisolated struct DownloadableModel: Identifiable, Sendable {
    struct Archive: Sendable {
        let file: String
        let size: Int64
        let sha256: String
    }

    let id: String
    /// What it's for, as in “Download the colorizing model?”.
    let purpose: String
    let modelName: String
    let licenseName: String
    let licenseURL: URL
    /// The license limits how the model may be used, so downloading it means accepting it.
    let licenseRestrictsUse: Bool
    let archives: [Archive]
    let install: @Sendable (URL) throws -> Void
    let isInstalled: @Sendable () -> Bool

    var downloadSize: Int64 { archives.reduce(0) { $0 + $1.size } }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: downloadSize, countStyle: .file) }

    static let release: URL = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["AOK_MODELS_URL"] { return URL(string: override)! }
        #endif
        return URL(string: "https://github.com/emkey1/AOK-ImageTool/releases/download/models-1/")!
    }()

    static let generativeFill = DownloadableModel(
        id: "generative-fill",
        purpose: "generative fill",
        modelName: GenerativeModel.displayName,
        licenseName: "CreativeML Open RAIL-M",
        licenseURL: URL(string: "https://huggingface.co/spaces/CompVis/stable-diffusion-license")!,
        licenseRestrictsUse: true,
        archives: [
            Archive(file: "AOK-SD15-Inpainting-Unet.zip", size: 1_592_904_546,
                    sha256: "f88ce70f0e416c7c499a2222f634cdaf9fa3a0f0bbd0f0e5e5e33516d93074ad"),
            Archive(file: "AOK-SD15-Inpainting-Other.zip", size: 382_784_091,
                    sha256: "607438d6813644402f7391de3ddbc6fdc23c24ae83e80538f44a70fdbdadfb1f"),
        ],
        install: { try GenerativeModel.install(from: $0) },
        isInstalled: { GenerativeModel.isInstalled }
    )

    static let colorize = DownloadableModel(
        id: "colorize",
        purpose: "colorizing",
        modelName: "DDColor",
        licenseName: "Apache 2.0",
        licenseURL: URL(string: "https://github.com/piddnad/DDColor/blob/master/LICENSE")!,
        licenseRestrictsUse: false,
        archives: [
            Archive(file: "AOK-DDColor.zip", size: 424_567_146,
                    sha256: "084893865fb85122a3b98917c7474e0658e4621602563d9535a49d1323e69aa3"),
        ],
        install: { try Colorizer.install(from: $0) },
        isInstalled: { Colorizer.isInstalled }
    )

    static let removal = DownloadableModel(
        id: "remove-objects",
        purpose: "object removal",
        modelName: RemovalModel.displayName,
        licenseName: "Apache 2.0",
        licenseURL: URL(string: "https://github.com/advimman/lama/blob/main/LICENSE")!,
        licenseRestrictsUse: false,
        archives: [
            Archive(file: "AOK-LaMa.zip", size: 189_909_991,
                    sha256: "82cdcbb438e021327a5bafddf76cd5f03e5ea763ff00fa93337a13fe3d9267b2"),
        ],
        install: { try RemovalModel.install(from: $0) },
        isInstalled: { RemovalModel.isInstalled }
    )
}

/// A model installed as a single compiled Core ML model (.mlmodelc) in its own folder.
nonisolated enum InstalledModel {
    /// Installs `modelName`: the .mlmodelc itself or a folder holding it. It's copied next to the installed one
    /// first and swapped in, so a failed copy leaves the old one (and choosing the installed one itself changes
    /// nothing). `unload` lets go of a loaded copy first.
    static func install(_ modelName: String, from source: URL, into directory: URL, unload: () -> Void) throws {
        let model = (source.lastPathComponent == modelName ? source : source.appendingPathComponent(modelName)).standardizedFileURL
        guard FileManager.default.fileExists(atPath: model.path) else { throw GenerativeModel.InstallError.notAModel }
        let fm = FileManager.default
        let dest = directory.appendingPathComponent(modelName).standardizedFileURL
        guard model != dest else { return }
        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".installing-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: model, to: staging.appendingPathComponent(modelName))
            unload()
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            try fm.moveItem(at: staging, to: directory)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func size(of directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

enum ModelDownloadError: LocalizedError {
    case badResponse(Int)
    case corrupt(String)
    case noRoom(Int64)
    case unpackFailed(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status): "The server answered \(status)."
        case .corrupt(let file): "“\(file)” didn't download correctly (its checksum doesn't match). Try again."
        case .noRoom(let needed): "There isn't enough free space: the download needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))."
        case .unpackFailed(let file): "“\(file)” couldn't be unpacked."
        }
    }
}

/// Model downloads in progress, shared by Settings and the prompts that offer a download.
@Observable
final class ModelDownloads {
    static let shared = ModelDownloads()

    enum Status: Equatable {
        case downloading(Double)
        case installing
    }

    private(set) var status: [String: Status] = [:]
    /// Why the last attempt failed, by model.
    private(set) var failure: [String: String] = [:]
    /// Bumped when a model finishes installing, for views that cache whether one is installed.
    private(set) var installCount = 0
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiting: [String: [() -> Void]] = [:]

    /// Downloads and installs `model`; `then` runs once it's installed.
    func start(_ model: DownloadableModel, then: (() -> Void)? = nil) {
        if let then { waiting[model.id, default: []].append(then) }
        guard tasks[model.id] == nil else { return }
        failure[model.id] = nil
        status[model.id] = .downloading(0)
        let id = model.id
        tasks[id] = Task {
            do {
                try await Self.fetch(model, progress: { fraction in
                    Task { @MainActor in
                        if case .downloading = ModelDownloads.shared.status[id] { ModelDownloads.shared.status[id] = .downloading(fraction) }
                    }
                }, installing: {
                    // (Queued: it may run after the job has finished, when there's nothing to show.)
                    Task { @MainActor in if ModelDownloads.shared.status[id] != nil { ModelDownloads.shared.status[id] = .installing } }
                })
                status[id] = nil
                installCount += 1
                for action in waiting.removeValue(forKey: id) ?? [] { action() }
            } catch {
                status[id] = nil
                waiting[id] = nil
                if !Task.isCancelled && (error as? URLError)?.code != .cancelled { failure[id] = error.localizedDescription }
            }
            tasks[id] = nil
        }
    }

    func cancel(_ model: DownloadableModel) {
        tasks[model.id]?.cancel()
    }

    /// What an interrupted download or install leaves in the models folder (at launch, when none can be running).
    static func removeLeftovers() {
        let folder = AppStorageLocation.models
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".download-") || name.hasPrefix(".installing-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Off the main actor: it hashes and unpacks gigabytes.
    @concurrent private nonisolated static func fetch(_ model: DownloadableModel, progress: @escaping @Sendable (Double) -> Void,
                                          installing: @escaping @Sendable () -> Void) async throws {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let needed = model.downloadSize * 3    // the archives, what they unpack to, and the installed copy
        if let free = try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw ModelDownloadError.noRoom(needed)
        }
        try fm.createDirectory(at: AppStorageLocation.models, withIntermediateDirectories: true)
        let work = AppStorageLocation.models.appendingPathComponent(".download-\(model.id)")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let unpacked = work.appendingPathComponent("unpacked")
        let total = Double(max(model.downloadSize, 1))
        var done: Int64 = 0
        for archive in model.archives {
            let zip = work.appendingPathComponent(archive.file)
            let before = done
            try await FileDownload.run(DownloadableModel.release.appendingPathComponent(archive.file), to: zip) { written in
                progress(min(1, Double(before + written) / total))
            }
            try Task.checkCancellation()
            guard try sha256(of: zip) == archive.sha256 else { throw ModelDownloadError.corrupt(archive.file) }
            try unzip(zip, into: unpacked)
            try fm.removeItem(at: zip)
            done += archive.size
        }
        try Task.checkCancellation()
        installing()
        try model.install(unpacked)
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 16 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func unzip(_ zip: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModelDownloadError.unpackFailed(zip.lastPathComponent) }
    }
}

/// One file downloaded to `destination`, reporting the bytes written so far.
nonisolated private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var reported: Int64 = 0

    private init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func run(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let download = FileDownload(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: url)
                download.lock.withLock {
                    download.continuation = continuation
                    download.task = task
                }
                if download.lock.withLock({ download.cancelled }) { task.cancel() } else { task.resume() }
            }
        } onCancel: {
            download.lock.withLock {
                download.cancelled = true
                return download.task
            }?.cancel()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // About every 4 MB is plenty for a progress bar.
        guard totalBytesWritten - reported >= 4 << 20 else { return }
        reported = totalBytesWritten
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return finish(.failure(ModelDownloadError.badResponse(status))) }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

extension ViewerModel {
    /// Asks before downloading `model` (once), shows its progress, and runs `then` once it's installed.
    func offerDownload(_ model: DownloadableModel, then: @escaping () -> Void) {
        guard GenerativeModel.isSupported else {
            alert = AlertInfo(title: "This needs a Mac with Apple silicon", message: "The \(model.purpose) model runs on Apple silicon only.")
            return
        }
        if model.isInstalled() { return then() }
        let downloads = ModelDownloads.shared
        if downloads.status[model.id] != nil {
            downloads.start(model, then: then)
            return showDownloadProgress(model)
        }
        let alert = NSAlert()
        alert.messageText = "Download the \(model.purpose) model?"
        alert.informativeText = "This uses \(model.modelName), which runs on this Mac. It's a one-time download of \(model.formattedSize). "
            + (model.licenseRestrictsUse
               ? "By downloading it you accept its license, \(model.licenseName), including the uses it doesn't allow."
               : "Its license is \(model.licenseName).")
        alert.addButton(withTitle: model.licenseRestrictsUse ? "Accept and Download" : "Download")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "View License")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                downloads.start(model, then: then)
                self?.showDownloadProgress(model)
            case .alertThirdButtonReturn:
                NSWorkspace.shared.open(model.licenseURL)
            default:
                break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    private func showDownloadProgress(_ model: DownloadableModel) {
        Task {
            let downloads = ModelDownloads.shared
            while let status = downloads.status[model.id] {
                switch status {
                case .downloading(let fraction):
                    showToast("Downloading the \(model.purpose) model… \(Int(fraction * 100))%", systemImage: "arrow.down.circle")
                case .installing:
                    showToast("Installing the \(model.purpose) model…", systemImage: "arrow.down.circle")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let failure = downloads.failure[model.id] {
                dismissToast()
                alert = AlertInfo(title: "Couldn't download the \(model.purpose) model", message: failure)
            } else if model.isInstalled() {
                showToast("The \(model.purpose) model is ready", systemImage: "checkmark.circle")
            } else {
                dismissToast()
            }
        }
    }
}
