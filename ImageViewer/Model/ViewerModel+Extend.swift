import CoreGraphics
import Foundation

/// Lets a C callback (on a background thread) ask whether the Swift task was cancelled.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A weak reference to a model that background callbacks can carry; only dereferenced on the main actor.
nonisolated final class ModelRelay: @unchecked Sendable {
    @MainActor weak var model: ViewerModel?
    @MainActor init(_ model: ViewerModel) { self.model = model }
}

extension ViewerModel {
    /// Extend needs an opaque image: see-through areas would be "continued" as black.
    /// (Not `canEdit`: that's false while the Crop tool, where Extend is turned on, is open.)
    var canExtend: Bool {
        guard let url = currentURL, let d = decoded, d.url == url, !savingURLs.contains(url) else { return false }
        let e = currentEdits
        if e.hasTransparency { return false }
        return !d.hasTransparentPixels || e.background?.isOpaque == true
    }

    /// Background ▸ Generate on This Mac…: the sheet, once the generative fill model is installed (offered for
    /// download first when it isn't).
    func generateBackgroundOnThisMac() {
        offerDownload(.generativeFill) { [weak self] in self?.showGenerateBackground = true }
    }

    /// Intelligence panel ▸ Generative Extend: Extend with Generate, offering its model first when it's missing.
    func beginGenerativeExtend() {
        offerDownload(.generativeFill) { [weak self] in self?.beginExtend(.generate) }
    }

    /// Opens the Crop tool in Extend mode, with this fill (by default the one last chosen). A picture that's
    /// been cropped is saved cropped first (see `extendCropped`).
    func beginExtend(_ method: ExtendMethod? = nil) {
        guard canExtend else { return }
        let e = currentEdits
        if let url = currentURL, let d = decoded, e.crop != nil, !e.cropExtendsBeyondImage, !PhotosRoundTrip.isFromPhotos(url) {
            return extendCropped(url: url, decoded: d, edits: e, method: method)
        }
        viewMode = .viewer
        let method = method ?? Prefs.preferredExtendMethod
        pendingExtend = method == .generate && !GenerativeModel.isInstalled ? .match : method
        activeTool = .crop
    }

    /// Extend after a crop: the frame should start at the crop, not bring back what was cropped away. So the
    /// cropped picture is saved first, as "<name> (Cropped)" stacked on the original (or, with Extend's copies
    /// off, in place of it), and Extend opens on that.
    private func extendCropped(url: URL, decoded d: DecodedImage, edits e: EditState, method: ExtendMethod?) {
        saveCopy(of: url, decoded: d, edits: e, label: "Cropped", defaultFormat: .heic, working: "Saving the crop…", systemImage: "crop",
                 failure: "Couldn't save the crop of “\(url.lastPathComponent)”", operation: .extend,
                 replaced: "Saved the crop in “\(url.lastPathComponent)”", then: { [weak self] made in
            // (Unless the user has moved on to another picture meanwhile.)
            guard let self, [url.standardizedFileURL, made.standardizedFileURL].contains(self.currentURL) else { return }
            self.whenShown(made) { self.beginExtend(method) }
        }) { $0 }
    }

    /// Shows `url` (if it isn't the current image) and does `action` once it has loaded.
    func whenShown(_ url: URL, _ action: @escaping () -> Void) {
        let url = url.standardizedFileURL
        if currentURL != url {
            activeTool = nil
            select(url)
            // (Not shown, such as when it's filtered out: nothing waits for it, to go off when it's viewed later.)
            guard currentURL == url else { return }
        }
        if decoded?.url.standardizedFileURL == url, !isLoading { return action() }
        whenLoaded = (url, action)
    }

    /// Makes Extend's fill when the crop reaches past the image and no current fill covers it — after an
    /// Extend, and after anything that invalidates the fill (rotating, straightening, a bigger frame, undo).
    /// The result is added to the edits without an undo step of its own: the fill is derived data, and the
    /// saved seed makes it come out the same when it's made again. A generated fill shows a draft (the
    /// preview's quality) while its sharper second pass runs.
    func refillExtensionIfNeeded() {
        guard let url = currentURL, let d = decoded, d.url == url else { return }
        let e = currentEdits
        guard e.needsExtendFill else { return }
        let key = extendKey(e, url: url)
        if extendTaskKey == key { return }   // already being made (adjusting meanwhile doesn't change the fill)
        extendTask?.cancel()
        extendTaskKey = key
        extendProgress = 0
        let flag = CancelFlag()
        let relay = ModelRelay(self)
        extendTask = Task {
            defer {
                if extendTaskKey == key {
                    extendTaskKey = nil
                    extendProgress = nil
                    extendTask = nil
                }
            }
            do {
                let fill = try await withTaskCancellationHandler {
                    try await ExtendRenderer.makeFill(d, edits: e, progress: { fraction in
                        Task { @MainActor in
                            if let model = relay.model, model.extendTaskKey == key { model.extendProgress = fraction }
                        }
                        return flag.isSet
                    }, draft: { draft in
                        Task { @MainActor in try? await relay.model?.applyExtendFill(draft, url: url, key: key, isDraft: true) }
                    })
                } onCancel: {
                    flag.set()
                }
                guard !Task.isCancelled else { return }
                try await applyExtendFill(fill, url: url, key: key, isDraft: false)
            } catch ExtendError.cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                showToast("Couldn't extend: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// Image ▸ Try Another Extend Fill: the same frame, filled differently.
    func tryAnotherExtendFill() {
        guard currentEdits.cropExtendsBeyondImage else { return }
        updateEdits("Try Another Fill") {
            $0.extendSeed = UInt64.random(in: 1...UInt64.max)
            $0.extendFill = nil
        }
    }

    /// What a fill is made from and covers; adjustments don't count (they apply on top of it).
    private func extendKey(_ e: EditState, url: URL) -> String {
        guard let c = e.crop else { return "" }
        return "\(url.path)|\(e.extendSourceKey)|\(c.minX),\(c.minY),\(c.width),\(c.height)"
    }

    /// Puts a finished fill (or a draft of it) into the image's current edits, if they still want it.
    private func applyExtendFill(_ fill: ExtendRenderer.Fill, url: URL, key: String, isDraft: Bool) async throws {
        let path = try await Task.detached(priority: .userInitiated) { try ExtendFillStore.save(fill.fill) }.value
        guard var current = edits[url], extendKey(current, url: url) == key else { return }
        if isDraft, let existing = current.extendFill, existing.isDraft != true, let c = current.crop, existing.covers(c) { return }
        var made = fill.extendFill(path)
        made.isDraft = isDraft ? true : nil
        current.extendFill = made
        setEditsDictionary(url, current)
        if url == currentURL { refreshDisplay() }
    }

    /// Save and export would write the unfilled (transparent) border while a fill is still being made.
    func extendIsPending(for url: URL) -> Bool {
        edits[url]?.needsExtendFill == true
    }
}
