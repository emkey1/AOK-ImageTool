import ImagePlayground
import SwiftUI

/// What goes behind a cutout: transparency, a color, the original blurred, a picture, or one made
/// in Image Playground. Shown in the Intelligence panel while the image has a cutout.
struct BackgroundPicker: View {
    @Environment(ViewerModel.self) private var model
    private var supportsImagePlayground: Bool { PlaygroundSupport.isAvailable }
    @State private var dragStart: EditState?
    @State private var colorCommit: Task<Void, Never>?

    private static let swatches: [(name: String, red: Double, green: Double, blue: Double)] = [
        ("White", 1, 1, 1), ("Light Gray", 0.88, 0.89, 0.9), ("Black", 0, 0, 0), ("Teal", 0.07, 0.6, 0.6),
        ("Sky", 0.56, 0.78, 0.96), ("Sand", 0.96, 0.87, 0.68), ("Rose", 0.96, 0.72, 0.76),
    ]

    var body: some View {
        let background = model.currentEdits.background
        VStack(alignment: .leading, spacing: 8) {
            Text("Background").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                Button { model.setBackground(nil, actionName: "Transparent Background") } label: {
                    Circle().fill(.white)
                        .overlay(Path { p in
                            p.move(to: CGPoint(x: 4, y: 18)); p.addLine(to: CGPoint(x: 18, y: 4))
                        }.stroke(.red, lineWidth: 2))
                        .modifier(SwatchStyle(selected: background == nil))
                }
                .help("Transparent")
                ForEach(Self.swatches, id: \.name) { swatch in
                    let backdrop = Backdrop.color(red: swatch.red, green: swatch.green, blue: swatch.blue, alpha: 1)
                    Button { model.setBackground(backdrop, actionName: "Background Color") } label: {
                        Circle().fill(Color(.sRGB, red: swatch.red, green: swatch.green, blue: swatch.blue))
                            .modifier(SwatchStyle(selected: background == backdrop))
                    }
                    .help(swatch.name)
                }
                ColorPicker("Other Color", selection: colorBinding, supportsOpacity: true)
                    .labelsHidden()
                    .help("Other color")
            }
            .buttonStyle(.plain)
            HStack {
                Button { model.setBackground(.blur(amount: 0.5), actionName: "Blurred Background") } label: {
                    Label("Blur", systemImage: "drop.halffull")
                }
                .disabled(!model.canBlurOriginalBackground)
                .help(model.canBlurOriginalBackground
                      ? "Blur the original background behind the subject"
                      : "Only for cutouts made in ImageViewer — this file no longer has its original background")
                Button { model.chooseBackgroundPicture() } label: {
                    Label("Picture…", systemImage: "photo")
                }
                if GenerativeModel.isSupported, supportsImagePlayground {
                    Menu {
                        Button(GenerativeModel.isInstalled ? "On This Mac…" : "On This Mac (needs a download)…") { model.generateBackgroundOnThisMac() }
                        Button("With Image Playground…") { model.showBackgroundPlayground = true }
                    } label: {
                        Label("Generate…", systemImage: "sparkles")
                    }
                    .fixedSize()
                    .help("Describe a scene: made on this Mac around your subject, or by Image Playground")
                } else if GenerativeModel.isSupported {
                    Button { model.generateBackgroundOnThisMac() } label: {
                        Label("Generate…", systemImage: "sparkles")
                    }
                    .help(GenerativeModel.isInstalled ? "Describe a scene to paint around your subject, on this Mac"
                          : "Describe a scene to paint around your subject, on this Mac (needs the generative fill model, a one-time download)")
                } else if supportsImagePlayground {
                    Button { model.showBackgroundPlayground = true } label: {
                        Label("Generate…", systemImage: "apple.image.playground")
                    }
                    .help("Describe a background for Image Playground to create")
                }
            }
            .controlSize(.small)
            if case .blur(let amount) = background {
                blurSlider(amount)
            }
            if background?.isPicture == true {
                matchLightingSlider
                Text("Blends the subject's brightness, light color and edges with the picture.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                if case .color(let red, let green, let blue, let alpha) = model.currentEdits.background {
                    return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
                }
                return .white
            },
            set: { color in
                let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
                let backdrop = Backdrop.color(red: Double(c.redComponent), green: Double(c.greenComponent),
                                              blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
                if dragStart == nil { dragStart = model.currentEdits }
                model.previewEdits { $0.background = backdrop }
                // The color panel has no "done" moment, so one undo step covers changes until they pause.
                colorCommit?.cancel()
                colorCommit = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, let start = dragStart else { return }
                    model.commitEdits(from: start, actionName: "Background Color")
                    dragStart = nil
                }
            }
        )
    }

    private var matchLightingSlider: some View {
        let strength = model.currentEdits.matchLighting ?? 0
        return AdjustmentSlider(
            title: "Match Lighting",
            value: Binding(get: { strength }, set: { v in model.previewEdits { $0.matchLighting = v > 0.005 ? v : nil } }),
            range: 0...1,
            format: { "\(Int($0 * 100))%" },
            isDefault: strength < 0.005,
            onEditingChanged: { editing in
                if editing {
                    dragStart = model.currentEdits
                } else if let start = dragStart {
                    model.commitEdits(from: start, actionName: "Match Lighting")
                    dragStart = nil
                }
            },
            reset: { model.updateEdits("Reset Match Lighting") { $0.matchLighting = nil } }
        )
    }

    private func blurSlider(_ amount: Double) -> some View {
        AdjustmentSlider(
            title: "Blur",
            value: Binding(get: { amount }, set: { v in model.previewEdits { $0.background = .blur(amount: v) } }),
            range: 0.05...1,
            format: { "\(Int($0 * 100))%" },
            isDefault: false,
            onEditingChanged: { editing in
                if editing {
                    dragStart = model.currentEdits
                } else if let start = dragStart {
                    model.commitEdits(from: start, actionName: "Background Blur")
                    dragStart = nil
                }
            },
            reset: { model.setBackground(.blur(amount: 0.5), actionName: "Reset Background Blur") }
        )
    }
}

private struct SwatchStyle: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Circle())
    }
}
