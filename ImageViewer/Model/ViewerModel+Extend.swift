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
    var canExtend: Bool {
        guard canEdit, let d = decoded else { return false }
        let e = currentEdits
        if e.hasTransparency { return false }
        return !d.hasTransparentPixels || e.background?.isOpaque == true
    }

    /// Opens the Crop tool in Extend mode, with this fill (by default the one last chosen).
    func beginExtend(_ method: ExtendMethod? = nil) {
        guard canExtend else { return }
        viewMode = .viewer
        let method = method ?? Prefs.preferredExtendMethod
        pendingExtend = method == .generate && !GenerativeModel.isInstalled ? .match : method
        activeTool = .crop
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
