import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String {
    case viewer, grid
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case info, adjust, intelligence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "Info"
        case .adjust: "Adjust"
        case .intelligence: "Intelligence"
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .adjust: "slider.horizontal.3"
        case .intelligence: "apple.intelligence"
        }
    }
}

enum ActiveTool: Equatable {
    case crop
    case selectObject
}

/// What the canvas should draw right now.
nonisolated struct DisplayImage: Equatable, @unchecked Sendable {
    let url: URL
    let image: CGImage
    /// Pixel size of the full-resolution result (the canvas zooms in these units even when `image` is a proxy).
    let logicalSize: CGSize
    let isPlaceholder: Bool
    let isHDR: Bool
    let hasAlpha: Bool
    let animate: Bool
    /// Identifies the visual content (file + page + edits) so Live Text only re-runs when it changes.
    let contentKey: Int
    let revision: Int

    static func == (a: DisplayImage, b: DisplayImage) -> Bool { a.revision == b.revision }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let systemImage: String?
    let actionTitle: String?
}

struct ExportRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// The undo target for one image's edits (see `ViewerModel.editUndoTargets`).
final class EditUndoTarget {}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@Observable
final class ViewerModel {
    // MARK: Source
    private(set) var folderURL: URL?
    private(set) var restrictedTo: Set<URL>?
    private(set) var allItems: [ImageItem] = []
    private(set) var items: [ImageItem] = []
    private(set) var currentIndex: Int?
    var selection: Set<URL> = []
    private(set) var isScanning = false

    // MARK: Display
    private(set) var decoded: DecodedImage?
    private(set) var display: DisplayImage?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var pageIndex = 0
    private(set) var zoomPercent: Double = 100
    private(set) var isFitMode = true
    private(set) var hasLiveText = false

    // MARK: UI state
    var viewMode: ViewMode = .viewer {
        didSet { if viewMode == .grid, activeTool != nil { activeTool = nil } }   // tools work in the viewer
    }
    var showInspector = false
    var inspectorTab: InspectorTab = .info
    var showFilmstrip: Bool = Prefs.showFilmstrip {
        didSet { Prefs.setBool(showFilmstrip, PrefKey.showFilmstrip) }
    }
    var lockZoom = false
    var showOriginal = false {
        didSet { if oldValue != showOriginal { refreshDisplay() } }
    }
    var activeTool: ActiveTool? {
        didSet { toolImage = activeTool == nil ? nil : currentURL }
    }
    /// The image the open tool was opened on.
    @ObservationIgnored private var toolImage: URL?
    /// Set to open the Crop tool already extending, with this fill; the tool takes it when it appears.
    var pendingExtend: ExtendMethod?
    private(set) var isSlideshowRunning = false
    private(set) var isSlideshowPaused = false
    private(set) var isFullScreen = false
    var gridColumns = 4
    var gridThumbnailSize: Double = {
        let v = UserDefaults.standard.double(forKey: PrefKey.gridThumbnailSize)
        return v > 0 ? v : 170
    }() {
        didSet { Prefs.set(gridThumbnailSize, PrefKey.gridThumbnailSize) }
    }

    // MARK: Sheets & alerts
    var showShortcuts = false
    var exportRequest: ExportRequest?
    var renameTarget: ImageItem?
    var showPlayground = false
    var showBackgroundPlayground = false
    /// The on-device model's background sheet (GenerateSheets.swift).
    var showGenerateBackground = false
    var showBlackAndWhite = false
    var showDuplicates = false
    var alert: AlertInfo?
    private(set) var toast: ToastMessage?

    // MARK: Sorting & filtering
    var sortKey: SortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: PrefKey.sortKey) ?? "") ?? .name {
        didSet {
            Prefs.set(sortKey.rawValue, PrefKey.sortKey)
            sortKeyDidChange()
        }
    }
    var sortAscending: Bool = UserDefaults.standard.object(forKey: PrefKey.sortAscending) as? Bool ?? true {
        didSet {
            Prefs.set(sortAscending, PrefKey.sortAscending)
            applySortAndFilter()
        }
    }
    var flagFilter: FlagFilter = .all {
        didSet { applySortAndFilter() }
    }
    var searchText = "" {
        didSet { searchTextDidChange(oldValue) }
    }
    var includeSubfolders: Bool = Prefs.includeSubfolders {
        didSet {
            Prefs.setBool(includeSubfolders, PrefKey.includeSubfolders)
            rescan()
        }
    }

    // MARK: Stacks (ViewerModel+Stacks.swift)
    /// Copies made from an image stack with it (see `ImageStacks`).
    var stacksEnabled: Bool = Prefs.stackCopies {
        didSet {
            Prefs.setBool(stacksEnabled, PrefKey.stackCopies)
            applySortAndFilter()
        }
    }
    /// The stacks in `items`, by their original: newest copy first, the original last.
    private(set) var stacks: [URL: [URL]] = [:]
    /// The stack (by its original) of each stacked item.
    private(set) var stackOf: [URL: URL] = [:]
    /// Stacks shown spread out, every copy side by side.
    var expandedStacks: Set<URL> = []
    /// Which copy a closed stack shows, by its original (the newest when not set).
    @ObservationIgnored var stackFront: [URL: URL] = [:]

    // MARK: Edits
    private(set) var edits: [URL: EditState] = [:]
    /// Images being saved; they can't be edited until the save is done.
    var savingURLs: Set<URL> = []
    /// Each image's edit undos are registered with its own target, so saving it can drop just them.
    @ObservationIgnored var editUndoTargets: [URL: EditUndoTarget] = [:]
    /// Progress (0...1) of the Extend fill being made, nil when idle.
    var extendProgress: Double?
    @ObservationIgnored var extendTask: Task<Void, Never>?
    @ObservationIgnored var extendTaskKey: String?

    // MARK: Collaborators
    let intelligence = IntelligenceModel()
    @ObservationIgnored weak var canvas: CanvasController?
    @ObservationIgnored private(set) weak var window: NSWindow?
    @ObservationIgnored private lazy var watcher = FolderWatcher { [weak self] in self?.rescan() }
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var fullRenderTask: Task<Void, Never>?
    @ObservationIgnored private var slideshowTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var toastAction: (() -> Void)?
    @ObservationIgnored private var displayRevision = 0
    @ObservationIgnored private var renderInFlight = false
    @ObservationIgnored private var renderDirty = false
    @ObservationIgnored private var lastNavigation = Date.distantPast
    @ObservationIgnored private var navigationDirection = 1
    @ObservationIgnored var keyMonitor: Any?
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingOpenURLs: [URL] = []
    @ObservationIgnored private var openDebounce: Task<Void, Never>?
    @ObservationIgnored private var enteredFullScreenForSlideshow = false
    @ObservationIgnored var gridAnchor: Int?
    @ObservationIgnored var isSavingBeforeClose = false
    @ObservationIgnored private var subjectMaskLoads: Set<URL> = []
    @ObservationIgnored private var enhanceTask: Task<Void, Never>?
    /// The AI-upscaled display (by revision) and the image it was made from.
    @ObservationIgnored private var enhanced: (revision: Int, base: CGImage)?

    static let proxyDimension: CGFloat = 2048

    init() {
        intelligence.viewer = self
        ViewerRegistry.shared.add(self)
    }

    // MARK: - Derived

    var currentItem: ImageItem? {
        guard let i = currentIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }

    var currentURL: URL? { currentItem?.url }

    var currentEdits: EditState {
        currentURL.flatMap { edits[$0] } ?? .identity
    }

    var hasUnsavedEdits: Bool { !unsavedURLs.isEmpty }

    var pageCount: Int { decoded?.pageCount ?? 1 }

    var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var windowTitle: String {
        currentItem?.name ?? folderURL?.lastPathComponent ?? "AOK-ImageTool"
    }

    var windowSubtitle: String {
        guard let i = currentIndex, !items.isEmpty else {
            if isScanning { return "Loading…" }
            return folderURL == nil ? "" : "No images"
        }
        var parts = ["\(i + 1) of \(items.count)"]
        if let p = currentStackPosition { parts.append("Stack \(p.index + 1)/\(p.count)") }
        if let url = currentURL, PhotosRoundTrip.isFromPhotos(url) {
            parts.append(PhotosLibrary.shared.photo(for: url)?.isLive == true ? "Live Photo from Photos" : "From Photos")
        }
        if let shown = display, shown.url == currentURL, !shown.isPlaceholder {
            parts.append(MetadataFormatting.dimensions(shown.logicalSize))
        } else if let d = decoded, d.url == currentURL {
            parts.append(MetadataFormatting.dimensions(d.pixelSize))
        }
        if let item = currentItem { parts.append(MetadataFormatting.fileSize(item.fileSize)) }
        if viewMode == .viewer, display != nil { parts.append("\(Int(zoomPercent.rounded()))%") }
        if let url = currentURL, edits[url] != nil { parts.append("Edited") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Window attachment

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        if DebugHooks.isActive { DebugScenes.prepare(window) }
        // The default size is bigger than a small screen (or a VM's); keep the whole window on it.
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame,
           window.frame.width > screen.width || window.frame.height > screen.height {
            let size = CGSize(width: min(window.frame.width, screen.width), height: min(window.frame.height, screen.height))
            window.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
                            display: true)
        }
        window.isDocumentEdited = hasUnsavedEdits
        installKeyMonitor()
        WindowCloseInterception.install(for: window)
        let nc = NotificationCenter.default
        windowObservers.forEach(nc.removeObserver)
        windowObservers = [
            nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = true }
            },
            nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isFullScreen = false
                    self?.enteredFullScreenForSlideshow = false
                }
            },
            nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
            },
        ]
    }

    private func windowWillClose() {
        removeKeyMonitor()
        stopSlideshow()
        watcher.stop()
        scanTask?.cancel()
        loadTask?.cancel()
        intelligence.cancelAll()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        ViewerRegistry.shared.remove(self)
    }

    var undoManager: UndoManager? { window?.undoManager }

    // MARK: - Opening

    /// Coalesces the burst of `onOpenURL` calls macOS sends when several files are opened at once.
    func enqueueOpen(_ url: URL) {
        pendingOpenURLs.append(url)
        openDebounce?.cancel()
        openDebounce = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            open(urls)
        }
    }

    func open(_ urls: [URL]) {
        let urls = urls.map(\.standardizedFileURL)
        guard let first = urls.first else { return }
        if urls.count == 1 {
            if PhotosRoundTrip.isEditWithFile(first) {
                openEditWithFile(first)
                return
            }
            if FolderScanner.isDirectory(first) {
                openFolder(first, selecting: LastViewed.file(in: first))
            } else {
                openFolder(first.deletingLastPathComponent(), selecting: first)
            }
            return
        }
        let files = urls.filter { !FolderScanner.isDirectory($0) }
        if let firstFile = files.first {
            openFolder(firstFile.deletingLastPathComponent(), selecting: firstFile, restrictedTo: Set(files))
        } else {
            openFolder(first, selecting: nil)
        }
    }

    /// Photos' Edit With: just this photo (Photos' library folder isn't for browsing). macOS only lets the app
    /// read it with access to Photos, which is asked for the first time.
    private func openEditWithFile(_ file: URL, askedForAccess: Bool = false) {
        let readable: Bool = {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            try? handle.close()
            return true
        }()
        guard readable else {
            if askedForAccess {
                alert = AlertInfo(title: "AOK-ImageTool can't read the photo Photos handed over",
                                  message: "Allow it in System Settings ▸ Privacy & Security ▸ Photos, or use File ▸ Open from Photos… instead.")
            } else {
                Task {
                    try? await PhotosLibrary.requestAccess()
                    openEditWithFile(file, askedForAccess: true)
                }
            }
            return
        }
        openFolder(file.deletingLastPathComponent(), selecting: file, restrictedTo: [file])
        showToast("Editing a photo from Photos: Save sends your changes back to it", systemImage: "photo.on.rectangle")
    }

    func openFolder(_ folder: URL, selecting: URL?, restrictedTo: Set<URL>? = nil) {
        stopSlideshow()
        activeTool = nil
        folderURL = folder.standardizedFileURL
        self.restrictedTo = restrictedTo
        expandedStacks = []
        stackFront = [:]
        if !PhotosRoundTrip.isFromPhotos(folder) { RecentFolders.add(folder) }
        watcher.watch(folder)
        if !searchText.isEmpty { searchText = "" }
        flagFilter = .all
        intelligence.folderDidChange(folder)

        // Unsaved edits from an earlier session, for files that haven't changed since.
        let restored = PendingEdits.shared.restore(in: folder, recursive: includeSubfolders, restrictedTo: restrictedTo)
        for (url, e) in restored where edits[url] == nil { edits[url] = e }
        window?.isDocumentEdited = hasUnsavedEdits

        // Show the requested file right away while the (possibly large) folder scan runs.
        if let selecting, let item = FolderScanner.item(for: selecting.standardizedFileURL) {
            allItems = [item]
            items = [item]
            currentIndex = 0
            loadCurrent()
        } else {
            allItems = []
            items = []
            currentIndex = nil
            clearDisplay()
        }
        rescan(selecting: selecting?.standardizedFileURL)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = SupportedFormats.readableTypes + [.folder]
        panel.message = "Choose images or a folder"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.open(panel.urls)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    func rescan(selecting: URL? = nil) {
        guard let folder = folderURL else { return }
        scanTask?.cancel()
        isScanning = true
        let recursive = includeSubfolders
        let hidden = Prefs.showHiddenFiles
        let restricted = restrictedTo
        scanTask = Task {
            let scanned = await Task.detached(priority: .userInitiated) { () -> [ImageItem] in
                // Chosen files: just those (no need to read the folder, which may not even be allowed).
                if let restricted { return restricted.compactMap(FolderScanner.item(for:)) }
                return (try? FolderScanner.scan(folder: folder, recursive: recursive, showHidden: hidden)) ?? []
            }.value
            guard !Task.isCancelled, folder == folderURL else { return }
            isScanning = false
            var dates: [URL: Date] = [:]
            var previousModified: [URL: Date] = [:]
            for item in allItems {
                if let d = item.dateTaken { dates[item.url] = d }
                if let m = item.modificationDate { previousModified[item.url] = m }
            }
            // Files changed by another app: drop stale decodes/thumbnails.
            var currentChanged = false
            for item in scanned {
                if let old = previousModified[item.url], old != item.modificationDate {
                    ImagePipeline.shared.invalidate(item.url)
                    ThumbnailCache.shared.invalidate(item.url)
                    EditRenderer.shared.forget(item.url)
                    if item.url == currentURL { currentChanged = true }
                }
            }
            if currentChanged { decoded = nil }
            allItems = scanned.map { item in
                var item = item
                item.dateTaken = dates[item.url]
                return item
            }
            // (The image now on screen: the user may have moved on while the folder was scanned.)
            applySortAndFilter(selecting: selecting ?? currentURL)
            if sortKey == .dateTaken { loadDatesTaken() }
            intelligence.itemsDidChange()
        }
    }

    func applySortAndFilter(selecting target: URL? = nil) {
        let before = currentURL
        defer { currentImageMoved(from: before) }
        let keep = target ?? currentURL
        var sorted = FolderScanner.sort(allItems, by: sortKey, ascending: sortAscending, scores: intelligence.qualityScores)
        let distances = intelligence.similarityDistances
        if intelligence.similarityReference != nil, !distances.isEmpty {
            sorted = Array(allItems.filter { distances[$0.url] != nil }
                .sorted { distances[$0.url]! < distances[$1.url]! }
                .prefix(60))
        }
        var filtered = sorted.filter { flagFilter.includes($0.flag) }
        let query = trimmedSearch
        if !query.isEmpty {
            let terms = intelligence.searchTerms(for: query)
            filtered = filtered.filter { intelligence.matches($0, terms: terms) }
        }
        let stacked = stacked(filtered, keeping: keep)
        items = stacked.items
        stacks = stacked.stacks
        stackOf = stacked.stackOf
        let present = Set(items.map(\.url))
        selection = selection.intersection(present)

        if let keep, let idx = items.firstIndex(where: { $0.url == keep }) {
            currentIndex = idx
            if decoded?.url != keep || display == nil { loadCurrent() }
        } else if items.isEmpty {
            currentIndex = nil
            clearDisplay()
        } else {
            currentIndex = min(currentIndex ?? 0, items.count - 1)
            loadCurrent()
        }
    }

    private func sortKeyDidChange() {
        if sortKey == .dateTaken { loadDatesTaken() }
        if sortKey == .quality { intelligence.ensureIndexed(reason: .quality) }
        applySortAndFilter()
    }

    private func searchTextDidChange(_ old: String) {
        let query = trimmedSearch
        if !query.isEmpty { intelligence.ensureIndexed(reason: .search) }
        if query != old.trimmingCharacters(in: .whitespacesAndNewlines) { applySortAndFilter() }
    }

    private func loadDatesTaken() {
        let missing = allItems.filter { $0.dateTaken == nil }.map(\.url)
        guard !missing.isEmpty else { return }
        Task {
            let dates = await Task.detached(priority: .utility) { () -> [URL: Date] in
                var result: [URL: Date] = [:]
                for url in missing { if let d = FolderScanner.dateTaken(for: url) { result[url] = d } }
                return result
            }.value
            allItems = allItems.map { item in
                var item = item
                if item.dateTaken == nil { item.dateTaken = dates[item.url] }
                return item
            }
            if sortKey == .dateTaken { applySortAndFilter() }
        }
    }

    // MARK: - Navigation

    func next() { step(1) }
    func previous() { step(-1) }

    func first() {
        guard !items.isEmpty else { return }
        navigationDirection = 1
        show(index: 0)
    }

    func last() {
        guard !items.isEmpty else { return }
        navigationDirection = -1
        show(index: items.count - 1)
    }

    func step(_ delta: Int, wrap: Bool = Prefs.wrapAround) {
        guard !items.isEmpty else { return }
        guard let i = currentIndex else {
            show(index: 0)
            return
        }
        var n = i + delta
        if wrap {
            n = ((n % items.count) + items.count) % items.count
        } else {
            n = min(max(n, 0), items.count - 1)
        }
        guard n != i else {
            NSSound.beep()
            return
        }
        navigationDirection = delta >= 0 ? 1 : -1
        show(index: n)
    }

    func show(index: Int) {
        guard items.indices.contains(index) else { return }
        if activeTool != nil { activeTool = nil }
        currentIndex = index
        selection = [items[index].url]
        gridAnchor = index
        pageIndex = 0
        if showOriginal { showOriginal = false }
        loadCurrent()
        if let folderURL, !PhotosRoundTrip.isFromPhotos(folderURL) { LastViewed.remember(items[index].url, in: folderURL) }
    }

    /// When re-sorting, filtering or a rescan puts another image on screen, what `show(index:)` resets for a
    /// new image is reset too (an open tool belongs to the image it was opened on).
    private func currentImageMoved(from before: URL?) {
        gridAnchor = currentIndex
        guard currentURL != before else { return }
        if activeTool != nil { activeTool = nil }
        pageIndex = 0
        if showOriginal { showOriginal = false }
    }

    func select(_ url: URL) {
        if let i = items.firstIndex(where: { $0.url == url }) { return show(index: i) }
        // Inside a closed stack: it becomes the copy the stack shows.
        if let root = stackOf[url] {
            stackFront[root] = url
            applySortAndFilter(selecting: url)
        }
    }

    func nextPage() {
        guard pageIndex + 1 < pageCount else { return next() }
        pageIndex += 1
        loadCurrent()
    }

    func previousPage() {
        guard pageIndex > 0 else { return previous() }
        pageIndex -= 1
        loadCurrent()
    }

    // MARK: - Loading

    private func clearDisplay() {
        loadTask?.cancel()
        decoded = nil
        display = nil
        isLoading = false
        loadError = nil
    }

    func reloadCurrent() {
        if let url = currentURL {
            ImagePipeline.shared.invalidate(url)
            ThumbnailCache.shared.invalidate(url)
        }
        loadCurrent()
    }

    private func loadCurrent() {
        loadTask?.cancel()
        fullRenderTask?.cancel()
        // A tool belongs to the image it was opened on (another one may now be current: a removed file, an undo).
        if activeTool != nil, toolImage != currentURL { activeTool = nil }
        guard let item = currentItem else {
            clearDisplay()
            return
        }
        let url = item.url
        let page = pageIndex
        let hdr = Prefs.hdrEnabled
        loadError = nil
        hasLiveText = false
        let now = Date()
        let rapid = now.timeIntervalSince(lastNavigation) < 0.15
        lastNavigation = now

        if let hit = ImagePipeline.shared.cached(url, page: page, hdr: hdr) {
            isLoading = false
            setDecoded(hit)
            return
        }

        isLoading = true
        decoded = nil
        let thumbnail = ThumbnailCache.shared.bestCached(url)
        loadTask = Task {
            let header = await Task.detached(priority: .userInitiated) { ImageDecoder.header(url: url) }.value
            guard !Task.isCancelled else { return }
            if let header, let thumbnail { showPlaceholder(thumbnail, url: url, size: header.pixelSize) }

            // While keys are auto-repeating, only show thumbnails; decode once the user pauses.
            if rapid {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
            }

            if let header, let preview = await Task.detached(priority: .userInitiated, operation: { ImageDecoder.quickPreview(url: url, header: header) }).value {
                guard !Task.isCancelled else { return }
                showPlaceholder(preview, url: url, size: header.pixelSize)
            }

            do {
                let image = try await ImagePipeline.shared.image(for: url, page: page, hdr: hdr)
                guard !Task.isCancelled, currentURL == url else { return }
                isLoading = false
                setDecoded(image)
            } catch {
                guard !Task.isCancelled, currentURL == url else { return }
                isLoading = false
                display = nil
                loadError = error.localizedDescription
            }
        }
    }

    private func showPlaceholder(_ image: CGImage, url: URL, size: CGSize) {
        guard currentURL == url else { return }
        displayRevision += 1
        display = DisplayImage(url: url, image: image, logicalSize: size, isPlaceholder: true, isHDR: false,
                               hasAlpha: false, animate: false, contentKey: 0, revision: displayRevision)
    }

    private func setDecoded(_ image: DecodedImage) {
        decoded = image
        refreshDisplay()
        refillExtensionIfNeeded()
        if DebugHooks.extendOnLaunch, activeTool == nil { activeTool = .crop }
        if DebugHooks.scene != nil { DebugScenes.apply(to: self) }
        schedulePrefetch()
        intelligence.imageDidChange()
    }

    private func schedulePrefetch() {
        guard let i = currentIndex, items.count > 1 else { return }
        let dir = navigationDirection
        var urls: [URL] = []
        for offset in [dir, 2 * dir, -dir] {
            var j = i + offset
            if Prefs.wrapAround { j = ((j % items.count) + items.count) % items.count }
            if items.indices.contains(j), j != i { urls.append(items[j].url) }
        }
        ImagePipeline.shared.prefetch(urls, hdr: Prefs.hdrEnabled)
    }

    // MARK: - Display & edit rendering

    func refreshDisplay() {
        fullRenderTask?.cancel()
        guard let d = decoded, d.url == currentURL else { return }
        let e = currentEdits
        if e.isIdentity || showOriginal {
            displayRevision += 1
            display = DisplayImage(url: d.url, image: d.cgImage, logicalSize: d.pixelSize, isPlaceholder: false,
                                   isHDR: d.isHDR, hasAlpha: d.hasAlpha, animate: d.isAnimated,
                                   contentKey: contentKey(d, .identity), revision: displayRevision)
            enhanceDisplayIfNeeded()
            return
        }
        requestEditRender()
    }

    private func contentKey(_ d: DecodedImage, _ e: EditState) -> Int {
        var h = Hasher()
        h.combine(d.url)
        h.combine(d.pageIndex)
        h.combine(try? JSONEncoder().encode(e))
        return h.finalize()
    }

    /// Renders a proxy for interactive feedback, coalescing requests while one is in flight,
    /// then swaps in a full-resolution render once edits settle.
    private func requestEditRender() {
        if renderInFlight {
            renderDirty = true
            return
        }
        renderInFlight = true
        Task {
            repeat {
                renderDirty = false
                guard let d = decoded, d.url == currentURL, !showOriginal else { break }
                let e = currentEdits
                guard !e.isIdentity else { break }
                if e.cutout == .subject { loadSubjectMaskIfNeeded(d) }
                let output = await EditRenderer.shared.render(d, edits: e, maxDimension: Self.proxyDimension)
                if !renderDirty, let output, decoded === d, currentEdits == e, !showOriginal {
                    displayRevision += 1
                    display = DisplayImage(url: d.url, image: output.image, logicalSize: output.fullSize, isPlaceholder: false,
                                           isHDR: d.isHDR, hasAlpha: d.hasAlpha || e.hasTransparency, animate: false,
                                           contentKey: contentKey(d, e), revision: displayRevision)
                    scheduleFullRender(d, e)
                    enhanceDisplayIfNeeded()
                }
            } while renderDirty
            renderInFlight = false
        }
    }

    /// A background removal restored from an earlier session has no mask yet: shows the image
    /// without it meanwhile, computes it, and re-renders. Drops the cutout if no subject is found.
    private func loadSubjectMaskIfNeeded(_ d: DecodedImage) {
        let url = d.url
        guard MaskStore.shared.subjectMask(for: url) == nil, subjectMaskLoads.insert(url).inserted else { return }
        Task {
            defer { subjectMaskLoads.remove(url) }
            do {
                try await MaskStore.shared.prepare(edits[url] ?? .identity, for: d)
            } catch {
                if var e = edits[url], e.cutout == .subject {
                    e.removeCutout()
                    setEditsDictionary(url, e.isIdentity ? nil : e)
                    window?.isDocumentEdited = hasUnsavedEdits
                }
            }
            if decoded === d { refreshDisplay() }
        }
    }

    private func scheduleFullRender(_ d: DecodedImage, _ e: EditState) {
        fullRenderTask?.cancel()
        guard max(d.pixelSize.width, d.pixelSize.height) > Self.proxyDimension else { return }
        fullRenderTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard let output = await EditRenderer.shared.render(d, edits: e, maxDimension: nil) else { return }
            guard !Task.isCancelled, decoded === d, currentEdits == e, !showOriginal else { return }
            displayRevision += 1
            display = DisplayImage(url: d.url, image: output.image, logicalSize: output.fullSize, isPlaceholder: false,
                                   isHDR: d.isHDR, hasAlpha: d.hasAlpha || e.hasTransparency, animate: false,
                                   contentKey: contentKey(d, e), revision: displayRevision)
        }
    }

    /// With "Sharpen Enlarged Images with AI" on, swaps in an AI-upscaled copy of an image shown larger
    /// than its pixels, at the shown scale. Same logical size, so zoom and Live Text don't change.
    func enhanceDisplayIfNeeded() {
        enhanceTask?.cancel()
        guard Prefs.aiEnhanceEnlarged, SuperResolution.isSupported else { return }
        enhanceTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let shown = display, !shown.isPlaceholder, !shown.animate, !shown.isHDR else { return }
            let base = (enhanced?.revision == shown.revision ? enhanced?.base : nil) ?? shown.image
            let scale = min(CGFloat(SuperResolution.factor), zoomPercent / 100)
            let current = CGFloat(shown.image.width) / CGFloat(max(base.width, 1))
            guard scale > 1.15, scale > current * 1.1,
                  abs(CGFloat(base.width) - shown.logicalSize.width) < 1,
                  SuperResolution.fits(width: base.width, height: base.height),
                  SuperResolution.modelState == .ready else { return }
            guard let image = try? await SuperResolution.upscale(base, scale: scale),
                  !Task.isCancelled, display?.revision == shown.revision else { return }
            displayRevision += 1
            enhanced = (displayRevision, base)
            display = DisplayImage(url: shown.url, image: image, logicalSize: shown.logicalSize, isPlaceholder: false,
                                   isHDR: false, hasAlpha: shown.hasAlpha, animate: false,
                                   contentKey: shown.contentKey, revision: displayRevision)
        }
    }

    // MARK: - Canvas callbacks

    func zoomDidChange(percent: Double, isFit: Bool) {
        if abs(zoomPercent - percent) > 0.5 {
            zoomPercent = percent
            enhanceDisplayIfNeeded()
        }
        if isFitMode != isFit { isFitMode = isFit }
    }

    func liveTextDidUpdate(hasText: Bool) {
        hasLiveText = hasText
    }

    func zoomIn() { viewMode == .grid ? adjustGridSize(by: 1.2) : canvas?.zoomIn() }
    func zoomOut() { viewMode == .grid ? adjustGridSize(by: 1 / 1.2) : canvas?.zoomOut() }
    func zoomToFit() { canvas?.fit() }
    func zoomToActualSize() { canvas?.actualSize() }

    func toggleFitActual() {
        if isFitMode { canvas?.actualSize() } else { canvas?.fit() }
    }

    func adjustGridSize(by factor: Double) {
        gridThumbnailSize = min(max(gridThumbnailSize * factor, 80), 420)
    }

    // MARK: - Modes

    func toggleInspector(_ tab: InspectorTab) {
        if showInspector && inspectorTab == tab {
            showInspector = false
        } else {
            inspectorTab = tab
            showInspector = true
        }
    }

    func toggleViewMode() {
        viewMode = viewMode == .viewer ? .grid : .viewer
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    func toggleSlideshow() {
        isSlideshowRunning ? stopSlideshow() : startSlideshow()
    }

    func startSlideshow() {
        guard items.count > 1 else { return }
        viewMode = .viewer
        activeTool = nil
        isSlideshowRunning = true
        isSlideshowPaused = false
        if !isFullScreen {
            enteredFullScreenForSlideshow = true
            window?.toggleFullScreen(nil)
        }
        runSlideshowTimer()
        showToast("Slideshow — Space to pause, Esc to stop", systemImage: "play.rectangle")
    }

    private func runSlideshowTimer() {
        slideshowTask?.cancel()
        slideshowTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Prefs.slideshowInterval))
                guard !Task.isCancelled else { break }
                step(1, wrap: true)
            }
        }
    }

    func toggleSlideshowPause() {
        guard isSlideshowRunning else { return }
        isSlideshowPaused.toggle()
        if isSlideshowPaused {
            slideshowTask?.cancel()
            showToast("Paused", systemImage: "pause.fill")
        } else {
            runSlideshowTimer()
            showToast("Playing", systemImage: "play.fill")
        }
    }

    func stopSlideshow() {
        guard isSlideshowRunning else { return }
        slideshowTask?.cancel()
        isSlideshowRunning = false
        isSlideshowPaused = false
        if enteredFullScreenForSlideshow, isFullScreen { window?.toggleFullScreen(nil) }
        enteredFullScreenForSlideshow = false
    }

    // MARK: - Toasts

    func showToast(_ text: String, systemImage: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        toast = ToastMessage(text: text, systemImage: systemImage, actionTitle: actionTitle)
        toastAction = action
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(action == nil ? 2.5 : 5))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    func performToastAction() {
        toastAction?()
        toastAction = nil
        withAnimation { toast = nil }
    }

    func dismissToast() {
        toast = nil
    }

    func showError(_ title: String, _ error: Error) {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }

    // MARK: - Mutating the item list (used by file operations)

    func updateItem(_ url: URL, _ change: (inout ImageItem) -> Void) {
        if let i = allItems.firstIndex(where: { $0.url == url }) { change(&allItems[i]) }
        if let i = items.firstIndex(where: { $0.url == url }) { change(&items[i]) }
    }

    func removeItems(_ urls: Set<URL>) {
        let oldIndex = currentIndex ?? 0
        let currentRemoved = currentURL.map(urls.contains) ?? false
        allItems.removeAll { urls.contains($0.url) }
        if urls.contains(where: { stackOf[$0] != nil }) {
            // A stack shows its next copy in place of a removed one.
            for url in urls where edits[url] != nil { setEditsDictionary(url, nil) }
            applySortAndFilter(selecting: currentRemoved ? nil : currentURL)
            return
        }
        items.removeAll { urls.contains($0.url) }
        selection.subtract(urls)
        for url in urls where edits[url] != nil { setEditsDictionary(url, nil) }
        if items.isEmpty {
            currentIndex = nil
            clearDisplay()
        } else if currentRemoved {
            currentIndex = min(oldIndex, items.count - 1)
            if let url = currentURL { selection = [url] }
            loadCurrent()
        } else if let url = decoded?.url, let i = items.firstIndex(where: { $0.url == url }) {
            currentIndex = i
        }
    }

    /// Puts another item (one of a stack's copies) in the list at `index`.
    func replaceListedItem(at index: Int, with item: ImageItem) {
        items[index] = item
    }

    /// Adds a file this window made (a copy, an export) to the list, if it belongs in it.
    func insertItem(_ item: ImageItem, select: Bool) {
        guard let folderURL else { return }
        let parent = item.url.deletingLastPathComponent().standardizedFileURL
        guard parent == folderURL || (includeSubfolders && parent.path.hasPrefix(folderURL.path + "/")) else { return }
        if restrictedTo != nil { restrictedTo?.insert(item.url.standardizedFileURL) }
        allItems.removeAll { $0.url == item.url }
        allItems.append(item)
        applySortAndFilter(selecting: select ? item.url : nil)
    }

    func replaceURL(_ old: URL, with newItem: ImageItem) {
        if let e = edits.removeValue(forKey: old) {
            edits[newItem.url] = e
            PendingEdits.shared.move(from: old, to: newItem.url)
        }
        if let i = allItems.firstIndex(where: { $0.url == old }) { allItems[i] = newItem }
        if let i = items.firstIndex(where: { $0.url == old }) { items[i] = newItem }
        if selection.remove(old) != nil { selection.insert(newItem.url) }
        if stackOf[old] != nil {
            if expandedStacks.remove(old) != nil { expandedStacks.insert(newItem.url) }
            if let front = stackFront.removeValue(forKey: old) { stackFront[newItem.url] = front }
            for (root, front) in stackFront where front == old { stackFront[root] = newItem.url }
            applySortAndFilter()
        }
        ImagePipeline.shared.invalidate(old)
        ThumbnailCache.shared.invalidate(old)
        if decoded?.url == old { loadCurrent() }
    }

    // Internal setter for edit bookkeeping in other files. Also keeps the copy that survives a relaunch current.
    func setEditsDictionary(_ url: URL, _ state: EditState?) {
        edits[url] = state
        // (Not for a photo opened from Photos: its working file is gone after a relaunch.)
        guard !PhotosLibrary.isWorkingFile(url) else { return }
        PendingEdits.shared.set(state, for: url, modificationDate: allItems.first { $0.url == url }?.modificationDate)
    }
}

/// Weak registry of open viewer windows (used to warn about unsaved edits on quit).
final class ViewerRegistry {
    static let shared = ViewerRegistry()
    private var models: [WeakModel] = []

    private struct WeakModel {
        weak var model: ViewerModel?
    }

    func add(_ model: ViewerModel) {
        models.removeAll { $0.model == nil }
        models.append(WeakModel(model: model))
    }

    func remove(_ model: ViewerModel) {
        models.removeAll { $0.model == nil || $0.model === model }
    }

    var all: [ViewerModel] { models.compactMap(\.model) }
}
