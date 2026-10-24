import CoreImage

extension CIContext {
    /// `image` within `bounds` as one byte per pixel (`.L8`), rows top-down, `bounds.width` bytes each. macOS 15
    /// renders nothing into one-byte rows whose length isn't a multiple of 4 bytes (later versions don't mind),
    /// so the rows are padded to that, then packed.
    nonisolated func renderGray(_ image: CIImage, bounds: CGRect, colorSpace: CGColorSpace? = nil) -> [UInt8] {
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0 else { return [] }
        let padded = (w + 3) / 4 * 4
        var rows = [UInt8](repeating: 0, count: padded * h)
        render(image, toBitmap: &rows, rowBytes: padded, bounds: bounds, format: .L8, colorSpace: colorSpace)
        guard padded != w else { return rows }
        var packed = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { packed.replaceSubrange((y * w)..<(y * w + w), with: rows[(y * padded)..<(y * padded + w)]) }
        return packed
    }
}
