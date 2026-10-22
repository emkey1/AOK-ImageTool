import ImagePlayground
import SwiftUI
import Translation

struct IntelligencePanel: View {
    @Environment(ViewerModel.self) private var model
    private var supportsImagePlayground: Bool { PlaygroundSupport.isAvailable }
    @State private var question = ""
    @State private var showTranslation = false
    @FocusState private var questionFocused: Bool

    private var ai: IntelligenceModel { model.intelligence }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                availabilityBanner
                if model.currentItem != nil {
                    describeSection
                    askSection
                    textSection
                    subjectSection
                    fixSection
                    if supportsImagePlayground { createSection }
                    qualitySection
                }
                folderSection
            }
            .padding(14)
        }
        .onAppear { ai.refreshSupport() }
    }

    // MARK: Availability

    @ViewBuilder
    private var availabilityBanner: some View {
        switch ai.support {
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label("Apple Intelligence Unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("\(reason) Vision-based tools below still work.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Apple Intelligence Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.12)))
        case .textOnly:
            Label("This model can't see images directly, so descriptions use on-device Vision labels and text.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .vision:
            EmptyView()
        }
    }

    // MARK: Describe

    private var describeSection: some View {
        PanelSection(title: "Describe", systemImage: "apple.intelligence") {
            if let url = model.currentURL, let d = ai.descriptions[url] {
                VStack(alignment: .leading, spacing: 8) {
                    Text(d.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(d.caption).textSelection(.enabled)
                    FlowLayout(spacing: 6) {
                        ForEach(d.keywords, id: \.self) { keyword in
                            Button(keyword) { model.searchText = keyword }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                                .help("Search the folder for “\(keyword)”")
                        }
                    }
                    HStack {
                        Button("Copy Alt Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(d.caption, forType: .string)
                        }
                        Button("Add Finder Tags") { ai.applyKeywordsAsTags() }
                    }
                    .controlSize(.small)
                    if !d.fileName.isEmpty, let item = model.currentItem,
                       item.url.deletingPathExtension().lastPathComponent != d.fileName {
                        Button {
                            ai.renameToSuggestion()
                        } label: {
                            Label("Rename to “\(d.fileName).\(item.url.pathExtension)”", systemImage: "character.cursor.ibeam")
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .controlSize(.small)
                    }
                    if !d.fromPixels {
                        Text("Based on detected labels and text.").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Button {
                    ai.describeCurrent()
                } label: {
                    Label(model.currentURL.flatMap { ai.descriptions[$0] } == nil ? "Describe Image" : "Describe Again",
                          systemImage: "text.below.photo")
                }
                .disabled(ai.isDescribing || !ai.support.isAvailable || model.decoded == nil)
                if ai.isDescribing { ProgressView().controlSize(.small) }
            }
            if let error = ai.describeError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Ask

    private var askSection: some View {
        PanelSection(title: "Ask About This Image", systemImage: "bubble.left.and.text.bubble.right") {
            if ai.chat.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(["What is this?", "Where could this be?", "What's written here?", "Describe the mood", "What breed or species?"], id: \.self) { s in
                        Button(s) { ai.ask(s) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .disabled(!ai.support.isAvailable || model.decoded == nil)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ai.chat) { message in
                        ChatBubble(message: message)
                    }
                    if ai.isAnswering, ai.chat.last?.text.isEmpty == true {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            HStack {
                TextField("Ask a question…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($questionFocused)
                    .onSubmit(send)
                    .disabled(!ai.support.isAvailable)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || ai.isAnswering)
                if !ai.chat.isEmpty {
                    Button { ai.resetChat() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                        .help("New conversation")
                }
            }
        }
    }

    private func send() {
        let q = question
        question = ""
        ai.ask(q)
    }

    // MARK: Text

    private var textSection: some View {
        PanelSection(title: "Text in Image", systemImage: "text.viewfinder") {
            if let url = model.currentURL, let text = ai.recognizedText[url] {
                if text.isEmpty {
                    Text("No text found.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
                    HStack {
                        Button("Copy Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        Button("Translate…") { showTranslation = true }
                    }
                    .controlSize(.small)
                    .translationPresentation(isPresented: $showTranslation, text: text)
                }
            } else {
                HStack {
                    Button {
                        ai.readTextCurrent()
                    } label: {
                        Label("Read Text", systemImage: "doc.text.viewfinder")
                    }
                    .disabled(ai.isReadingText || model.decoded == nil)
                    if ai.isReadingText { ProgressView().controlSize(.small) }
                }
                Text("Tip: you can also select text directly on the image with Live Text.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Subject

    private var subjectSection: some View {
        PanelSection(title: "Subject", systemImage: "person.crop.rectangle") {
            let hasCutout = model.currentEdits.cutout != nil
            ActionGrid {
                ActionButton(hasCutout ? "Restore Background" : "Remove Background", systemImage: hasCutout ? "photo" : "person.and.background.dotted") {
                    ai.toggleRemoveBackground()
                }
                ActionButton("Select Object…", systemImage: "hand.point.up.left.and.text") {
                    model.activeTool = .selectObject
                }
                ActionButton("Copy Subject", systemImage: "doc.on.clipboard") {
                    ai.copySubject()
                }
            }
            .disabled(!model.canEdit || ai.busy != nil)
            if model.hasFillableTransparency {
                BackgroundPicker()
                    .disabled(!model.canEdit || ai.busy != nil)
            }
        }
    }

    // MARK: Fixes

    private var fixSection: some View {
        PanelSection(title: "Smart Fixes", systemImage: "wand.and.sparkles") {
            ActionGrid {
                ActionButton("Auto Enhance", systemImage: "wand.and.stars") { model.toggleAutoEnhance() }
                ActionButton("Straighten", systemImage: "level") { ai.autoStraighten() }
                ActionButton("Smart Crop", systemImage: "crop") { ai.smartCrop() }
                ActionButton(model.currentEdits.perspective == nil ? "Fix Document" : "Undo Document Fix", systemImage: "doc.viewfinder") {
                    ai.fixPerspective()
                }
                if GenerativeModel.isInstalled {
                    ActionButton("Generative Extend", systemImage: "arrow.up.left.and.arrow.down.right") {
                        model.beginExtend(.generate)
                    }
                    .disabled(!model.canExtend)
                }
                if Colorizer.isInstalled {
                    ActionButton("Colorize", systemImage: "paintpalette") { model.colorizeCurrent() }
                }
            }
            .disabled(!model.canEdit || ai.busy != nil)
        }
    }

    // MARK: Create

    private var createSection: some View {
        PanelSection(title: "Create", systemImage: "apple.image.playground") {
            Button {
                model.showPlayground = true
            } label: {
                Label("Reimagine in Image Playground…", systemImage: "apple.image.playground")
            }
            Text("Turn this image into an animation, illustration or sketch. The result is saved next to the original.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Quality

    private var qualitySection: some View {
        PanelSection(title: "Shot Quality", systemImage: "star.leadinghalf.filled") {
            if let url = model.currentURL, let entry = ai.index[url], let score = entry.score {
                let percent = Double(score + 1) / 2
                Gauge(value: percent) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(percent * 100))")
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(Gradient(colors: [.red, .orange, .green]))
                Text(entry.isUtility == true
                     ? "Looks like a screenshot, receipt or document."
                     : percent > 0.66 ? "A strong shot." : percent > 0.4 ? "A decent shot." : "Probably not a keeper.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Analyze the folder to score every shot and rank the best ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Folder

    private var folderSection: some View {
        PanelSection(title: "This Folder", systemImage: "folder") {
            if ai.isIndexing {
                ProgressView(value: ai.indexProgress ?? 0) {
                    Text("Analyzing \(ai.indexTotal) images…").font(.caption)
                }
            } else {
                Text("\(ai.indexedCount) of \(model.allItems.count) images analyzed for search")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ActionGrid {
                ActionButton("Analyze Folder", systemImage: "sparkle.magnifyingglass") { ai.analyzeFolder() }
                ActionButton("Best Shots", systemImage: "medal") { model.sortKey = .quality }
                ActionButton("Find Similar", systemImage: "square.stack.3d.down.right") { ai.showSimilar() }
                ActionButton("Duplicates…", systemImage: "square.on.square") { ai.findDuplicates() }
            }
            .disabled(model.folderURL == nil || model.allItems.isEmpty)
            Text("Search finds images by what's in them (“dog”, “beach”, “receipt”) and by text they contain.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 30) }
            Text(message.text.isEmpty ? " " : message.text)
                .textSelection(.enabled)
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(background, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(message.role == .user ? Color.white : message.role == .error ? Color.red : Color.primary)
            if message.role != .user { Spacer(minLength: 30) }
        }
    }

    private var background: AnyShapeStyle {
        switch message.role {
        case .user: AnyShapeStyle(Color.accentColor)
        case .assistant: AnyShapeStyle(.quaternary)
        case .error: AnyShapeStyle(Color.red.opacity(0.12))
        }
    }
}

struct ActionGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            content
        }
    }
}

struct ActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .glassButtonStyle()
    }
}

/// Wrapping horizontal layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
