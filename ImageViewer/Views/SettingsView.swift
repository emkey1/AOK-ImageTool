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
    @AppStorage(PrefKey.checkForUpdates) private var checkForUpdates = true

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
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                HStack {
                    Button("Check Now") { Updater.shared.checkNow() }
                    Button("Release Notes") { Updater.showReleaseNotes() }
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
    @AppStorage(CopyOperation.upscale.key) private var copyUpscale = true
    @AppStorage(CopyOperation.colorize.key) private var copyColorize = true
    @AppStorage(CopyOperation.blackAndWhite.key) private var copyBlackAndWhite = true
    @AppStorage(CopyOperation.fixBlur.key) private var copyFixBlur = true
    @AppStorage(CopyOperation.extend.key) private var copyExtend = true
    @AppStorage(CopyOperation.removeObjects.key) private var copyRemoveObjects = true
    @AppStorage(CopyOperation.changeObjects.key) private var copyChangeObjects = true

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
            Section {
                Toggle("Upscale with AI makes a copy", isOn: $copyUpscale)
                Toggle("Colorize makes a copy", isOn: $copyColorize)
                Toggle("Black & White makes a copy", isOn: $copyBlackAndWhite)
                Toggle("Fix Blur makes a copy", isOn: $copyFixBlur)
                Toggle("Extend makes a copy", isOn: $copyExtend)
                Toggle("Remove Objects makes a copy", isOn: $copyRemoveObjects)
                Toggle("Change Objects makes a copy", isOn: $copyChangeObjects)
            } header: {
                Text("Copies")
            } footer: {
                Text("A copy is saved next to the original and stacked on it; the original stays as it was. Turned off, Upscale, Colorize, Black & White and Fix Blur replace the image when they're done (the original goes to the Trash as when saving), and Extend, Remove Objects and Change Objects become edits you save. Photos from your Photos library and animations always get copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ModelSettings(model: .generativeFill, title: "Generative Fill",
                          footer: "Extend's Generate, Generate a Background, and Remove and Change Objects' Generate draw new content with \(GenerativeModel.displayName), entirely on this Mac.",
                          folder: GenerativeModel.directory, sizeOnDisk: { GenerativeModel.sizeOnDisk },
                          remove: { try GenerativeModel.remove() }, installFromFolder: { try GenerativeModel.install(from: $0) },
                          folderPrompt: "Choose the folder scripts/convert-inpainting-model.sh made (it holds Unet.mlmodelc and the other model files).")
            ModelSettings(model: .colorize, title: "Colorize",
                          footer: "Image ▸ Colorize turns black and white photos to color with DDColor, on this Mac; only the color comes from the model, the photo's detail is kept.",
                          folder: Colorizer.directory, sizeOnDisk: { Colorizer.sizeOnDisk },
                          remove: { try Colorizer.remove() }, installFromFolder: { try Colorizer.install(from: $0) },
                          folderPrompt: "Choose DDColor.mlmodelc, or the folder that holds it.")
            ModelSettings(model: .fixBlur, title: "Fix Blur",
                          footer: "Image ▸ Fix Blur takes camera shake or soft focus out of a photo with \(BlurFixer.blurModelName) (two models, one download), on this Mac.",
                          folder: BlurFixer.focusModel.directory, sizeOnDisk: { BlurFixer.shakeModel.sizeOnDisk + BlurFixer.focusModel.sizeOnDisk },
                          remove: { try BlurFixer.removeBlurModels() }, installFromFolder: { try BlurFixer.installBlurModels(from: $0) },
                          folderPrompt: "Choose the folder that holds Shake.mlmodelc and Focus.mlmodelc (scripts/convert-sharpen-models.sh makes them).")
            ModelSettings(model: .restoreFaces, title: "Fix Blur: Faces",
                          footer: "Fix Blur's Restore Faces redraws blurry faces with \(BlurFixer.facesModelName), on this Mac.",
                          folder: BlurFixer.faceModel.directory, sizeOnDisk: { BlurFixer.faceModel.sizeOnDisk },
                          remove: { try BlurFixer.faceModel.remove() }, installFromFolder: { try BlurFixer.faceModel.install(from: $0) },
                          folderPrompt: "Choose Faces.mlmodelc (made by scripts/convert-sharpen-models.sh), or the folder that holds it.")
            ModelSettings(model: .removal, title: "Remove Objects",
                          footer: "Remove Objects' Erase paints in what was behind what you remove with \(RemovalModel.displayName), a model made for it, on this Mac. Without it, Match Photo and Generate still work.",
                          folder: RemovalModel.directory, sizeOnDisk: { RemovalModel.sizeOnDisk },
                          remove: { try RemovalModel.remove() }, installFromFolder: { try RemovalModel.install(from: $0) },
                          folderPrompt: "Choose LaMa.mlmodelc (made by scripts/convert-removal-model.sh), or the folder that holds it.")
        }
        .formStyle(.grouped)
    }
}

/// A downloadable model's status, download and removal (Settings ▸ Editing).
private struct ModelSettings: View {
    let model: DownloadableModel
    let title: String
    let footer: String
    let folder: URL
    let sizeOnDisk: () -> Int64
    let remove: @Sendable () throws -> Void
    let installFromFolder: @Sendable (URL) throws -> Void
    let folderPrompt: String

    @State private var installed = false
    @State private var size: Int64 = 0
    @State private var busy = false
    @State private var error: String?
    @State private var confirmRemove = false
    private var downloads: ModelDownloads { .shared }

    var body: some View {
        let status = downloads.status[model.id]
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
                if let status {
                    HStack {
                        switch status {
                        case .downloading(let fraction):
                            ProgressView(value: fraction)
                            Text("\(Int(fraction * 100))% of \(model.formattedSize)").monospacedDigit().foregroundStyle(.secondary)
                        case .installing:
                            ProgressView().controlSize(.small)
                            Text("Installing…").foregroundStyle(.secondary)
                        }
                        Button("Cancel") { downloads.cancel(model) }
                            .disabled(status == .installing)
                    }
                } else {
                    HStack {
                        if !installed {
                            Button(model.licenseRestrictsUse ? "Accept License and Download (\(model.formattedSize))" : "Download (\(model.formattedSize))") {
                                downloads.start(model)
                            }
                        }
                        Menu("More") {
                            Button(installed ? "Replace from Folder…" : "Install from Folder…") { choose() }
                            if installed {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            }
                            Button("View License") { NSWorkspace.shared.open(model.licenseURL) }
                        }
                        .fixedSize()
                        if installed {
                            Button("Remove…", role: .destructive) { confirmRemove = true }
                        }
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .disabled(busy)
                }
            }
            if let error = error ?? downloads.failure[model.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer + " Model license: \(model.licenseName)" + (model.licenseRestrictsUse ? ", which limits how it may be used." : "."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { refresh() }
        .onChange(of: downloads.installCount) { refresh() }
        .confirmationDialog("Remove the \(model.purpose) model?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                let remove = remove
                run { try remove() }
            }
        } message: {
            Text("You can download it again here.")
        }
    }

    private func refresh() {
        installed = model.isInstalled()
        size = installed ? sizeOnDisk() : 0
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Install"
        panel.message = folderPrompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let install = installFromFolder
        run { try install(url) }
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
