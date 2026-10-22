import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// Click-to-select objects (Vision interactive segmentation), then cut out, copy or save them.
struct ObjectSelectEditor: View {
    @Environment(ViewerModel.self) private var model
    @State private var proxy: CGImage?
    @State private var included: [CGPoint] = []   // normalized, lower-left origin
    @State private var excluded: [CGPoint] = []
    @State private var mask: CIImage?
    @State private var shade: CGImage?
    @State private var isWorking = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color(white: 0.07)
                    if let proxy {
                        let size = CGSize(width: proxy.width, height: proxy.height)
                        let fitted = fitRect(size, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 30, dy: 30))
                        Image(decorative: proxy, scale: 1)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX, y: fitted.midY)
                        if let shade {
                            Image(decorative: shade, scale: 1)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                                .position(x: fitted.midX, y: fitted.midY)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                        ForEach(Array(included.enumerated()), id: \.offset) { _, p in
                            marker(p, in: fitted, color: .green, symbol: "plus")
                        }
                        ForEach(Array(excluded.enumerated()), id: \.offset) { _, p in
                            marker(p, in: fitted, color: .red, symbol: "minus")
                        }
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX, y: fitted.midY)
                            .onTapGesture(coordinateSpace: .local) { location in
                                // `location` is in the container's space (the gesture sits outside `.position`).
                                let p = CGPoint(x: (location.x - fitted.minX) / fitted.width,
                                                y: 1 - (location.y - fitted.minY) / fitted.height)
                                guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                                if NSEvent.modifierFlags.contains(.option) {
                                    excluded.append(p)
                                } else {
                                    included.append(p)
                                }
                                segment()
                            }
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
            }
            controls
        }
        .task {
            guard let d = model.decoded else { return }
            proxy = await VisionServices.downscaled(d.cgImage, maxDimension: 1600)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCommit)) { note in
            if note.object as AnyObject? === model, mask != nil { cutOut() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolCancel)) { note in
            if note.object as AnyObject? === model { model.activeTool = nil }
        }
    }

    private func marker(_ p: CGPoint, in fitted: CGRect, color: Color, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(radius: 2)
            .position(x: fitted.minX + p.x * fitted.width, y: fitted.minY + (1 - p.y) * fitted.height)
            .allowsHitTesting(false)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Text(message ?? (included.isEmpty
                             ? "Click an object to select it. ⌥-click to exclude an area."
                             : "Click to add to the selection, ⌥-click to remove."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Clear") {
                included = []
                excluded = []
                mask = nil
                shade = nil
                message = nil
            }
            .disabled(included.isEmpty)
            Button("Copy") { copy() }
                .disabled(mask == nil)
            Button("Save as PNG…") { save() }
                .disabled(mask == nil)
            Button("Cancel") { model.activeTool = nil }
                .keyboardShortcut(.cancelAction)
            Button("Cut Out") { cutOut() }
                .prominentButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(mask == nil)
                .help("Keep only the selection (non-destructive)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func segment() {
        guard let proxy, !included.isEmpty else { return }
        task?.cancel()
        isWorking = true
        message = nil
        let inc = included, exc = excluded
        task = Task {
            do {
                let result: CIImage
                if #available(macOS 27, *), let refined = try? await VisionServices.objectMask(for: proxy, included: inc, excluded: exc) {
                    result = refined
                } else {
                    // Before macOS 27 (or if refinement fails): the foreground instance under the latest click.
                    result = try await VisionServices.instanceMask(for: proxy, at: inc.last!)
                }
                guard !Task.isCancelled else { return }
                mask = result
                let shaded = await Task.detached { Self.shade(for: result, size: CGSize(width: proxy.width, height: proxy.height)) }.value
                withAnimation(.easeOut(duration: 0.15)) { shade = shaded }
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// Darkens everything outside the selection.
    nonisolated private static func shade(for mask: CIImage, size: CGSize) -> CGImage? {
        let ext = CGRect(origin: .zero, size: size)
        let m = mask
            .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / mask.extent.width, y: size.height / mask.extent.height))
        let dark = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.6)).cropped(to: ext)
        let glow = CIImage(color: CIColor(red: 0.35, green: 0.6, blue: 1, alpha: 0.18)).cropped(to: ext)
        let out = glow.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: dark,
            kCIInputMaskImageKey: m,
        ])
        return ImageDecoder.ciContext.createCGImage(out, from: ext)
    }

    private func cutOut() {
        guard let mask else { return }
        let id = MaskStore.shared.addObjectMask(mask)
        model.updateEdits("Cut Out Object") { $0.cutout = .object(id) }
        model.activeTool = nil
    }

    private func copy() {
        guard let mask, let d = model.decoded else { return }
        Task {
            do {
                try await model.intelligence.copyCutout(of: d, mask: mask)
                model.showToast("Copied object", systemImage: "doc.on.clipboard")
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let mask, let d = model.decoded else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = d.url.deletingPathExtension().lastPathComponent + " (Object).png"
        panel.directoryURL = d.url.deletingLastPathComponent()
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let data = try await model.intelligence.cutoutPNG(of: d, mask: mask)
                    try data.write(to: url)
                    if url.deletingLastPathComponent().standardizedFileURL == model.folderURL, let item = FolderScanner.item(for: url) {
                        model.insertItem(item, select: false)
                    }
                    model.showToast("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle")
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        if let window = model.window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }
}
