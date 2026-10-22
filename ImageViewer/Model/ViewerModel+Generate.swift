import AppKit
import CoreImage

/// What a background is generated around: the photo (source orientation, like a cutout and its
/// background), its subject's mask (white = the subject) and the subject on its own, to describe.
struct BackgroundSource: @unchecked Sendable {
    let photo: CGImage
    let subject: CIImage
    let cutout: CGImage?
}

extension ViewerModel {
    func backgroundSource() async -> BackgroundSource? {
        guard let d = decoded, d.url == currentURL else { return nil }
        let e = currentEdits
        let photo = await VisionServices.downscaled(d.cgImage, maxDimension: 1536)
        var mask: CIImage?
        if let cutout = e.cutout {
            mask = MaskStore.shared.mask(for: cutout, url: d.url)
        } else if d.hasTransparentPixels {
            // The file's own transparency: its alpha as a mask.
            mask = CIImage(cgImage: photo).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        guard let mask else { return nil }
        var subjectOnly = EditState()
        subjectOnly.cutout = e.cutout
        let cutout = await EditRenderer.shared.render(d, edits: subjectOnly, maxDimension: 1024, stage: .source)?.image
        return BackgroundSource(photo: photo, subject: mask, cutout: cutout)
    }

    /// A background made on this Mac goes behind the cutout like any picture (undoable).
    func useGeneratedBackground(_ image: CGImage) {
        guard hasFillableTransparency else { return }
        do {
            setBackground(.image(path: try BackdropStore.save(image)), actionName: "Generated Background")
        } catch {
            showError("Couldn't use the generated background", error)
        }
    }
}
