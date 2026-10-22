import SwiftUI

struct ViewerToolbar: ToolbarContent {
    @Environment(ViewerModel.self) private var model
    @AppStorage(PrefKey.upscaleSmallImages) private var enlargeSmall = false
    @AppStorage(PrefKey.aiEnhanceEnlarged) private var aiEnhance = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.previous() } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .help("Previous image (←)")
            .disabled(model.items.count < 2)

            Button { model.next() } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .help("Next image (→)")
            .disabled(model.items.count < 2)
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 })) {
                Label("Viewer", systemImage: "photo").tag(ViewMode.viewer)
                Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Viewer or grid (G)")
            .disabled(model.folderURL == nil)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if model.viewMode == .viewer {
                Menu {
                    Button("Zoom In") { model.zoomIn() }
                    Button("Zoom Out") { model.zoomOut() }
                    Divider()
                    Button("Zoom to Fit") { model.zoomToFit() }
                    Button("Actual Size (100%)") { model.zoomToActualSize() }
                    Divider()
                    Toggle("Enlarge Small Images to Fit Window", isOn: $enlargeSmall)
                    if SuperResolution.isSupported {
                        Toggle("Sharpen Enlarged Images with AI", isOn: Binding(get: { aiEnhance }, set: { model.setAIEnhancement($0) }))
                    }
                    Toggle("Lock Zoom Across Images", isOn: Binding(get: { model.lockZoom }, set: { model.lockZoom = $0 }))
                } label: {
                    Label("\(Int(model.zoomPercent.rounded()))%", systemImage: "plus.magnifyingglass")
                } primaryAction: {
                    model.toggleFitActual()
                }
                .help("Click to toggle fit / 100% (Z)")
                .disabled(model.display == nil)
            } else {
                Slider(value: Binding(get: { model.gridThumbnailSize }, set: { model.gridThumbnailSize = $0 }), in: 80...420)
                    .frame(width: 110)
                    .help("Thumbnail size")
            }

            Button { model.rotate(clockwise: false) } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .help("Rotate left (⌘L)")
            .disabled(!model.canEdit)

            Button {
                model.viewMode = .viewer
                model.activeTool = model.activeTool == .crop ? nil : .crop
            } label: {
                Label("Crop", systemImage: "crop")
            }
            .help("Crop & straighten (C)")
            .disabled(model.decoded == nil)

            Menu {
                Picker("Show", selection: Binding(get: { model.flagFilter }, set: { model.flagFilter = $0 })) {
                    ForEach(FlagFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Sort By", selection: Binding(get: { model.sortKey }, set: { model.sortKey = $0 })) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("Reverse Order", isOn: Binding(get: { !model.sortAscending }, set: { model.sortAscending = !$0 }))
                Toggle("Include Subfolders", isOn: Binding(get: { model.includeSubfolders }, set: { model.includeSubfolders = $0 }))
            } label: {
                Label("Sort & Filter", systemImage: model.flagFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Sort & filter")
            .disabled(model.folderURL == nil)

            if model.intelligence.isIndexing {
                ProgressView(value: model.intelligence.indexProgress ?? 0)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("Analyzing images with Apple Intelligence…")
            }

            ShareLink(items: model.actionTargets) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(model.actionTargets.isEmpty)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            inspectorButton(.info, help: "Info (I)")
            inspectorButton(.adjust, help: "Adjust (E)")
            inspectorButton(.intelligence, help: "Apple Intelligence (A)")
        }
    }

    private func inspectorButton(_ tab: InspectorTab, help: String) -> some View {
        Button { model.toggleInspector(tab) } label: {
            Label(tab.title, systemImage: tab.systemImage)
        }
        .help(help)
        .tint(model.showInspector && model.inspectorTab == tab ? .accentColor : nil)
        .symbolVariant(model.showInspector && model.inspectorTab == tab ? .fill : .none)
    }
}
