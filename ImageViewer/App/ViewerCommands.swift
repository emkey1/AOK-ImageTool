import ImagePlayground
import SwiftUI
import UniformTypeIdentifiers

struct ViewerCommands: Commands {
    @FocusedValue(\.viewer) private var viewer: ViewerModel?
    @Environment(\.openWindow) private var openWindow
    private var supportsImagePlayground: Bool { PlaygroundSupport.isAvailable }
    @AppStorage(PrefKey.pixelatedZoom) private var pixelated = false
    @AppStorage(PrefKey.upscaleSmallImages) private var enlargeSmall = false
    @AppStorage(PrefKey.aiEnhanceEnlarged) private var aiEnhance = false
    @AppStorage(PrefKey.canvasBackground) private var background = CanvasBackground.dark.rawValue
    @AppStorage(PrefKey.upscaledAnimationFormat) private var animationFormat = Animation.Container.gif.rawValue

    private var hasImage: Bool { viewer?.currentItem != nil }
    private var hasEdits: Bool { !(viewer?.currentEdits.isIdentity ?? true) }
    private var canEdit: Bool { viewer?.canEdit ?? false }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkNow() }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "viewer") }
                .keyboardShortcut("n")
            Button("Open…") { open() }
                .keyboardShortcut("o")
                .modifierKeyAlternate(.option) {
                    Button("Open in New Window…") { open(inNewWindow: true) }
                        .keyboardShortcut("o", modifiers: [.command, .option])
                }
            Button("New Folder…") { viewer?.beginNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(viewer == nil)
            Button("Open from Photos…") { viewer?.openFromPhotos() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(viewer == nil)
            Button("Import from Photos…") { viewer?.importFromPhotos() }
                .disabled(viewer == nil)
            Button("New Image from Description…") { viewer?.beginNewImage() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(viewer == nil)
            Menu("Open Recent") {
                ForEach(RecentFolders.all, id: \.self) { url in
                    Button(url.lastPathComponent) { open([url]) }
                        .modifierKeyAlternate(.option) {
                            Button("\(url.lastPathComponent) in a New Window") { open([url], inNewWindow: true) }
                        }
                }
                Divider()
                Button("Clear Menu") { RecentFolders.clear() }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { viewer?.save() }
                .keyboardShortcut("s")
                .disabled(!hasEdits)
            Button("Export…") { viewer?.requestExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!hasImage)
            Button("Revert to Original") { viewer?.revertEdits() }
                .disabled(!hasEdits)
            Button("Revert All Edited Images…") { viewer?.revertAllEdits() }
                .disabled(!(viewer?.hasUnsavedEdits ?? false))
            Divider()
            Button("Rename…") { viewer?.beginRename() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!hasImage)
            Button("Move To…") { viewer?.moveOrCopySelection(copy: false) }
                .disabled(!hasImage)
            Button("Copy To…") { viewer?.moveOrCopySelection(copy: true) }
                .disabled(!hasImage)
            Button("Show in Finder") { viewer?.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(viewer?.folderURL == nil)
            Button("Set as Desktop Picture") { viewer?.setAsDesktopPicture() }
                .disabled(!hasImage)
            Divider()
            Button("Move to Trash") { viewer?.trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasImage)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { viewer?.printImage() }
                .keyboardShortcut("p")
                .disabled(!hasImage)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            // (⌘V does this too while the image or grid has the focus; see handleKeyDown.)
            Button("Paste as New Image") { viewer?.pasteImage() }
                .disabled(viewer == nil)
            Button("Copy Image") { viewer?.copyImage() }
                .disabled(!hasImage)
            Button("Copy Subject") { viewer?.intelligence.copySubject() }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                .disabled(!hasImage)
            Divider()
            Button("Copy Edits") { viewer?.copyEdits() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasEdits)
            Button("Paste Edits") { viewer?.pasteEdits() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(viewer?.actionTargets.isEmpty ?? true || EditClipboard.shared.adjustments == nil)
            Divider()
            Button("Copy File Path") { viewer?.copyPath() }
                .disabled(!hasImage)
        }

        CommandGroup(before: .toolbar) {
            Button("Viewer") { viewer?.viewMode = .viewer }
                .keyboardShortcut("1")
            Button("Grid") { viewer?.viewMode = .grid }
                .keyboardShortcut("2")
            Toggle("Show Filmstrip", isOn: Binding(get: { viewer?.showFilmstrip ?? true }, set: { viewer?.showFilmstrip = $0 }))
            Divider()
            Button("Zoom In") { viewer?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { viewer?.zoomOut() }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { viewer?.zoomToFit() }
                .keyboardShortcut("9")
            Button("Actual Size") { viewer?.zoomToActualSize() }
                .keyboardShortcut("0")
            Toggle("Enlarge Small Images to Fit Window", isOn: $enlargeSmall)
                .keyboardShortcut("9", modifiers: [.command, .option])
            if SuperResolution.isSupported {
                Toggle("Sharpen Enlarged Images with AI", isOn: Binding(get: { aiEnhance }, set: { viewer?.setAIEnhancement($0) }))
                    .disabled(viewer == nil)
            }
            Toggle("Lock Zoom Across Images", isOn: Binding(get: { viewer?.lockZoom ?? false }, set: { viewer?.lockZoom = $0 }))
            Toggle("Show Pixels When Zoomed In", isOn: $pixelated)
            Picker("Background", selection: $background) {
                ForEach(CanvasBackground.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Divider()
            Picker("Sort By", selection: Binding(get: { viewer?.sortKey ?? .name }, set: { viewer?.sortKey = $0 })) {
                ForEach(SortKey.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Reverse Order", isOn: Binding(get: { !(viewer?.sortAscending ?? true) }, set: { viewer?.sortAscending = !$0 }))
            Picker("Show", selection: Binding(get: { viewer?.flagFilter ?? .all }, set: { viewer?.flagFilter = $0 })) {
                ForEach(FlagFilter.byFlag) { Text($0.title).tag($0) }
                    Divider()
                    ForEach(FlagFilter.byRating) { Text($0.title).tag($0) }
            }
            Toggle("Include Subfolders", isOn: Binding(get: { viewer?.includeSubfolders ?? false }, set: { viewer?.includeSubfolders = $0 }))
            Toggle("Stack Copies with Originals", isOn: Binding(get: { viewer?.stacksEnabled ?? true }, set: { viewer?.stacksEnabled = $0 }))
            Divider()
            Button(viewer?.isSlideshowRunning == true ? "Stop Slideshow" : "Start Slideshow") { viewer?.toggleSlideshow() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Show Info") { viewer?.toggleInspector(.info) }
                .keyboardShortcut("i")
            Button("Show Adjustments") { viewer?.toggleInspector(.adjust) }
                .keyboardShortcut("e")
            Button("Show Intelligence") { viewer?.toggleInspector(.intelligence) }
                .keyboardShortcut("j")
            Divider()
        }

        CommandMenu("Go") {
            Button("Next Image") { viewer?.next() }
            Button("Previous Image") { viewer?.previous() }
            Button("First Image") { viewer?.first() }
            Button("Last Image") { viewer?.last() }
            Divider()
            Button("Next Page") { viewer?.nextPage() }
                .disabled((viewer?.pageCount ?? 1) < 2)
            Button("Previous Page") { viewer?.previousPage() }
                .disabled((viewer?.pageCount ?? 1) < 2)
            Divider()
            // ⌥← and ⌥→ (handled with the single-key shortcuts, so they still move by word in text fields).
            Button("Newer Copy in Stack") { viewer?.stepInStack(-1) }
                .disabled((viewer?.currentStackPosition?.index ?? 0) == 0)
            Button("Older Copy in Stack") { viewer?.stepInStack(1) }
                .disabled(viewer?.currentStackPosition.map { $0.index + 1 >= $0.count } ?? true)
            Button(viewer?.currentURL.map { viewer?.isStackExpanded($0) ?? false } ?? false ? "Close Stack" : "Show All Copies in Stack") {
                if let url = viewer?.currentURL { viewer?.toggleStack(url) }
            }
            .disabled(viewer?.currentStackPosition == nil)
            Divider()
            Button("Enclosing Folder") { viewer?.openEnclosingFolder() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(viewer?.folderURL == nil)
            Button("Next Folder") { viewer?.openSiblingFolder(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(viewer?.folderURL == nil)
            Button("Previous Folder") { viewer?.openSiblingFolder(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(viewer?.folderURL == nil)
        }

        CommandMenu("Image") {
            Button("Rotate Left") { viewer?.rotate(clockwise: false) }
                .keyboardShortcut("l")
                .disabled(!canEdit)
            Button("Rotate Right") { viewer?.rotate(clockwise: true) }
                .keyboardShortcut("r")
                .disabled(!canEdit)
            Button("Flip Horizontal") { viewer?.flip(horizontal: true) }
                .disabled(!canEdit)
            Button("Flip Vertical") { viewer?.flip(horizontal: false) }
                .disabled(!canEdit)
            Divider()
            Button("Crop & Straighten…") { viewer?.viewMode = .viewer; viewer?.activeTool = .crop }
                .keyboardShortcut("k")
                .disabled(!canEdit)
            Button("Clone & Heal…") { viewer?.beginCloneHeal() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!(viewer?.canRemoveObjects ?? false))
                .help("Paint with what's copied from elsewhere in the picture, blended in")
            Button("Auto Enhance") { viewer?.toggleAutoEnhance() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!canEdit)
            Button("Adjust Color…") { viewer?.inspectorTab = .adjust; viewer?.showInspector = true }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!hasImage)
            if GenerativeModel.isSupported {
                Button(Colorizer.isInstalled ? "Colorize" : "Colorize…") { viewer?.colorizeCurrent() }
                    .disabled(!hasImage)
                    .help("Save a color version of a black and white photo next to it")
            }
            Button("Black & White…") { viewer?.showBlackAndWhite = true }
                .disabled(!canEdit)
                .help("Save a black and white copy next to the original")
            if GenerativeModel.isSupported {
                Button("Fix Blur…") { viewer?.beginFixBlur() }
                    .disabled(!(viewer?.canFixBlur ?? false) || !canEdit)
                    .help("Save a sharpened copy: camera shake or soft focus taken out, faces restored")
            }
            Toggle("Show Original", isOn: Binding(get: { viewer?.showOriginal ?? false }, set: { viewer?.showOriginal = $0 }))
                .disabled(!hasEdits)
            if SuperResolution.isSupported {
                Menu("Upscale with AI") {
                    ForEach(SuperResolution.offeredScales, id: \.self) { scale in
                        let estimate = viewer?.animationUpscale(by: scale)
                        Button(UpscaleMenu.title(scale, estimate)) { viewer?.upscaleCurrent(by: scale) }
                            .disabled(estimate?.allowed == false)
                    }
                    if viewer?.decoded?.isAnimated == true {
                        Divider()
                        Picker("Save Animation As", selection: $animationFormat) {
                            ForEach(Animation.Container.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    }
                }
                .disabled(!hasImage)
            }
            Divider()
            Menu("Flag") {
                Button("Pick") { viewer?.setFlag(.pick) }
                Button("Reject") { viewer?.setFlag(.reject) }
                Button("Unflag") { viewer?.setFlag(.none) }
                Divider()
                Button("Move Rejects to Trash…") { viewer?.trashRejects() }
            }
            .disabled(!hasImage)
        }

        CommandMenu("Intelligence") {
            Button("Describe Image") { showIntelligence(); viewer?.intelligence.describeCurrent() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!hasImage)
            Button("Ask About Image…") { showIntelligence() }
                .disabled(!hasImage)
            Button("Read Text in Image") { showIntelligence(); viewer?.intelligence.readTextCurrent() }
                .disabled(!hasImage)
            Divider()
            Button(viewer?.currentEdits.cutout != nil ? "Restore Background" : "Remove Background") { viewer?.intelligence.toggleRemoveBackground() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!canEdit)
            Menu("Background") {
                Button("Transparent") { viewer?.setBackground(nil, actionName: "Transparent Background") }
                Button("White") { viewer?.setBackground(.color(red: 1, green: 1, blue: 1, alpha: 1), actionName: "Background Color") }
                Button("Black") { viewer?.setBackground(.color(red: 0, green: 0, blue: 0, alpha: 1), actionName: "Background Color") }
                Button("Blurred Original") { viewer?.setBackground(.blur(amount: 0.5), actionName: "Blurred Background") }
                    .disabled(!(viewer?.canBlurOriginalBackground ?? false))
                Divider()
                Button("Picture…") { viewer?.chooseBackgroundPicture() }
                if GenerativeModel.isSupported {
                    // (Offers its model when it isn't installed yet.)
                    Button(supportsImagePlayground ? "Generate on This Mac…" : "Generate…") { viewer?.generateBackgroundOnThisMac() }
                }
                if supportsImagePlayground {
                    Button(GenerativeModel.isSupported ? "Generate with Image Playground…" : "Generate…") { viewer?.showBackgroundPlayground = true }
                }
                Divider()
                Toggle("Match Lighting", isOn: Binding(
                    get: { viewer?.currentEdits.matchLighting != nil },
                    set: { on in viewer?.updateEdits("Match Lighting") { $0.matchLighting = on ? 0.6 : nil } }
                ))
                .disabled(viewer?.currentEdits.background?.isPicture != true)
            }
            .disabled(!(viewer?.canAddBackground ?? false))
            Button("Select Object…") { viewer?.viewMode = .viewer; viewer?.activeTool = .selectObject }
                .disabled(!canEdit)
            Button("Remove Objects…") { viewer?.beginRemoveObjects() }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(!(viewer?.canRemoveObjects ?? false))
            Button("Change Objects…") { viewer?.beginChangeObjects() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!(viewer?.canRemoveObjects ?? false))
            Divider()
            // Extend opens with the fill used last (Generate, once its model is installed).
            Button("Extend…") { viewer?.beginExtend() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!(viewer?.canExtend ?? false))
            Button("Try Another Extend Fill") { viewer?.tryAnotherExtendFill() }
                .disabled(!(viewer?.currentEdits.cropExtendsBeyondImage ?? false))
            Divider()
            Button("Auto Straighten") { viewer?.intelligence.autoStraighten() }
                .disabled(!canEdit)
            Button("Smart Crop") { viewer?.intelligence.smartCrop() }
                .disabled(!canEdit)
            Button("Straighten Document") { viewer?.intelligence.fixPerspective() }
                .disabled(!canEdit)
            Divider()
            if supportsImagePlayground {
                Button("Reimagine in Image Playground…") { viewer?.showPlayground = true }
                    .disabled(!hasImage)
            }
            Divider()
            Button("Find Similar Images") { viewer?.intelligence.showSimilar() }
                .disabled(!hasImage)
            Button("Find Duplicates…") { viewer?.intelligence.findDuplicates() }
                .disabled(viewer?.folderURL == nil)
            Button("Rank Best Shots") { viewer?.sortKey = .quality }
                .disabled(viewer?.folderURL == nil)
            Button("Analyze Folder for Search") { viewer?.intelligence.analyzeFolder() }
                .disabled(viewer?.folderURL == nil)
        }

        CommandGroup(replacing: .help) {
            Button("\(GuideWindowController.appName) Guide") { GuideWindowController.shared.show() }
                .keyboardShortcut("?", modifiers: .command)
            Button("Editing") { GuideWindowController.shared.show(.editing) }
            Button("Extend & Generative Fill") { GuideWindowController.shared.show(.extend) }
            Button("Removing Objects") { GuideWindowController.shared.show(.remove) }
            Button("Apple Intelligence") { GuideWindowController.shared.show(.intelligence) }
            Divider()
            Button("Keyboard Shortcuts") { viewer?.showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
            Button("Release Notes") { Updater.showReleaseNotes() }
        }
    }

    private func showIntelligence() {
        viewer?.inspectorTab = .intelligence
        viewer?.showInspector = true
    }

    /// Opens in the window in front, or in a new one (as with no window open). With no `urls`, asks which.
    private func open(_ urls: [URL]? = nil, inNewWindow: Bool = false) {
        if let viewer, !inNewWindow {
            if let urls { viewer.open(urls) } else { viewer.showOpenPanel() }
            return
        }
        if let urls {
            PendingOpen.urls = urls
            openWindow(id: "viewer")
            return
        }
        let panel = ViewerModel.openPanel()
        if panel.runModal() == .OK {
            PendingOpen.urls = ViewerModel.chosen(in: panel)
            openWindow(id: "viewer")
        }
    }
}
