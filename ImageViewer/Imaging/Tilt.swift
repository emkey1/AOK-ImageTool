import CoreGraphics
import Foundation
import simd

/// The picture tilted in depth and turned: Crop's Vertical, Horizontal and Straighten together, as Photos has
/// them. The picture is shown as its camera would have seen it turned by these angles (up or down, left or
/// right, and about its own lens), which is what squares up a building photographed from below or a painting
/// photographed from the side. The lens is taken to be a 28 mm one on 35 mm film, as Core Image's
/// CIPerspectiveRotate takes it and a phone's main camera nearly is. What's kept is the largest upright
/// rectangle of the picture's own shape, around its middle, that the tilted picture fills.
///
/// Which way the sliders go, and how far, is Photos' (compared in Photos 10 on macOS 15: at Vertical +12° and at
/// Horizontal +12° a sign's lettering was within a pixel or two of where this puts it). That's the opposite of
/// CIPerspectiveRotate's pitch and yaw.
///
/// Points are in pixels with the origin at the bottom left (Core Image's), in the picture (`size` big, already
/// turned and flipped) and in what's kept (`keptSize` big).
nonisolated struct Tilt: Sendable {
    /// Vertical and Horizontal go this far each way, in degrees.
    static let range: ClosedRange<Double> = -30...30
    /// The lens's focal length as a fraction of the picture's diagonal (35 mm film's is 43.27 mm).
    static let focalLength = 28 / 43.2666

    let size: CGSize
    let keptSize: CGSize
    private let forward: simd_double3x3
    private let backward: simd_double3x3

    /// - vertical: degrees; positive pushes the top of the picture back (it shrinks, the bottom grows).
    /// - horizontal: degrees; positive brings its right side forward (it grows, the left shrinks).
    /// - straighten: degrees, clockwise positive.
    init(size: CGSize, vertical: Double, horizontal: Double, straighten: Double) {
        let w = max(Double(size.width), 1), h = max(Double(size.height), 1)
        let f = Self.focalLength * (w * w + h * h).squareRoot()
        let a = min(max(vertical, Self.range.lowerBound), Self.range.upperBound) * .pi / 180
        let b = min(max(horizontal, Self.range.lowerBound), Self.range.upperBound) * .pi / 180
        // One turn about an axis lying in the picture (so Vertical and Horizontal don't come in an order, and a
        // picture turned a quarter turn tilts the same way), then the straightening about the lens.
        var turn = simd_quatd(angle: -straighten * .pi / 180, axis: SIMD3(0, 0, 1))
        let angle = (a * a + b * b).squareRoot()
        if angle > 0 { turn = turn * simd_quatd(angle: angle, axis: SIMD3(a / angle, b / angle, 0)) }
        // Pixels to rays from the lens (through the picture's middle), turned, and onto the plane again.
        let toRay = simd_double3x3(rows: [SIMD3(1, 0, -w / 2), SIMD3(0, 1, -h / 2), SIMD3(0, 0, f)])
        let plane = simd_double3x3(diagonal: SIMD3(f, f, 1)) * simd_double3x3(turn) * toRay

        func onPlane(_ x: Double, _ y: Double) -> SIMD2<Double> {
            let v = plane * SIMD3(x, y, 1)
            return SIMD2(v.x / v.z, v.y / v.z)
        }
        // The tilted picture's outline (counterclockwise) and its middle; the kept rectangle grows from the
        // middle until a corner of it meets the outline.
        let outline = [onPlane(0, 0), onPlane(w, 0), onPlane(w, h), onPlane(0, h)]
        let middle = onPlane(w / 2, h / 2)
        var scale = Double.infinity
        for corner in [SIMD2(w, h), SIMD2(-w, h), SIMD2(w, -h), SIMD2(-w, -h)] {
            for i in 0..<4 {
                let from = outline[i], edge = outline[(i + 1) % 4] - from
                let outward = SIMD2(edge.y, -edge.x)
                let toward = simd_dot(outward, corner / 2)
                if toward > 1e-9 { scale = min(scale, simd_dot(outward, from - middle) / toward) }
            }
        }
        if !scale.isFinite || scale <= 0 { scale = 1 }
        let kept = CGRect(x: middle.x - scale * w / 2, y: middle.y - scale * h / 2, width: scale * w, height: scale * h).integral
        let shift = simd_double3x3(rows: [SIMD3(1, 0, -Double(kept.minX)), SIMD3(0, 1, -Double(kept.minY)), SIMD3(0, 0, 1)])
        self.size = CGSize(width: w, height: h)
        keptSize = CGSize(width: max(kept.width, 1), height: max(kept.height, 1))
        forward = shift * plane
        backward = forward.inverse
    }

    /// Where a point of the picture is in what's kept (outside it, for what the tilt puts out of the frame).
    func kept(_ p: CGPoint) -> CGPoint {
        let v = forward * SIMD3(Double(p.x), Double(p.y), 1)
        return CGPoint(x: v.x / v.z, y: v.y / v.z)
    }

    /// Where a point of what's kept is in the picture.
    func picture(_ p: CGPoint) -> CGPoint {
        let v = backward * SIMD3(Double(p.x), Double(p.y), 1)
        return CGPoint(x: v.x / v.z, y: v.y / v.z)
    }

    /// Whether all of `region` (in what's kept, or around it) has a place in the picture's plane: what would be
    /// behind the lens the picture was taken with has none, and what's nearly level with it is too far off to use.
    func reaches(_ region: CGRect) -> Bool {
        let far = 50 * Double(max(size.width, size.height))
        return [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                CGPoint(x: region.maxX, y: region.maxY), CGPoint(x: region.minX, y: region.maxY)].allSatisfy {
            let v = backward * SIMD3(Double($0.x), Double($0.y), 1)
            return v.z > 0 && simd_length(SIMD2(v.x, v.y)) < far * v.z
        }
    }

    /// The picture's corners in what's kept.
    var corners: (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        (kept(CGPoint(x: 0, y: size.height)), kept(CGPoint(x: size.width, y: size.height)),
         kept(CGPoint(x: size.width, y: 0)), kept(.zero))
    }
}
