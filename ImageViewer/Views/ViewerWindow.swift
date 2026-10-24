import ImagePlayground
import SwiftUI

struct ViewerWindow: View {
    @State private var model = ViewerModel()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            FolderSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 340)
        } detail: {
            MainContent()
                .toolbar { ViewerToolbar() }
                .inspector(isPresented: $model.showInspector) {
                    InspectorPanel()
                        .inspectorColumnWidth(min: 290, ideal: 330, max: 460)
                }
        }
        .focusedSceneValue(\.viewer, model)
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.windowSubtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search images"))
        .onSubmit(of: .search) { model.focusCanvas() }
        .onOpenURL { model.enqueueOpen($0) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .background(WindowAccessor { model.attach(to: $0) })
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return !urls.isEmpty
        }
        .sheet(item: $model.exportRequest) { ExportSheet(request: $0) }
        .sheet(item: $model.renameTarget) { RenameSheet(item: $0) }
        .sheet(isPresented: $model.showShortcuts) { ShortcutsSheet() }
        .sheet(isPresented: $model.showDuplicates) { DuplicatesSheet() }
        .sheet(isPresented: $model.showGenerateBackground) { GenerateBackgroundSheet() }
        .sheet(isPresented: $model.showBlackAndWhite) { BlackAndWhiteSheet() }
        .sheet(isPresented: $model.showFixBlur) { FixBlurSheet() }
        .sheet(isPresented: $model.showNewImage) { NewImageSheet() }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert?.message ?? "")
        }
        .modifier(PlaygroundSheet(model: model))
        .onAppear {
            let pending = PendingOpen.take()
            if !pending.isEmpty { model.open(pending) }
            if DebugScenes.showsSidebar { sidebarVisibility = .all }
        }
        // Outermost, so sheets, alerts, toolbar and inspector all see the model.
        .environment(model)
    }
}

/// Image Playground: "Reimagine" (from the current image), a scene to put behind a cutout
/// (Intelligence ▸ Background ▸ Generate…), and a new picture from New Image from Description's description. The sheets hang off a background view, so switching between
/// having an image and not doesn't rebuild the window.
private struct PlaygroundSheet: ViewModifier {
    @Bindable var model: ViewerModel

    func body(content: Content) -> some View {
        if #available(macOS 15.1, *) {
            content.background { PlaygroundSheets(model: model) }
        } else {
            content
        }
    }
}

@available(macOS 15.1, *)
private struct PlaygroundSheets: View {
    @Bindable var model: ViewerModel

    var body: some View {
        Group {
            if let url = model.currentURL {
                Color.clear.imagePlaygroundSheet(isPresented: $model.showPlayground, concepts: [], sourceImageURL: url) { result in
                    model.intelligence.savePlaygroundImage(from: result)
                }
            } else {
                Color.clear.imagePlaygroundSheet(isPresented: $model.showPlayground, concepts: []) { result in
                    model.intelligence.savePlaygroundImage(from: result)
                }
            }
        }
        .background {
            Color.clear.imagePlaygroundSheet(isPresented: $model.showBackgroundPlayground, concepts: []) { url in
                model.useGeneratedBackground(from: url)
            }
        }
        .background {
            Color.clear.imagePlaygroundSheet(isPresented: $model.showNewImagePlayground, concept: model.newImageDescription) { url in
                model.saveNewImage(from: url, description: model.newImageDescription)
            }
        }
    }
}

struct MainContent: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        Group {
            if model.folderURL == nil {
                WelcomeView()
            } else {
                VStack(spacing: 0) {
                    if let reference = model.intelligence.similarityReference {
                        SimilarityBanner(reference: reference)
                    }
                    ZStack {
                        switch model.viewMode {
                        case .viewer: ViewerPane()
                        case .grid: GridPane()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.viewMode == .viewer, model.showFilmstrip, !model.items.isEmpty, !model.isSlideshowRunning {
                        Divider()
                        FilmstripView()
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
    }
}

struct ViewerPane: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        ZStack {
            ImageCanvas(model: model)

            if let tool = model.activeTool {
                switch tool {
                case .crop: CropEditor()
                case .selectObject: ObjectSelectEditor()
                case .removeObjects: RemoveObjectsEditor()
                case .changeObjects: RemoveObjectsEditor(mode: .change)
                case .cloneHeal: RemoveObjectsEditor(mode: .clone)
                }
            } else {
                stateOverlay
                CanvasBadges()
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if model.items.isEmpty && !model.isScanning {
            if !model.trimmedSearch.isEmpty {
                ContentUnavailableView.search(text: model.trimmedSearch)
            } else if model.flagFilter != .all {
                ContentUnavailableView("No \(model.flagFilter.title)", systemImage: "flag.slash",
                                       description: Text("Press P to pick or X to reject images."))
            } else {
                ContentUnavailableView("No Images", systemImage: "photo.on.rectangle.angled",
                                       description: Text("This folder doesn't contain any images AOK-ImageTool can open."))
            }
        } else if let error = model.loadError {
            ContentUnavailableView("Can't Display Image", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.isLoading && model.display == nil {
            ProgressView().controlSize(.large)
        }
    }
}

/// Small status overlays on the canvas: flag, edit state, HDR, pages, AI work in progress.
struct CanvasBadges: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 6) {
                if let item = model.currentItem, item.flag != .none {
                    Badge(text: item.flag == .pick ? "Pick" : "Reject",
                          systemImage: item.flag == .pick ? "flag.fill" : "xmark.circle.fill",
                          tint: item.flag == .pick ? .green : .red)
                }
                if model.showOriginal {
                    Badge(text: "Original", systemImage: "eye", tint: .orange)
                } else if !model.currentEdits.isIdentity {
                    Badge(text: "Edited", systemImage: "slider.horizontal.3", tint: .accentColor)
                }
                if model.decoded?.isHDR == true, model.display?.isHDR == true {
                    Badge(text: "HDR", systemImage: "sun.max.fill", tint: .yellow)
                }
                if model.lockZoom {
                    Badge(text: "Zoom Locked", systemImage: "lock.fill", tint: .secondary)
                }
                Spacer()
                if let busy = model.intelligence.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassBackground(in: .capsule)
                } else if let progress = model.extendProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(model.currentEdits.effectiveExtendMethod == .generate ? "Generating" : "Extending")… \(Int(progress * 100))%")
                            .font(.callout).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassBackground(in: .capsule)
                } else if model.isLoading && model.display != nil {
                    ProgressView().controlSize(.small)
                        .padding(8)
                        .glassBackground(in: .circle)
                }
            }
            Spacer()
            if model.pageCount > 1 {
                HStack(spacing: 12) {
                    Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                        .disabled(model.pageIndex == 0)
                    Text("Page \(model.pageIndex + 1) of \(model.pageCount)")
                        .monospacedDigit()
                    Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                        .disabled(model.pageIndex + 1 >= model.pageCount)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassBackground(in: .capsule)
            }
        }
        .padding(12)
        .allowsHitTesting(model.pageCount > 1)
    }
}

struct Badge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .glassBackground(in: .capsule)
    }
}

struct SimilarityBanner: View {
    @Environment(ViewerModel.self) private var model
    let reference: URL

    var body: some View {
        HStack {
            Image(systemName: "sparkles.rectangle.stack")
            Text("Images similar to **\(reference.lastPathComponent)**")
            Spacer()
            Button("Show All") { model.intelligence.clearSimilar() }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}

struct ToastView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 10) {
                if let icon = toast.systemImage { Image(systemName: icon) }
                Text(toast.text).lineLimit(2)
                if let action = toast.actionTitle {
                    Button(action) { model.performToastAction() }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassBackground(in: .capsule)
            .padding(.bottom, model.viewMode == .viewer && model.showFilmstrip ? 100 : 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .onTapGesture { model.dismissToast() }
        }
    }
}

/// Gives the model its hosting NSWindow (for key handling, full screen, sheets).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Image Playground (macOS 15.1+, on Macs with Apple Intelligence).
enum PlaygroundSupport {
    static var isAvailable: Bool {
        if #available(macOS 15.1, *) { return ImagePlaygroundViewController.isAvailable }
        return false
    }
}
