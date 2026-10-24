import CoreGraphics
import CoreImage
import Foundation
import simd

/// White balance: Warmth and Tint (`EditState.temperature`, `.tint`) as the pipeline applies them, and how to
/// set them from a spot that should be neutral (the eyedropper), from the photo's own near-neutral areas (Auto),
/// or for the light it was taken in (presets).
nonisolated enum WhiteBalance {
    /// How far the eyedropper and Auto may go (the sliders show ±1, which covers most photos).
    static let limit = 1.5

    /// What the eyedropper makes of what's clicked: gray, or (on a face) natural skin.
    enum Target: Sendable {
        case gray, skin
    }

    /// The eyedropper's answer: the setting, what it was aiming for, and whether what was clicked was quite
    /// colorful for something meant to be gray.
    struct Pick: Sendable {
        let temperature: Double
        let tint: Double
        let target: Target
        let colorful: Bool
    }

    /// Natural skin, photographed in daylight, as log ratios of linear red and blue to green: typical skin (the
    /// ColorChecker's light and dark skin lie at -28.7°, 0.65 and 0.80 from gray; cheeks in photos at -12° to
    /// -25°, 0.6 to 0.8), and how far from it skin still looks natural: more along it (paler or more tanned) than
    /// across it (rosier or more golden).
    static let skin = SIMD2<Float>(0.70 * cos(-25 * .pi / 180), 0.70 * sin(-25 * .pi / 180))
    static let skinTolerance = (along: Float(0.22), across: Float(0.17))

    /// The light a photo can look lit by, each corrected toward daylight.
    enum Light: String, CaseIterable, Identifiable, Sendable {
        case shade, overcast, lamps, fluorescent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .shade: "Shade (too blue)"
            case .overcast: "Overcast (a little blue)"
            case .lamps: "Indoor Lamps (too orange)"
            case .fluorescent: "Fluorescent (too green)"
            }
        }

        /// Warmth and Tint that correct it.
        var setting: (temperature: Double, tint: Double) {
            switch self {
            case .shade: (0.55, 0.05)
            case .overcast: (0.3, 0)
            case .lamps: (-0.75, 0)
            case .fluorescent: (-0.3, 0.45)
            }
        }
    }

    /// `img` with Warmth and Tint: the light is taken to be the color temperature and tint they stand for, and
    /// corrected to daylight (6500 K).
    static func apply(_ img: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard temperature != 0 || tint != 0 else { return img }
        return img.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500 + temperature * (temperature > 0 ? 4000 : 2500), y: tint * 60),
            "inputTargetNeutral": CIVector(x: 6500, y: 0),
        ])
    }

    /// The Warmth and Tint that make what's at `point` (normalized in the edited picture, Core Image's y up)
    /// neutral, or, on a face, natural skin (skin isn't gray: made gray, a face goes ghostly and the photo
    /// cyan). nil when it's outside the photo (on an Extend fill) or too dark to tell.
    @concurrent
    static func neutral(_ decoded: DecodedImage, edits e: EditState, at point: CGPoint) async -> Pick? {
        let renderer = EditRenderer.shared
        // Where that is before the crop.
        let frame = CGRect(origin: .zero, size: renderer.makeImage(decoded, edits: e, maxDimension: nil, stage: .geometry).extent.size)
        let shown = e.crop.map { EditRenderer.pixelRect($0, in: frame).integral } ?? frame
        let p = CGPoint(x: (shown.minX + point.x * shown.width) / frame.width, y: (shown.minY + point.y * shown.height) / frame.height)
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
        let input = renderer.whiteBalanceInput(decoded, edits: e, maxDimension: 1024)
        let ext = input.extent
        // A small spot around it, averaged (noise and texture don't count).
        let r = max(2, 0.006 * max(ext.width, ext.height))
        let spot = CGRect(x: ext.minX + p.x * ext.width - r, y: ext.minY + p.y * ext.height - r, width: 2 * r, height: 2 * r).intersection(ext)
        guard !spot.isEmpty else { return nil }
        let average = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: spot)])
        // On a face? (Its box, a little bigger: a click on a cheek or forehead edge counts.)
        var target = Target.gray
        if let picture = renderer.context.createCGImage(input, from: ext) {
            let faces = await VisionServices.faceBoxes(picture)
            if faces.contains(where: { $0.insetBy(dx: -0.1 * $0.width, dy: -0.1 * $0.height).contains(p) }) { target = .skin }
        }
        guard let answer = solve(average, target: target) else { return nil }
        return Pick(temperature: answer.temperature, tint: answer.tint, target: target, colorful: answer.colorful)
    }

    /// Auto: the Warmth and Tint that turn the most of the photo neutral. Each setting on a grid is tried on the
    /// photo's pixels (the filter is a 3 × 3 matrix in linear light), scoring how much comes out nearly gray,
    /// brighter pixels counting more (whites are the surest), with a mild preference for changing less; then
    /// finer around the best. nil when too little of the photo is ever nearly gray to go by (a sunset, a
    /// forest), whose color white balance shouldn't take away.
    @concurrent
    static func auto(_ decoded: DecodedImage, edits e: EditState) async -> (temperature: Double, tint: Double)? {
        let renderer = EditRenderer.shared
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let input = renderer.whiteBalanceInput(decoded, edits: e, maxDimension: 112)
        let ext = input.extent.integral
        let w = Int(ext.width), h = Int(ext.height)
        guard w > 0, h > 0 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        renderer.context.render(input, toBitmap: &px, rowBytes: w * 16, bounds: ext, format: .RGBAf, colorSpace: linear)
        // Lit, unclipped pixels, and how much each counts.
        var reds: [Float] = [], greens: [Float] = [], blues: [Float] = [], weights: [Float] = []
        for i in 0..<(w * h) {
            let r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2]
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            guard lum > 0.02, lum < 0.9, max(r, g, b) < 0.98, min(r, g, b) > 0 else { continue }
            reds.append(r)
            greens.append(g)
            blues.append(b)
            weights.append(lum.squareRoot())
        }
        guard weights.count > 100 else { return nil }
        let total = weights.reduce(0, +)
        /// How much of the photo `m` makes nearly gray (a share of all the weight): a pixel counts fully when
        /// it's gray, less as it's further off, not at all past 25% saturation (linear).
        func neutrality(_ m: simd_float3x3) -> Float {
            let (c0, c1, c2) = (m.columns.0, m.columns.1, m.columns.2)
            var sum: Float = 0
            for i in 0..<weights.count {
                let r = reds[i], g = greens[i], b = blues[i]
                let x = c0.x * r + c1.x * g + c2.x * b
                let y = c0.y * r + c1.y * g + c2.y * b
                let z = c0.z * r + c1.z * g + c2.z * b
                let top = max(x, y, z)
                guard top > 0 else { continue }
                let off = (top - min(x, y, z)) / top / 0.25
                guard off < 1 else { continue }
                let near = 1 - off * off
                sum += weights[i] * near * near
            }
            return sum / total
        }
        func score(_ t: Double, _ k: Double) -> (score: Float, gray: Float) {
            let gray = neutrality(matrix(temperature: t, tint: k, space: linear))
            return (gray * Float(exp(-(t * t) / (2 * 0.55 * 0.55) - (k * k) / (2 * 0.35 * 0.35))), gray)
        }
        var best = (t: 0.0, k: 0.0, score: score(0, 0))
        // Coarse to fine: Warmth in steps of 0.25 (Tint 0.2), then finer around the best.
        for (step, kStep, span) in [(0.25, 0.2, 6), (0.06, 0.06, 4), (0.02, 0.02, 3)] {
            let center = best
            for i in -span...span {
                for j in -span...span {
                    let t = min(max(center.t + Double(i) * step, -limit), limit)
                    let k = min(max(center.k + Double(j) * kStep, -1), 1)
                    let s = score(t, k)
                    if s.score > best.score.score { best = (t, k, s) }
                }
            }
        }
        guard best.score.gray > 0.03 else { return nil }
        return ((best.t * 100).rounded() / 100, (best.k * 100).rounded() / 100)
    }

    /// Warmth and Tint as the 3 × 3 matrix they come to in linear light (in `space`): the filter is linear, so it's
    /// found by running it on pure red, green and blue.
    static func matrix(temperature: Double, tint: Double, space: CGColorSpace) -> simd_float3x3 {
        var basis = CIImage.empty()
        for (i, (r, g, b)) in [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)].enumerated() {
            guard let color = CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: space) else { continue }
            basis = CIImage(color: color).cropped(to: CGRect(x: i, y: 0, width: 1, height: 1)).composited(over: basis)
        }
        var px = [Float](repeating: 0, count: 12)
        EditRenderer.shared.context.render(apply(basis, temperature: temperature, tint: tint), toBitmap: &px, rowBytes: 48,
                                           bounds: CGRect(x: 0, y: 0, width: 3, height: 1), format: .RGBAf, colorSpace: space)
        return simd_float3x3(SIMD3(px[0], px[1], px[2]), SIMD3(px[4], px[5], px[6]), SIMD3(px[8], px[9], px[10]))
    }

    /// The Warmth and Tint that make `color` (a single pixel) neutral, or natural skin (the least change that
    /// puts it on `skin`, in `skinRange`), searched coarse to fine: the filter is run on it, so the answer fits the
    /// pipeline exactly. `colorful`: it was far from gray to begin with.
    static func solve(_ color: CIImage, target: Target = .gray) -> (temperature: Double, tint: Double, colorful: Bool)? {
        let context = EditRenderer.shared.context
        let bounds = CGRect(x: color.extent.minX, y: color.extent.minY, width: 1, height: 1)
        func rgb(_ img: CIImage) -> SIMD3<Float> {
            var px = [Float](repeating: 0, count: 4)
            context.render(img, toBitmap: &px, rowBytes: 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
            return SIMD3(px[0], px[1], px[2])
        }
        let start = rgb(color)
        guard start.min() > 0.002 else { return nil }
        /// As log ratios of red and blue to green.
        func chroma(_ c: SIMD3<Float>) -> SIMD2<Float> {
            let c = pointwiseMax(c, SIMD3(repeating: 1e-5))
            return SIMD2(log(c.x / c.y), log(c.z / c.y))
        }
        /// How far `v` is outside the range of natural skin (0 inside it; 1 = its edge), the range `scale` × as big.
        func outsideSkin(_ v: SIMD2<Float>, scale: Float = 1) -> Float {
            let u = simd_normalize(skin), d = v - skin
            let along = simd_dot(d, u) / (skinTolerance.along * scale), across = (d.x * -u.y + d.y * u.x) / (skinTolerance.across * scale)
            return max(0, (along * along + across * across).squareRoot() - 1)
        }
        // Skin that already looks natural is left as it is; skin that doesn't is brought inside the range: just
        // inside when it was just outside, well inside when it was far off (a cast, more likely than skin at the
        // very edge of natural).
        let startOutside = outsideSkin(chroma(start))
        if target == .skin, startOutside == 0 { return (0, 0, simd_length(chroma(start)) > 0.45) }
        let skinScale = 1 - 0.6 * min(1, startOutside / 0.6)
        // How far from the target (with the least nudge toward changing less, for skin, which a range of settings
        // reaches).
        func off(_ t: Double, _ k: Double) -> Float {
            let v = chroma(rgb(apply(color, temperature: t, tint: k)))
            switch target {
            case .gray:
                return simd_length_squared(v)
            case .skin:
                let out = outsideSkin(v, scale: skinScale)
                return out * out + 0.0005 * Float(t * t + k * k)
            }
        }
        var best = (t: 0.0, k: 0.0, off: off(0, 0))
        var step = 0.25
        for round in 0..<4 {
            let span = round == 0 ? Int(limit / step) : 3
            let center = best
            for i in -span...span {
                for j in -span...span {
                    let t = min(max(center.t + Double(i) * step, -limit), limit)
                    let k = min(max(center.k + Double(j) * step, -limit), limit)
                    let o = off(t, k)
                    if o < best.off { best = (t, k, o) }
                }
            }
            step /= 3
        }
        return ((best.t * 100).rounded() / 100, (best.k * 100).rounded() / 100, simd_length(chroma(start)) > 0.45)
    }
}
