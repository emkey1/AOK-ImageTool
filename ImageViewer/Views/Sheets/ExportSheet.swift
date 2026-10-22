import SwiftUI

struct ExportSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ExportRequest

    @AppStorage(PrefKey.exportFormat) private var formatRaw = ExportFormat.jpeg.rawValue
    @AppStorage(PrefKey.exportQuality) private var quality = 0.88
    @AppStorage(PrefKey.exportMetadata) private var metadataRaw = MetadataPolicy.keepAll.rawValue
    @State private var limitSize = false
    @State private var maxDimension = 2048
    @State private var name = ""
    @State private var applyEdits = true
    @State private var destination: URL?
    @State private var progress: Double?
    @State private var errors: [String] = []

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw).flatMap { ExportFormat.writable.contains($0) ? $0 : nil } ?? .jpeg }
    private var isSingle: Bool { request.urls.count == 1 }
    private var anyEdits: Bool { request.urls.contains { model.edits[$0] != nil } }
    private var anyCutout: Bool { request.urls.contains { model.edits[$0]?.hasTransparency == true } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if isSingle {
                        LabeledContent("Name") {
                            HStack(spacing: 4) {
                                TextField("Name", text: $name).labelsHidden()
                                Text(".\(format.fileExtension)").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        LabeledContent("Images", value: "\(request.urls.count)")
                    }
                    LabeledContent("Save To") {
                        HStack {
                            Text(destinationFolder?.lastPathComponent ?? "—")
                                .lineLimit(1).truncationMode(.middle)
                                .help(destinationFolder?.path ?? "")
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                }

                Section {
                    Picker("Format", selection: $formatRaw) {
                        ForEach(ExportFormat.writable) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .onAppear { if formatRaw != format.rawValue { formatRaw = format.rawValue } }   // e.g. AVIF on macOS 15
                    if format.supportsQuality {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $quality, in: 0.3...1)
                                Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                            }
                        }
                    }
                    Toggle("Limit Size", isOn: $limitSize)
                    if limitSize {
                        LabeledContent("Longest Side") {
                            HStack {
                                TextField("Pixels", value: $maxDimension, format: .number)
                                    .frame(width: 80)
                                    .labelsHidden()
                                Text("px").foregroundStyle(.secondary)
                                Menu("Presets") {
                                    ForEach([1024, 1600, 2048, 3072, 4096], id: \.self) { v in
                                        Button("\(v) px") { maxDimension = v }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }
                    Picker("Metadata", selection: $metadataRaw) {
                        ForEach(MetadataPolicy.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if anyEdits {
                        Toggle("Apply Edits", isOn: $applyEdits)
                    }
                } footer: {
                    if anyCutout && !format.supportsAlpha {
                        Label("\(format.displayName) has no transparency — cut-out areas will be white. Choose PNG or HEIC to keep them transparent.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else if MetadataPolicy(rawValue: metadataRaw) == .removeLocation {
                        Text("GPS location is removed — good for sharing online.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !errors.isEmpty {
                    Section("Problems") {
                        ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let progress {
                    ProgressView(value: progress).frame(width: 180)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSingle ? "Export" : "Export \(request.urls.count) Images") { export() }
                    .keyboardShortcut(.defaultAction)
                    .prominentButtonStyle()
                    .disabled(progress != nil || destinationFolder == nil || (isSingle && name.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .padding(16)
        }
        .frame(width: 500)
        .onAppear {
            if let first = request.urls.first {
                name = first.deletingPathExtension().lastPathComponent + (model.edits[first] != nil ? " (Edited)" : "")
                if model.edits[first]?.hasTransparency == true, !format.supportsAlpha { formatRaw = ExportFormat.png.rawValue }
            }
        }
    }

    private var destinationFolder: URL? {
        destination ?? request.urls.first?.deletingLastPathComponent()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = destinationFolder
        if panel.runModal() == .OK { destination = panel.url }
    }

    private func export() {
        guard let folder = destinationFolder else { return }
        var options = ExportOptions()
        options.format = format
        options.quality = quality
        options.maxDimension = limitSize ? max(16, maxDimension) : nil
        options.metadata = MetadataPolicy(rawValue: metadataRaw) ?? .keepAll
        options.applyEdits = applyEdits
        progress = 0
        errors = []
        let urls = request.urls
        let single = isSingle ? name.trimmingCharacters(in: .whitespaces) : nil
        Task {
            let result = await model.export(urls, options: options, to: folder, singleName: single) { p in
                Task { @MainActor in progress = p }
            }
            progress = nil
            if result.errors.isEmpty {
                dismiss()
                let written = result.written
                model.showToast(written.count == 1 ? "Exported \(written[0].lastPathComponent)" : "Exported \(written.count) images",
                                systemImage: "square.and.arrow.up", actionTitle: "Show") {
                    NSWorkspace.shared.activateFileViewerSelecting(written)
                }
            } else {
                errors = result.errors
            }
        }
    }
}

struct RenameSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: ImageItem
    @State private var name = ""
    @State private var suggesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename “\(item.name)”")
                .font(.headline)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(rename)
                Text(".\(item.url.pathExtension)").foregroundStyle(.secondary)
            }
            if model.intelligence.support.isAvailable {
                HStack {
                    Button {
                        suggest()
                    } label: {
                        Label("Suggest a Name", systemImage: "apple.intelligence")
                    }
                    .disabled(suggesting)
                    if suggesting { ProgressView().controlSize(.small) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { name = item.url.deletingPathExtension().lastPathComponent }
    }

    private func rename() {
        if model.rename(item, to: name) { dismiss() }
    }

    private func suggest() {
        suggesting = true
        Task {
            if let suggestion = await model.intelligence.suggestName(for: item) { name = suggestion }
            suggesting = false
        }
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.bold))
                Spacer()
                Button("Open the Guide") {
                    dismiss()
                    GuideWindowController.shared.show(.keys)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(ViewerModel.shortcutGroups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(.headline)
                        ForEach(group.items) { s in
                            HStack(alignment: .firstTextBaseline) {
                                Text(s.keys)
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .frame(width: 150, alignment: .leading)
                                Text(s.action).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 720)
    }
}

struct DuplicatesSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var marked: Set<URL> = []
    @State private var recompute: Task<Void, Never>?

    private var ai: IntelligenceModel { model.intelligence }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicates & Similar Shots").font(.title2.weight(.bold))
                    Text("Grouped by Apple's on-device image similarity. The best-rated shot in each group comes first.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            HStack {
                Text("Exact")
                Slider(value: Binding(get: { Double(ai.duplicateThreshold) }, set: { v in
                    ai.duplicateThreshold = Float(v)
                    recompute?.cancel()
                    recompute = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        ai.computeDuplicates()
                    }
                }), in: 0.08...0.7)
                Text("Loose")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            Divider().padding(.top, 10)

            Group {
                if ai.isIndexing {
                    VStack(spacing: 10) {
                        ProgressView(value: ai.indexProgress ?? 0).frame(width: 260)
                        Text("Analyzing \(ai.indexTotal) images…").foregroundStyle(.secondary)
                    }
                } else if ai.isFindingDuplicates && ai.duplicateGroups.isEmpty {
                    ProgressView()
                } else if ai.duplicateGroups.isEmpty {
                    ContentUnavailableView("No Duplicates Found", systemImage: "checkmark.seal",
                                           description: Text("Try moving the slider toward Loose to find similar shots."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(ai.duplicateGroups) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(group.urls.count) similar images").font(.subheadline.weight(.semibold))
                                    ScrollView(.horizontal) {
                                        HStack(spacing: 10) {
                                            ForEach(Array(group.urls.enumerated()), id: \.element) { index, url in
                                                tile(url, isBest: index == 0)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Button("Keep Best of Each Group") {
                    marked = Set(ai.duplicateGroups.flatMap { $0.urls.dropFirst() })
                }
                .disabled(ai.duplicateGroups.isEmpty)
                Button("Clear Marks") { marked = [] }
                    .disabled(marked.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move \(marked.count) to Trash") {
                    model.moveToTrash(Array(marked))
                    marked = []
                    ai.computeDuplicates()
                }
                .prominentButtonStyle()
                .disabled(marked.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 820, height: 600)
    }

    private func tile(_ url: URL, isBest: Bool) -> some View {
        let item = model.allItems.first { $0.url == url }
        let isMarked = marked.contains(url)
        return VStack(spacing: 4) {
            Group {
                if let item {
                    ThumbnailView(item: item, tier: .small)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 140, height: 140)
            .overlay(alignment: .topLeading) {
                if isBest {
                    Label("Best", systemImage: "medal.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isMarked ? "trash.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isMarked ? Color.red : Color.black.opacity(0.35))
                    .padding(4)
            }
            .opacity(isMarked ? 0.6 : 1)
            .onTapGesture {
                if isMarked { marked.remove(url) } else { marked.insert(url) }
            }
            .onTapGesture(count: 2) {
                model.select(url)
                model.viewMode = .viewer
                dismiss()
            }
            Text(url.lastPathComponent)
                .font(.caption2)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 140)
            if let score = ai.index[url]?.score {
                Text("Score \(Int((score + 1) * 50))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
