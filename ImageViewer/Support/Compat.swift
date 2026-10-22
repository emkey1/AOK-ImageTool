import SwiftUI

// Liquid Glass arrived in macOS 26; on macOS 15 the same controls use materials and bordered buttons.
extension View {
    /// A glass background on macOS 26+, a translucent material before.
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// The prominent (accent-colored) button style.
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// The standard secondary button style for larger buttons.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
