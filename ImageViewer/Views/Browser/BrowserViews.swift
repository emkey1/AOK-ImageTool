import SwiftUI

/// Async thumbnail backed by `ThumbnailCache`.
struct ThumbnailView: View {
    let item: ImageItem
    let tier: ThumbnailCache.Tier
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: "\(item.url.path)|\(item.modificationDate?.timeIntervalSince1970 ?? 0)|\(tier.rawValue)") {
            if let hit = ThumbnailCache.shared.cached(item.url, tier: tier) {
                image = hit
                return
            }
            if image == nil { image = ThumbnailCache.shared.bestCached(item.url) }
            if let loaded = await ThumbnailCache.shared.thumbnail(for: item.url, tier: tier) {
                image = loaded
            }
        }
    }
}

struct FlagBadge: View {
    let flag: Flag

    var body: some View {
        switch flag {
        case .pick:
            Image(systemName: "flag.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
        case .reject:
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
        case .none:
            EmptyView()
        }
    }
}

struct FilmstripView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(model.items) { item in
                        FilmstripCell(item: item,
                                      isCurrent: item.url == model.currentURL,
                                      isEdited: model.edits[item.url] != nil)
                            .id(item.url)
                            .onTapGesture { model.select(item.url) }
                            .contextMenu { ItemContextMenu(item: item) }
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(height: 84)
            .background(.bar)
            .onChange(of: model.currentURL, initial: true) { _, url in
                guard let url else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(url, anchor: .center) }
            }
        }
    }
}

struct FilmstripCell: View {
    let item: ImageItem
    let isCurrent: Bool
    let isEdited: Bool

    var body: some View {
        ThumbnailView(item: item, tier: .small)
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .topLeading) {
                FlagBadge(flag: item.flag).font(.system(size: 13)).padding(2)
            }
            .overlay(alignment: .bottomTrailing) {
                if isEdited {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .background(.tint, in: Circle())
                        .foregroundStyle(.white)
                        .padding(2)
                }
            }
            .padding(2)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2.5)
            }
            .opacity(item.flag == .reject ? 0.55 : 1)
            .help(item.name)
            .contentShape(Rectangle())
    }
}

struct GridPane: View {
    @Environment(ViewerModel.self) private var model
    @AppStorage(PrefKey.showGridLabels) private var showLabels = true

    var body: some View {
        GeometryReader { geo in
            let size = model.gridThumbnailSize
            let spacing: CGFloat = 14
            let columns = max(1, Int((geo.size.width - 28 + spacing) / (size + 8 + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(size + 8), spacing: spacing), count: columns), spacing: spacing) {
                        ForEach(model.items) { item in
                            GridCell(item: item, size: size, showLabel: showLabels)
                                .id(item.url)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: model.currentURL) { _, url in
                    guard let url else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(url) }
                }
                .onAppear {
                    if let url = model.currentURL { proxy.scrollTo(url, anchor: .center) }
                }
            }
            .onChange(of: columns, initial: true) { _, value in
                model.gridColumns = value
            }
        }
        .overlay {
            if model.items.isEmpty && !model.isScanning {
                ContentUnavailableView(model.trimmedSearch.isEmpty ? "No Images" : "No Results",
                                       systemImage: model.trimmedSearch.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
            }
        }
    }
}

struct GridCell: View {
    @Environment(ViewerModel.self) private var model
    let item: ImageItem
    let size: CGFloat
    let showLabel: Bool

    var body: some View {
        let selected = model.selection.contains(item.url)
        let current = model.currentURL == item.url
        let score = model.intelligence.index[item.url]?.score
        VStack(spacing: 5) {
            ThumbnailView(item: item, tier: size > 150 ? .large : .small)
                .frame(width: size, height: size)
                .overlay(alignment: .topLeading) {
                    FlagBadge(flag: item.flag).font(.title3).padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if model.sortKey == .quality, let score {
                        Text(String(format: "%.0f", (score + 1) * 50))
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(4)
                            .help("Apple Intelligence quality score")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if model.edits[item.url] != nil {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2.weight(.bold))
                            .padding(4)
                            .background(.tint, in: Circle())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(current ? Color.accentColor : .clear, lineWidth: 2))
                .opacity(item.flag == .reject ? 0.55 : 1)
            if showLabel {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.gridClick(item.url, modifiers: NSEvent.modifierFlags) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.select(item.url)
            model.viewMode = .viewer
        })
        .contextMenu { ItemContextMenu(item: item) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .help(item.name)
    }
}

struct ItemContextMenu: View {
    @Environment(ViewerModel.self) private var model
    let item: ImageItem

    private var targets: [URL] { model.contextTargets(for: item.url) }

    var body: some View {
        Button("Open") {
            model.select(item.url)
            model.viewMode = .viewer
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(targets.map { $0 as NSURL })
        }
        Divider()
        Button("Pick") { model.setFlag(.pick, for: targets) }
        Button("Reject") { model.setFlag(.reject, for: targets) }
        Button("Unflag") { model.setFlag(.none, for: targets) }
        Divider()
        Button("Export…") { model.exportRequest = ExportRequest(urls: targets) }
        Button("Find Similar Images") {
            model.select(item.url)
            model.intelligence.showSimilar()
        }
        Divider()
        Button("Move to Trash", role: .destructive) { model.moveToTrash(targets) }
    }
}
