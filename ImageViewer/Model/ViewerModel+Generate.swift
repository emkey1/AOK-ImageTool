import AppKit
import CoreImage

/// What a background is generated around: the photo as it's shown (turned, straightened, cropped, without
/// adjustments or what's behind the subject), its subject's mask over that (white = the subject), the subject on
/// its own, to describe and show, and the frame the result is put behind (see `BackdropFrame`).
struct BackgroundSource: @unchecked Sendable {
    let photo: CGImage
    let subject: CIImage
    let cutout: CGImage?
    let frame: BackdropFrame?
}

extension ViewerModel {
    func backgroundSource() async -> BackgroundSource? {
        guard let d = decoded, d.url == currentURL else { return nil }
        let e = currentEdits
        // A cutout, or the file's own transparency.
        if let cutout = e.cutout {
            guard MaskStore.shared.mask(for: cutout, url: d.url) != nil else { return nil }
        } else if !d.hasTransparentPixels {
            return nil
        }
        let frame = e.backdropFrame
        var shape = frame?.edits ?? EditState()
        shape.removals = e.removals
        var subjectOnly = shape
        subjectOnly.cutout = e.cutout
        // At most 1536 pixels on the long side of what's shown, however tightly it's cropped.
        let shown = EditRenderer.shared.shownGeometry(shape, size: d.pixelSize).shown
        let longest = max(d.pixelSize.width, d.pixelSize.height)
        let maxDimension = longest * min(1, 1536 / max(shown.width, shown.height, 1))
        guard let photo = await EditRenderer.shared.render(d, edits: shape, maxDimension: maxDimension)?.image,
              let cutout = await EditRenderer.shared.render(d, edits: subjectOnly, maxDimension: maxDimension)?.image
        else { return nil }
        // The subject is what's left opaque: the cutout's alpha (or the file's), exactly the photo's size.
        let rendered = CIImage(cgImage: cutout)
        let extent = CGRect(x: 0, y: 0, width: photo.width, height: photo.height)
        let mask = EditRenderer.alphaMask(of: rendered)
            .transformed(by: CGAffineTransform(scaleX: extent.width / max(rendered.extent.width, 1), y: extent.height / max(rendered.extent.height, 1)))
            .cropped(to: extent)
        return BackgroundSource(photo: photo, subject: mask, cutout: cutout, frame: frame)
    }

    /// A background made on this Mac goes behind the cutout like any picture (undoable), filling the frame it
    /// was painted for.
    func useGeneratedBackground(_ image: CGImage, frame: BackdropFrame?) {
        guard hasFillableTransparency else { return }
        do {
            setBackground(.image(path: try BackdropStore.save(image), frame: frame), actionName: "Generated Background")
        } catch {
            showError("Couldn't use the generated background", error)
        }
    }
}
