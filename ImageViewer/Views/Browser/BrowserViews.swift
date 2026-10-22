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

    /// An image on its own, or a spread-out stack's images together.
    private struct Segment: Identifiable {
        var items: [ImageItem]
        /// The stack, when spread out.
        let stack: URL?
        var id: String { stack.map { "stack:" + $0.path } ?? items[0].url.path }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        for item in model.items {
            let stack = model.stackOf[item.url].flatMap { model.expandedStacks.contains($0) ? $0 : nil }
            if let stack, result.last?.stack == stack {
                result[result.count - 1].items.append(item)
            } else {
                result.append(Segment(items: [item], stack: stack))
            }
        }
        return result
    }

    var body: some View {
        let segments = segments
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(segments) { segment in
                        if segment.stack != nil {
                            HStack(spacing: 2) {
                                ForEach(segment.items) { cell($0) }
                            }
                            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary))
                            .id(segment.id)
                        } else {
                            cell(segment.items[0]).id(segment.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(height: 84)
            .background(.bar)
            .onChange(of: model.currentURL, initial: true) { _, url in
                guard let url else { return }
                guard let target = segments.first(where: { $0.items.contains { $0.url == url } })?.id else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private func cell(_ item: ImageItem) -> some View {
        FilmstripCell(item: item,
                      isCurrent: item.url == model.currentURL,
                      isEdited: model.edits[item.url] != nil,
                      stack: model.stackBadge(for: item.url))
            .onTapGesture { model.select(item.url) }
            .contextMenu { ItemContextMenu(item: item) }
            .onDrag { NSItemProvider(object: item.url as NSURL) }
    }
}

/// Marks a stack: its edges peeking out above a closed stack, and a count that opens or closes it.
struct StackDecoration: ViewModifier {
    @Environment(ViewerModel.self) private var model
    let url: URL
    let stack: ViewerModel.StackBadge?
    /// The tile's width.
    let width: CGFloat

    func body(content: Content) -> some View {
        let compact = width < 100
        return content
            .overlay(alignment: .top) {
                if let stack, !stack.expanded {
                    VStack(spacing: 2) {
                        Capsule().frame(width: width * 0.6, height: 2.5)
                        Capsule().frame(width: width * 0.78, height: 2.5)
                    }
                    .foregroundStyle(.secondary)
                    .offset(y: -7)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let stack, !stack.expanded || stack.position == 0 {
                    Button {
                        model.toggleStack(url)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: stack.expanded ? "chevron.backward" : "square.stack.fill")
                            Text("\(stack.count)").monospacedDigit()
                        }
                        .font(.system(size: compact ? 9 : 11, weight: .bold))
                        .padding(.horizontal, compact ? 4 : 6).padding(.vertical, compact ? 2 : 3)
                        .background(stack.expanded ? AnyShapeStyle(.tint) : AnyShapeStyle(.black.opacity(0.6)), in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(compact ? 3 : 6)
                    .help(stack.expanded
                          ? "Stack these \(stack.count) images again"
                          : "\(stack.count) images: this, and the copies made from it or its original. Click to see them all; ⌥← and ⌥→ step through them.")
                }
            }
    }
}

struct FilmstripCell: View {
    let item: ImageItem
    let isCurrent: Bool
    let isEdited: Bool
    var stack: ViewerModel.StackBadge?

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
            .modifier(StackDecoration(url: item.url, stack: stack, width: 64))
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
        let stack = model.stackBadge(for: item.url)
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
                .modifier(StackDecoration(url: item.url, stack: stack, width: size))
                .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.22)
                                                                   : stack?.expanded == true ? Color.secondary.opacity(0.14) : .clear))
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
        if let stack = model.stackBadge(for: item.url) {
            Button(stack.expanded ? "Close Stack" : "Show All \(stack.count) Images in Stack") { model.toggleStack(item.url) }
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
