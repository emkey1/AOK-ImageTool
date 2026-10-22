import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Viewing", systemImage: "eye") { ViewingSettings() }
            Tab("Editing", systemImage: "slider.horizontal.3") { EditingSettings() }
            Tab("Intelligence", systemImage: "apple.intelligence") { IntelligenceSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage(PrefKey.upDownNavigates) private var upDownNavigates = true
    @AppStorage(PrefKey.spaceAdvances) private var spaceAdvances = true
    @AppStorage(PrefKey.wrapAround) private var wrapAround = true
    @AppStorage(PrefKey.includeSubfolders) private var includeSubfolders = false
    @AppStorage(PrefKey.showHiddenFiles) private var showHidden = false
    @AppStorage(PrefKey.advanceAfterFlag) private var advanceAfterFlag = true
    @AppStorage(PrefKey.slideshowInterval) private var slideshowInterval = 4.0

    var body: some View {
        Form {
            Section("Navigation") {
                Picker("Up and Down Arrows", selection: $upDownNavigates) {
                    Text("Previous / Next Image").tag(true)
                    Text("Zoom In / Out").tag(false)
                }
                Toggle("Space bar shows the next image", isOn: $spaceAdvances)
                Toggle("Wrap around at the end of the folder", isOn: $wrapAround)
                Toggle("Advance to the next image after Pick / Reject", isOn: $advanceAfterFlag)
            }
            Section("Folders") {
                Toggle("Include images in subfolders", isOn: $includeSubfolders)
                Toggle("Show hidden files", isOn: $showHidden)
            }
            Section("Slideshow") {
                LabeledContent("Seconds per image") {
                    HStack {
                        Slider(value: $slideshowInterval, in: 1...15, step: 0.5)
                        Text(String(format: "%.1f s", slideshowInterval)).monospacedDigit().frame(width: 44)
                    }
                }
            }
            Section("Supported Formats") {
                Text(SupportedFormats.readableExtensionsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ViewingSettings: View {
    @AppStorage(PrefKey.canvasBackground) private var background = CanvasBackground.dark.rawValue
    @AppStorage(PrefKey.checkerboard) private var checkerboard = true
    @AppStorage(PrefKey.upscaleSmallImages) private var upscale = false
    @AppStorage(PrefKey.pixelatedZoom) private var pixelated = false
    @AppStorage(PrefKey.hdrEnabled) private var hdr = true
    @AppStorage(PrefKey.showGridLabels) private var gridLabels = true

    var body: some View {
        Form {
            Section("Canvas") {
                Picker("Background", selection: $background) {
                    ForEach(CanvasBackground.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Checkerboard behind transparent images", isOn: $checkerboard)
                Toggle("Enlarge small images to fit the window", isOn: $upscale)
                Toggle("Show crisp pixels when zoomed past 100%", isOn: $pixelated)
            }
            Section {
                Toggle("Show HDR photos in high dynamic range", isOn: $hdr)
                    .onChange(of: hdr) { ImagePipeline.shared.removeAll() }
            } footer: {
                Text("On displays that support it, HDR photos (like those from iPhone) show their full brightness range.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Grid") {
                Toggle("Show file names under thumbnails", isOn: $gridLabels)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditingSettings: View {
    @AppStorage(PrefKey.trashOriginalOnSave) private var trashOriginal = true
    @AppStorage(PrefKey.confirmOverwrite) private var confirmOverwrite = true

    var body: some View {
        Form {
            Section {
                Toggle("Move the original to the Trash when saving", isOn: $trashOriginal)
                Toggle("Ask before saving over the original", isOn: $confirmOverwrite)
            } header: {
                Text("Saving")
            } footer: {
                Text("Edits are non-destructive until you Save. With “Move the original to the Trash” on, you can always recover the unedited file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GenerativeFillSettings()
            ColorizeSettings()
        }
        .formStyle(.grouped)
    }
}

/// Status of the colorizing model (DDColor).
private struct ColorizeSettings: View {
    @State private var installed = Colorizer.isInstalled
    @State private var size: Int64 = 0
    @State private var confirmRemove = false
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Model") {
                if !GenerativeModel.isSupported {
                    Text("Needs a Mac with Apple silicon").foregroundStyle(.secondary)
                } else if installed {
                    Label("Installed (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Not installed").foregroundStyle(.secondary)
                }
            }
            if GenerativeModel.isSupported {
                HStack {
                    Button(installed ? "Replace…" : "Install from Folder…") { choose() }
                    if installed {
                        Button("Remove…", role: .destructive) { confirmRemove = true }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Colorize")
        } footer: {
            Text("Image ▸ Colorize turns black and white photos to color with DDColor, on this Mac; only the color comes from the model, the photo's detail is kept. The model (about 460 MB) is converted with scripts/convert-colorize-model.sh. Model license: Apache 2.0.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { refresh() }
        .confirmationDialog("Remove the colorizing model?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                do { try Colorizer.remove() } catch { self.error = error.localizedDescription }
                refresh()
            }
        }
    }

    private func refresh() {
        installed = Colorizer.isInstalled
        size = installed ? Colorizer.sizeOnDisk : 0
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Install"
        panel.message = "Choose DDColor.mlmodelc, or the folder that holds it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Colorizer.install(from: url) } catch { self.error = error.localizedDescription }
        refresh()
    }
}

/// Status and installation of Extend's generative fill model.
private struct GenerativeFillSettings: View {
    @State private var installed = GenerativeModel.isInstalled
    @State private var size: Int64 = 0
    @State private var busy = false
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        Section {
            LabeledContent("Model") {
                if !GenerativeModel.isSupported {
                    Text("Needs a Mac with Apple silicon").foregroundStyle(.secondary)
                } else if installed {
                    Label("Installed (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Not installed").foregroundStyle(.secondary)
                }
            }
            if GenerativeModel.isSupported {
                HStack {
                    Button(installed ? "Replace…" : "Install from Folder…") { choose() }
                    if installed {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([GenerativeModel.directory])
                        }
                        Button("Remove…", role: .destructive) { confirmRemove = true }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                .disabled(busy)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Generative Fill")
        } footer: {
            Text("Crop ▸ Extend ▸ Generate draws new content past a photo's edges with \(GenerativeModel.displayName), entirely on this Mac. The model (about 2 GB) is converted from the official weights with scripts/convert-inpainting-model.sh; choose the folder it made. Model license: CreativeML Open RAIL-M.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { refresh() }
        .confirmationDialog("Remove the generative fill model?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                run { try GenerativeModel.remove() }
            }
        } message: {
            Text("Generate won't be available until the model is installed again, which needs the converted model folder.")
        }
    }

    private func refresh() {
        installed = GenerativeModel.isInstalled
        size = installed ? GenerativeModel.sizeOnDisk : 0
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Install"
        panel.message = "Choose the folder the converter made (it holds Unet.mlmodelc and the other model files)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try GenerativeModel.install(from: url) }
    }

    private func run(_ work: @escaping @Sendable () throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try work() }.value
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
            refresh()
        }
    }
}

private struct IntelligenceSettings: View {
    @AppStorage(PrefKey.liveTextEnabled) private var liveText = true
    @AppStorage(PrefKey.autoDescribe) private var autoDescribe = false
    @State private var support = ImageDescriber.support

    var body: some View {
        Form {
            Section("Apple Intelligence") {
                LabeledContent("Status") {
                    switch support {
                    case .vision: Label("Available (understands images)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .textOnly: Label("Available (text only)", systemImage: "checkmark.circle").foregroundStyle(.orange)
                    case .unavailable(let reason): Text(reason).foregroundStyle(.secondary)
                    }
                }
                Toggle("Describe images automatically when the Intelligence panel is open", isOn: $autoDescribe)
                    .disabled(!support.isAvailable)
            }
            Section {
                Toggle("Live Text & Visual Look Up on images", isOn: $liveText)
            } footer: {
                Text("Select and copy text right on the image, look up landmarks, plants, pets and more. All analysis happens on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Search Index") {
                Button("Clear Cached Analysis") {
                    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ImageViewer")
                        .appendingPathComponent("Index")
                    try? FileManager.default.removeItem(at: base)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { support = ImageDescriber.support }
    }
}
