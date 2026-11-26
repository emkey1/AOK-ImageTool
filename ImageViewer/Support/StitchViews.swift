#if DEBUG
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd

/// Views of one picture as a camera turning on the spot would see it (the picture standing in for a far-off
/// scene), for trying Stitch Pictures on: how two of them lie on each other is known exactly. They're made by
/// Core Image, not by the stitching code, so the two check each other.
nonisolated enum StitchViews {
    /// How a view's camera is turned, in degrees: to the right, up, and clockwise.
    struct Camera {
        var yaw = 0.0
        var pitch = 0.0
        var roll = 0.0
    }

    static let width = 960
    static let height = 720
    /// About a phone's main camera: 69° across.
    static let focal = 0.7275 * Double(width)
    /// What a camera would write for that lens.
    static var focal35: Double { focal / hypot(Double(width), Double(height)) * 43.27 }
    static var intrinsics: simd_double3x3 { Stitch.intrinsics(focal, SIMD2(Double(width) / 2, Double(height) / 2)) }

    /// Takes directions seen by the camera (x right, y down, z ahead) to the scene's.
    static func rotation(_ c: Camera) -> simd_double3x3 {
        let y = c.yaw * .pi / 180, p = c.pitch * .pi / 180, r = c.roll * .pi / 180
        let ry = simd_double3x3(rows: [SIMD3(cos(y), 0, sin(y)), SIMD3(0, 1, 0), SIMD3(-sin(y), 0, cos(y))])
        let rx = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(p), -sin(p)), SIMD3(0, sin(p), cos(p))])
        let rz = simd_double3x3(rows: [SIMD3(cos(r), -sin(r), 0), SIMD3(sin(r), cos(r), 0), SIMD3(0, 0, 1)])
        return ry * rx * rz
    }

    /// Takes a view's pixels to those of the picture it's a view of (which stands a little nearer than the
    /// view's own scale, so that turned views still fall inside it).
    static func toWorld(_ c: Camera, world: CGSize) -> simd_double3x3 {
        let worldFocal = focal * Double(world.width) / Double(width) / 2.6
        return Stitch.intrinsics(worldFocal, SIMD2(Double(world.width) / 2, Double(world.height) / 2)) * rotation(c) * intrinsics.inverse
    }

    /// The homography taking view a's pixels onto view b's.
    static func truth(_ a: Camera, onto b: Camera) -> simd_double3x3 {
        intrinsics * rotation(b).transpose * rotation(a) * intrinsics.inverse
    }

    /// What `camera` sees of `world`, `gain` times as bright; `size` pixels with its top left corner at `origin`
    /// in the camera's own picture (a wider canvas than the camera's, for comparing a stitched picture with).
    static func view(of world: CGImage, _ camera: Camera, gain: Double = 1, origin: CGPoint = .zero,
                     size: CGSize = CGSize(width: width, height: height)) -> CGImage? {
        let source = CIImage(cgImage: world)
        let h = toWorld(camera, world: CGSize(width: world.width, height: world.height))
        // The part of the world the view shows: a quadrilateral, straightened into the view's rectangle.
        func corner(_ x: Double, _ y: Double) -> CIVector? {
            let p = h * SIMD3(origin.x + x, origin.y + y, 1)
            guard p.z > 1e-9 else { return nil }
            return CIVector(x: p.x / p.z, y: Double(world.height) - p.y / p.z)
        }
        guard let topLeft = corner(0, 0), let topRight = corner(size.width, 0), let bottomRight = corner(size.width, size.height),
              let bottomLeft = corner(0, size.height) else { return nil }
        var seen = source.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": topLeft, "inputTopRight": topRight, "inputBottomRight": bottomRight, "inputBottomLeft": bottomLeft,
        ])
        let ext = seen.extent
        guard ext.width > 1, ext.height > 1, !ext.isInfinite else { return nil }
        seen = seen.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / ext.width, y: size.height / ext.height))
        if gain != 1 {
            seen = seen.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            ])
        }
        return ImageDecoder.ciContext.createCGImage(seen, from: CGRect(origin: .zero, size: size), format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Writes a view as a JPEG that says what lens took it (unless `lens` is false).
    static func write(_ image: CGImage, to url: URL, lens: Bool = true) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if lens { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifFocalLenIn35mmFilm: Int(focal35.rounded())] }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Three overlapping views of `world`, hand-held (tilted and rolled a little, their exposures uneven),
    /// written into `folder`.
    static func writeSet(of world: CGImage, into folder: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cameras = [(Camera(yaw: -20, pitch: 6, roll: -1), 1.1), (Camera(yaw: 0, pitch: 5, roll: 0.5), 1.0), (Camera(yaw: 19, pitch: 7, roll: 1.5), 0.9)]
        var urls: [URL] = []
        for (i, (camera, gain)) in cameras.enumerated() {
            guard let image = view(of: world, camera, gain: gain) else { continue }
            let url = folder.appendingPathComponent("View \(i + 1).jpg")
            write(image, to: url)
            urls.append(url)
        }
        return urls
    }
}
#endif
