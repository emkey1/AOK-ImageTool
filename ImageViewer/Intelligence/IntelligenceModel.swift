import AppKit
import Observation
import SwiftUI
import VisionKit

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, error }
    let id = UUID()
    let role: Role
    var text: String
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    var urls: [URL]
}

enum IndexReason {
    case search, quality, duplicates, similar, user
    /// Pictures added or changed in a folder that's been analyzed.
    case refresh
}

/// Apple Intelligence + Vision features for the current image and the open folder.
@Observable
final class IntelligenceModel {
    @ObservationIgnored weak var viewer: ViewerModel?

    // MARK: Availability
    private(set) var support: ModelSupport = ImageDescriber.support
    let liveTextSupported = ImageAnalyzer.isSupported

    // MARK: Current image
    private(set) var descriptions: [URL: ImageDescription] = [:]
    private(set) var recognizedText: [URL: String] = [:]
    private(set) var busy: String?
    private(set) var isDescribing = false
    private(set) var describeError: String?
    private(set) var isReadingText = false

    // MARK: Chat
    private(set) var chat: [ChatMessage] = []
    private(set) var isAnswering = false
    @ObservationIgnored private var chatSession = ImageChat()
    @ObservationIgnored private var chatURL: URL?
    @ObservationIgnored private var chatTask: Task<Void, Never>?

    // MARK: Folder index
    private(set) var index: [URL: IndexEntry] = [:]
    private(set) var indexProgress: Double?
    private(set) var indexTotal = 0
    @ObservationIgnored private var blobs: [URL: String] = [:]
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var describeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReasons: Set<IndexReason> = []

    // MARK: Similarity & duplicates
    private(set) var similarityReference: URL?
    private(set) var similarityDistances: [URL: Float] = [:]
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var isFindingDuplicates = false
    var duplicateThreshold: Float = 0.3

    var qualityScores: [URL: Float] {
        index.compactMapValues(\.score)
    }

    var isIndexing: Bool { indexProgress != nil }
    /// Images being scored on their own (Shot Quality in a folder that hasn't been analyzed).
    private(set) var scoring: Set<URL> = []

    /// The folder has been analyzed (most of it, at least), so what's added to it is analyzed too.
    private var folderAnalyzed: Bool {
        guard let viewer, !viewer.allItems.isEmpty else { return false }
        return indexedCount * 2 >= viewer.allItems.count
    }

    // MARK: - Lifecycle

    func refreshSupport() {
        support = ImageDescriber.support
    }

    func folderDidChange(_ newFolder: URL) {
        cancelAll()
        pendingReasons = []   // what was asked of the last folder
        flushSave()
        folder = newFolder.standardizedFileURL
        index = [:]
        blobs = [:]
        descriptions = [:]
        recognizedText = [:]
        duplicateGroups = []
        similarityReference = nil
        similarityDistances = [:]
        resetChat()
        let folder = newFolder.standardizedFileURL
        Task {
            let stored = await Task.detached(priority: .utility) { FolderIndexStore.load(folder: folder) }.value
            guard self.folder == folder else { return }
            var loaded: [URL: IndexEntry] = [:]
            for (key, entry) in stored {
                loaded[folder.appendingPathComponent(key).standardizedFileURL] = entry
            }
            index = loaded
            for (url, entry) in loaded {
                if let d = entry.description { descriptions[url] = d }
            }
            rebuildBlobs()
            viewer?.applySortAndFilter()
            analyzeNewcomers()
        }
    }

    func itemsDidChange() {
        rebuildBlobs()
        if !pendingReasons.isEmpty, indexTask == nil, let reason = pendingReasons.first {
            ensureIndexed(reason: reason)
        } else {
            analyzeNewcomers()
        }
    }

    /// In a folder that's been analyzed, pictures added or changed since (copies, saved edits, new files) are
    /// analyzed in the background, so Best Shots, search and Shot Quality include them. (A copy tops its stack:
    /// without this, a stack had no score and sank to the bottom of Best Shots.)
    private func analyzeNewcomers() {
        guard indexTask == nil, let viewer, folderAnalyzed, viewer.allItems.contains(where: needsIndex) else { return }
        ensureIndexed(reason: .refresh)
    }

    /// Shot Quality for the current image when the folder hasn't been analyzed: this one is scored on its own.
    func scoreCurrentIfNeeded() {
        guard let viewer, let item = viewer.currentItem, needsIndex(item), indexTask == nil, !scoring.contains(item.url) else { return }
        let url = item.url, date = item.modificationDate
        scoring.insert(url)
        Task {
            defer { scoring.remove(url) }
            guard var entry = await Self.analyze(url: url, modDate: date), viewer.allItems.contains(where: { $0.url == url }) else { return }
            entry.description = index[url]?.description
            setEntry(entry, for: url)
            if viewer.sortKey == .quality { viewer.applySortAndFilter() }
        }
    }

    func imageDidChange() {
        guard let url = viewer?.currentURL else { return }
        if chatURL != url { resetChat() }
        describeError = nil
        if Prefs.autoDescribe, viewer?.showInspector == true, viewer?.inspectorTab == .intelligence,
           descriptions[url] == nil, support.isAvailable {
            describeCurrent()
        }
    }

    func cancelAll() {
        indexTask?.cancel()
        indexTask = nil
        indexProgress = nil
        describeTask?.cancel()
        chatTask?.cancel()
        isDescribing = false
        isAnswering = false
    }

    func forget(_ url: URL) {
        index[url] = nil
        blobs[url] = nil
        descriptions[url] = nil
        recognizedText[url] = nil
        scheduleSave()
    }

    func rename(from old: URL, to new: URL) {
        if let e = index.removeValue(forKey: old) { index[new] = e }
        if let d = descriptions.removeValue(forKey: old) { descriptions[new] = d }
        if let t = recognizedText.removeValue(forKey: old) { recognizedText[new] = t }
        rebuildBlobs()
        scheduleSave()
    }

    // MARK: - Search

    private func rebuildBlobs() {
        guard let viewer else { return }
        var result: [URL: String] = [:]
        for item in viewer.allItems {
            let raw = index[item.url]?.searchBlob(fileName: item.name) ?? item.name.lowercased()
            result[item.url] = Self.normalize(raw)
        }
        blobs = result
    }

    private static func normalize(_ s: String) -> String {
        let mapped = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return " " + String(mapped)
    }

    /// For each query word: the word itself if anything in the folder matches it, otherwise its
    /// closest word-embedding neighbors (so "puppy" finds images labeled "dog" without
    /// polluting results when the literal word already matches).
    func searchTerms(for query: String) -> [[String]] {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return tokens.map { token in
            let literal = " " + token
            if blobs.values.contains(where: { $0.contains(literal) }) { return [token] }
            return QueryExpander.shared.variants(of: token)
        }
    }

    func matches(_ item: ImageItem, terms: [[String]]) -> Bool {
        let blob = blobs[item.url] ?? Self.normalize(item.name)
        return terms.allSatisfy { alternatives in
            alternatives.contains { blob.contains(" " + $0) }
        }
    }

    var indexedCount: Int {
        guard let viewer else { return 0 }
        return viewer.allItems.reduce(0) { $0 + (index[$1.url]?.analyzed == true ? 1 : 0) }
    }

    // MARK: - Folder indexing

    private func needsIndex(_ item: ImageItem) -> Bool {
        guard let entry = index[item.url], entry.analyzed else { return true }
        return entry.modDate != item.modificationDate
    }

    func ensureIndexed(reason: IndexReason) {
        pendingReasons.insert(reason)
        guard indexTask == nil, let viewer else { return }
        let todo = viewer.allItems.filter(needsIndex).map { ($0.url, $0.modificationDate) }
        guard !todo.isEmpty else {
            indexingFinished()
            return
        }
        indexTotal = todo.count
        indexProgress = 0
        indexTask = Task {
            var done = 0
            await withTaskGroup(of: (URL, IndexEntry?).self) { group in
                var iterator = todo.makeIterator()
                func addNext() {
                    guard let (url, date) = iterator.next() else { return }
                    group.addTask { (url, await Self.analyze(url: url, modDate: date)) }
                }
                for _ in 0..<3 { addNext() }
                while let (url, entry) = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if var entry {
                        entry.description = index[url]?.description
                        index[url] = entry
                        if let item = viewer.allItems.first(where: { $0.url == url }) {
                            blobs[url] = Self.normalize(entry.searchBlob(fileName: item.name))
                        }
                    }
                    done += 1
                    indexProgress = Double(done) / Double(todo.count)
                    if done % 40 == 0, !viewer.trimmedSearch.isEmpty || viewer.sortKey == .quality {
                        viewer.applySortAndFilter()
                    }
                    addNext()
                }
            }
            guard !Task.isCancelled else { return }
            indexTask = nil
            indexProgress = nil
            scheduleSave()
            indexingFinished()
        }
    }

    private func indexingFinished() {
        let reasons = pendingReasons
        pendingReasons = []
        guard let viewer else { return }
        if reasons.contains(.search) || reasons.contains(.quality)
            || (reasons.contains(.refresh) && (viewer.sortKey == .quality || !viewer.trimmedSearch.isEmpty)) {
            viewer.applySortAndFilter()
        }
        if reasons.contains(.duplicates) { computeDuplicates() }
        if reasons.contains(.similar), let ref = viewer.currentURL { computeSimilar(to: ref) }
        if reasons.contains(.user) {
            viewer.showToast("Analyzed \(viewer.allItems.count) images", systemImage: "sparkles")
        }
    }

    @concurrent
    private static func analyze(url: URL, modDate: Date?) async -> IndexEntry? {
        guard let thumb = ImageDecoder.thumbnail(url: url, maxPixelSize: 768) else { return nil }
        let r = await VisionServices.analyzeForIndex(thumb)
        return IndexEntry(modDate: modDate, labels: r.labels, text: r.text, score: r.score, isUtility: r.isUtility,
                          featurePrint: r.featurePrint, description: nil, analyzed: true)
    }

    private func setEntry(_ entry: IndexEntry, for url: URL) {
        index[url] = entry
        if let item = viewer?.allItems.first(where: { $0.url == url }) {
            blobs[url] = Self.normalize(entry.searchBlob(fileName: item.name))
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    private func flushSave() {
        guard let folder, !index.isEmpty else { return }
        var entries: [String: IndexEntry] = [:]
        for (url, entry) in index {
            entries[FolderIndexStore.relativeKey(url, in: folder)] = entry
        }
        Task.detached(priority: .utility) { FolderIndexStore.save(entries, folder: folder) }
    }

    // MARK: - Describe (Apple Intelligence)

    func describeCurrent() {
        guard let viewer, let d = viewer.decoded, let url = viewer.currentURL, d.url == url else { return }
        refreshSupport()
        if case .unavailable(let reason) = support {
            describeError = reason
            return
        }
        describeTask?.cancel()
        isDescribing = true
        describeError = nil
        let image = d.cgImage
        let knownText = recognizedText[url]
        let modDate = viewer.currentItem?.modificationDate
        describeTask = Task {
            let small = await VisionServices.downscaled(image, maxDimension: 1024)
            let labels = await VisionServices.classify(small)
            let text: String
            if let knownText { text = knownText } else { text = await VisionServices.recognizeText(small, fast: true) }
            do {
                let description = try await ImageDescriber.describe(small, labels: labels, text: text)
                guard !Task.isCancelled else { return }
                descriptions[url] = description
                var entry = index[url] ?? IndexEntry(modDate: modDate)
                entry.description = description
                if entry.labels.isEmpty { entry.labels = labels }
                setEntry(entry, for: url)
            } catch {
                guard !Task.isCancelled else { return }
                describeError = ImageDescriber.friendlyError(error)
            }
            isDescribing = false
        }
    }

    func applyKeywordsAsTags() {
        guard let viewer, let url = viewer.currentURL, let description = descriptions[url] else { return }
        do {
            let current = try url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
            var tags = current.tagNames ?? []
            for k in description.keywords where !tags.contains(k) { tags.append(k) }
            // NSURL's setter works on every supported macOS (URLResourceValues.tagNames is settable from macOS 26).
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            var u = url
            if let label = current.labelNumber, label != 0 {
                var restore = URLResourceValues()
                restore.labelNumber = label
                try? u.setResourceValues(restore)
            }
            viewer.showToast("Added \(description.keywords.count) Finder tags — now searchable in Spotlight", systemImage: "tag")
        } catch {
            viewer.showError("Couldn't add tags", error)
        }
    }

    func renameToSuggestion() {
        guard let viewer, let item = viewer.currentItem, let name = descriptions[item.url]?.fileName, !name.isEmpty else { return }
        if viewer.rename(item, to: name) {
            viewer.showToast("Renamed to \(name).\(item.url.pathExtension)", systemImage: "character.cursor.ibeam")
        }
    }

    /// Generates (if needed) a descriptive file name for the rename sheet.
    func suggestName(for item: ImageItem) async -> String? {
        if let existing = descriptions[item.url]?.fileName, !existing.isEmpty { return existing }
        guard support.isAvailable else { return nil }
        let cached = ImagePipeline.shared.cached(item.url, page: 0, hdr: Prefs.hdrEnabled)?.cgImage
        let url = item.url
        let source: CGImage? = if let cached { cached } else { await Task.detached { ImageDecoder.thumbnail(url: url, maxPixelSize: 1024) }.value }
        guard let source else { return nil }
        let small = await VisionServices.downscaled(source, maxDimension: 1024)
        let labels = await VisionServices.classify(small)
        guard let description = try? await ImageDescriber.describe(small, labels: labels, text: "") else { return nil }
        descriptions[item.url] = description
        var entry = index[item.url] ?? IndexEntry(modDate: item.modificationDate)
        entry.description = description
        setEntry(entry, for: item.url)
        return description.fileName
    }

    // MARK: - Text

    func readTextCurrent() {
        guard let viewer, let d = viewer.decoded, let url = viewer.currentURL else { return }
        if let overlayText = viewer.canvas?.liveTextText {
            recognizedText[url] = overlayText
            return
        }
        isReadingText = true
        let image = d.cgImage
        Task {
            let source = await VisionServices.downscaled(image, maxDimension: 4096)
            let text = await VisionServices.recognizeText(source, fast: false)
            recognizedText[url] = text
            isReadingText = false
        }
    }

    // MARK: - Chat ("Ask about this image")

    func resetChat() {
        chatTask?.cancel()
        chat = []
        chatSession = ImageChat()
        chatURL = viewer?.currentURL
        isAnswering = false
    }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering, let viewer, let d = viewer.decoded, let url = viewer.currentURL, d.url == url else { return }
        refreshSupport()
        if case .unavailable(let reason) = support {
            chat.append(ChatMessage(role: .error, text: reason))
            return
        }
        if chatURL != url { resetChat() }
        chatURL = url
        chat.append(ChatMessage(role: .user, text: q))
        chat.append(ChatMessage(role: .assistant, text: ""))
        let answerIndex = chat.count - 1
        isAnswering = true
        let image = d.cgImage
        let session = chatSession
        let knownText = recognizedText[url]
        chatTask = Task {
            do {
                try await session.ask(q, image: image, describe: {
                    let small = await VisionServices.downscaled(image, maxDimension: 1024)
                    let labels = await VisionServices.classify(small)
                    let text: String
                    if let knownText { text = knownText } else { text = await VisionServices.recognizeText(small, fast: true) }
                    return """
                        You can't see the image directly. A classifier detected: \(labels.prefix(12).joined(separator: ", ")).
                        \(text.isEmpty ? "" : "Text in the image: \(text.prefix(500))")
                        """
                }) { partial in
                    guard !Task.isCancelled, self.chat.indices.contains(answerIndex) else { return }
                    self.chat[answerIndex].text = partial
                }
            } catch {
                guard !Task.isCancelled, chat.indices.contains(answerIndex) else { return }
                chat[answerIndex] = ChatMessage(role: .error, text: ImageDescriber.friendlyError(error))
            }
            isAnswering = false
        }
    }

    // MARK: - Subject / background

    private func withBusy(_ message: String, _ work: @escaping () async throws -> Void) {
        busy = message
        Task {
            do {
                try await work()
            } catch {
                viewer?.showToast(error.localizedDescription, systemImage: "exclamationmark.triangle")
            }
            busy = nil
        }
    }

    private func subjectMask(for d: DecodedImage) async throws -> CIImage {
        if let mask = MaskStore.shared.subjectMask(for: d.url) { return mask }
        let mask = try await VisionServices.subjectMask(for: d.cgImage)
        MaskStore.shared.setSubjectMask(mask, for: d.url)
        return mask
    }

    func toggleRemoveBackground() {
        guard let viewer, let d = viewer.decoded, d.url == viewer.currentURL else { return }
        if viewer.currentEdits.cutout != nil {
            viewer.updateEdits("Restore Background") { $0.removeCutout() }
            return
        }
        withBusy("Finding the subject…") { [weak self] in
            _ = try await self?.subjectMask(for: d)
            self?.viewer?.updateEdits("Remove Background", of: d.url) { $0.cutout = .subject }
        }
    }

    func copySubject() {
        guard let viewer, let d = viewer.decoded, d.url == viewer.currentURL else { return }
        withBusy("Lifting the subject…") { [weak self] in
            guard let self else { return }
            let mask = try await subjectMask(for: d)
            try await copyCutout(of: d, mask: mask)
            viewer.showToast("Copied subject", systemImage: "person.crop.rectangle")
        }
    }

    /// Renders `d` with `mask` applied, cropped to the mask, and puts a PNG on the pasteboard.
    func copyCutout(of d: DecodedImage, mask: CIImage) async throws {
        let png = try await cutoutPNG(of: d, mask: mask)
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }

    /// PNG of `d` with `mask` applied (transparent elsewhere), cropped to the masked area.
    func cutoutPNG(of d: DecodedImage, mask: CIImage) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let ext = CGRect(origin: .zero, size: d.pixelSize)
            let m = mask
                .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: ext.width / mask.extent.width, y: ext.height / mask.extent.height))
            var cut = CIImage(cgImage: d.cgImage).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: ext),
                kCIInputMaskImageKey: m,
            ])
            if let bounds = VisionServices.maskBounds(m, imageSize: d.pixelSize) { cut = cut.cropped(to: bounds) }
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let data = ImageDecoder.ciContext.pngRepresentation(of: cut, format: .RGBA8, colorSpace: sRGB) else {
                throw VisionError.noSubject
            }
            return data
        }.value
    }

    // MARK: - Smart fixes

    private func beforeCropProxy(_ d: DecodedImage, edits: EditState) async -> CGImage? {
        var e = edits
        e.straighten = 0
        e.crop = nil
        return await EditRenderer.shared.render(d, edits: e, maxDimension: 1024, stage: .beforeCrop)?.image
    }

    func autoStraighten() {
        guard let viewer, let d = viewer.decoded, d.url == viewer.currentURL else { return }
        let edits = viewer.currentEdits
        withBusy("Finding the horizon…") { [weak self] in
            guard let self, let proxy = await beforeCropProxy(d, edits: edits),
                  let angle = await VisionServices.straightenAngle(proxy) else {
                self?.viewer?.showToast("No horizon or straight lines found", systemImage: "level")
                return
            }
            guard abs(angle) >= 0.15 else {
                viewer.showToast("Already level", systemImage: "level")
                return
            }
            viewer.updateEdits("Straighten", of: d.url) { $0.straighten = min(max(angle, -45), 45) }
            viewer.showToast(String(format: "Straightened %.1f°", angle), systemImage: "level")
        }
    }

    func smartCrop() {
        guard let viewer, let d = viewer.decoded, d.url == viewer.currentURL else { return }
        var edits = viewer.currentEdits
        edits.crop = nil
        withBusy("Finding the subject…") {
            guard let proxy = await EditRenderer.shared.render(d, edits: edits, maxDimension: 1024, stage: .beforeCrop)?.image,
                  let salient = await VisionServices.salientRegion(proxy),
                  let crop = Self.cropRect(around: salient, imageSize: CGSize(width: proxy.width, height: proxy.height))
            else {
                viewer.showToast("This image is already well framed", systemImage: "crop")
                return
            }
            viewer.updateEdits("Smart Crop", of: d.url) { $0.crop = crop }
        }
    }

    /// Smallest crop (original aspect ratio, with breathing room) around a salient region.
    /// Input is normalized lower-left; output is normalized top-left (EditState convention).
    static func cropRect(around salient: CGRect, imageSize: CGSize) -> CGRect? {
        let W = imageSize.width, H = imageSize.height
        var box = CGRect(x: salient.minX * W, y: salient.minY * H, width: salient.width * W, height: salient.height * H)
        box = box.insetBy(dx: -box.width * 0.18, dy: -box.height * 0.18)
        let aspect = W / H
        if box.width / box.height < aspect {
            let w = box.height * aspect
            box = CGRect(x: box.midX - w / 2, y: box.minY, width: w, height: box.height)
        } else {
            let h = box.width / aspect
            box = CGRect(x: box.minX, y: box.midY - h / 2, width: box.width, height: h)
        }
        if box.width > W || box.height > H {
            let s = min(W / box.width, H / box.height)
            box = CGRect(x: box.midX - box.width * s / 2, y: box.midY - box.height * s / 2, width: box.width * s, height: box.height * s)
        }
        box.origin.x = min(max(box.minX, 0), W - box.width)
        box.origin.y = min(max(box.minY, 0), H - box.height)
        guard box.width * box.height < W * H * 0.85 else { return nil }
        return CGRect(x: box.minX / W, y: 1 - box.maxY / H, width: box.width / W, height: box.height / H)
    }

    func fixPerspective() {
        guard let viewer, let d = viewer.decoded, d.url == viewer.currentURL else { return }
        if viewer.currentEdits.perspective != nil {
            viewer.updateEdits("Undo Document Fix") { $0.perspective = nil }
            return
        }
        let image = d.cgImage
        withBusy("Looking for a document…") { [weak self] in
            let small = await VisionServices.downscaled(image, maxDimension: 1536)
            guard let quad = await VisionServices.documentQuad(small) else { throw VisionError.noDocument }
            self?.viewer?.updateEdits("Straighten Document", of: d.url) {
                $0.perspective = quad
                $0.crop = nil
                $0.straighten = 0
            }
        }
    }

    // MARK: - Similar & duplicates

    func showSimilar() {
        guard let viewer, let url = viewer.currentURL else { return }
        if index[url]?.featurePrint != nil, viewer.allItems.allSatisfy({ !needsIndex($0) }) {
            computeSimilar(to: url)
        } else {
            viewer.showToast("Analyzing folder to find similar images…", systemImage: "sparkles")
            ensureIndexed(reason: .similar)
        }
    }

    private func computeSimilar(to url: URL) {
        guard let viewer, let reference = index[url]?.featurePrint else { return }
        let prints = viewer.allItems.compactMap { item in index[item.url]?.featurePrint.map { (item.url, $0) } }
        Task {
            let distances = await Task.detached(priority: .userInitiated) {
                VisionServices.distances(from: reference, to: prints)
            }.value
            similarityDistances = distances
            similarityReference = url
            viewer.viewMode = .grid
            viewer.applySortAndFilter(selecting: url)
        }
    }

    func clearSimilar() {
        similarityReference = nil
        similarityDistances = [:]
        viewer?.applySortAndFilter()
    }

    func findDuplicates() {
        guard let viewer else { return }
        viewer.showDuplicates = true
        if viewer.allItems.contains(where: needsIndex) {
            ensureIndexed(reason: .duplicates)
        } else {
            computeDuplicates()
        }
    }

    func computeDuplicates() {
        guard let viewer else { return }
        let prints = viewer.allItems.compactMap { item in index[item.url]?.featurePrint.map { (item.url, $0) } }
        let threshold = duplicateThreshold
        let scores = qualityScores
        isFindingDuplicates = true
        Task {
            let groups = await Task.detached(priority: .userInitiated) {
                VisionServices.clusterDuplicates(prints, threshold: threshold)
            }.value
            duplicateGroups = groups
                .map { group in DuplicateGroup(urls: group.sorted { (scores[$0] ?? -2) > (scores[$1] ?? -2) }) }
                .sorted { $0.urls.count > $1.urls.count }
            isFindingDuplicates = false
        }
    }

    func analyzeFolder() {
        guard let viewer else { return }
        if viewer.allItems.contains(where: needsIndex) {
            ensureIndexed(reason: .user)
        } else {
            viewer.showToast("Folder already analyzed", systemImage: "checkmark.circle")
        }
    }

    // MARK: - Image Playground

    func savePlaygroundImage(from tempURL: URL) {
        guard let viewer, let folder = viewer.folderURL else { return }
        let base = (viewer.currentURL?.deletingPathExtension().lastPathComponent ?? "Image") + " (Playground)"
        let ext = tempURL.pathExtension.isEmpty ? "heic" : tempURL.pathExtension
        let dest = ImageWriter.uniqueURL(in: viewer.currentURL?.deletingLastPathComponent() ?? folder, baseName: base, ext: ext)
        do {
            try FileManager.default.copyItem(at: tempURL, to: dest)
            if let original = viewer.currentURL { ImageStacks.markDerived(dest, from: original) }
            if let item = FolderScanner.item(for: dest) {
                viewer.insertItem(item, select: true)
            }
            viewer.showToast("Saved \(dest.lastPathComponent)", systemImage: "apple.image.playground")
        } catch {
            viewer.showError("Couldn't save the Image Playground image", error)
        }
    }
}
