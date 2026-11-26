import CoreImage
import Foundation
import ImageIO
import simd

nonisolated enum StitchError: LocalizedError {
    case tooFew
    case noOverlap
    case cancelled
    case failed

    var errorDescription: String? {
        switch self {
        case .tooFew: "Choose two or more pictures to stitch."
        case .noOverlap: "These pictures don't show enough of the same things to be joined."
        case .cancelled: "Stitching was cancelled."
        case .failed: "The pictures couldn't be stitched."
        }
    }
}

/// Stitch Pictures: pictures taken from one spot, the camera turned between them, joined into one wider (or
/// taller) picture. How they lie on each other is found from what they show (`layout`, the C engine in
/// Stitch.c); they're then looked at from one view (`render`): flat, or wrapped on a cylinder or sphere when
/// they take in too much for that, level, and turned as the user likes. What no picture covers is cropped
/// away, or filled (`fill`, `filled`).
nonisolated enum Stitch {
    /// The pictures are lined up at this size (their long side) at most, and kept at it while the sheet is open.
    static let workingSide = 2400
    /// A stitched picture's long side and size at most; pictures that would make a bigger one are stitched smaller.
    static let maxSide = 16384
    static let maxPixels = 120_000_000
    /// What isn't covered is filled on a canvas this big (its long side) at most, like Extend's.
    static let fillSide = 2048

    // MARK: Pictures

    /// A picture to stitch: its pixels as it shows (its edits applied), perhaps smaller than it is.
    final class Picture: @unchecked Sendable {
        let width: Int
        let height: Int
        /// Its size as it shows, full size.
        let fullSize: CGSize
        /// Its lens's focal length in its full-size pixels, when the file says.
        let focal: Double?
        let space: CGColorSpace
        /// Which way is down, in its own pixels (x right, y down, z into the picture), when the file says.
        let down: SIMD3<Double>?
        /// Owns the pixels: RGBA, rows top to bottom.
        private let context: CGContext
        fileprivate let low: UnsafeMutablePointer<Float>
        fileprivate let lowWidth: Int
        fileprivate let lowHeight: Int

        fileprivate var pixels: UnsafePointer<UInt8> { UnsafePointer(context.data!.assumingMemoryBound(to: UInt8.self)) }
        /// How many of its pixels to one of the full-size picture's.
        var scale: Double { Double(width) / Double(max(fullSize.width, 1)) }
        var image: CGImage? { context.makeImage() }

        /// `image` drawn in `space`, no bigger than `maxSide`.
        init?(_ image: CGImage, fullSize: CGSize? = nil, focal: Double? = nil, down: SIMD3<Double>? = nil, space: CGColorSpace, maxSide: Int? = nil) {
            let longest = max(image.width, image.height)
            let scale = maxSide.map { min(1, Double($0) / Double(max(longest, 1))) } ?? 1
            let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), ctx.data != nil else { return nil }
            ctx.interpolationQuality = scale < 1 ? .high : .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            context = ctx
            width = w
            height = h
            self.fullSize = fullSize ?? CGSize(width: image.width, height: image.height)
            self.focal = focal
            self.down = down
            self.space = space
            let long = Double(max(w, h))
            lowWidth = max(8, Int((256 * Double(w) / long).rounded()))
            lowHeight = max(8, Int((256 * Double(h) / long).rounded()))
            low = .allocate(capacity: lowWidth * lowHeight * 3)
            iv_stitch_low(ctx.data!.assumingMemoryBound(to: UInt8.self), Int32(w), Int32(h), low, Int32(lowWidth), Int32(lowHeight))
        }

        deinit { low.deallocate() }

        /// Its corners (in its own pixels, each already divided by `shrink` so they're the full-size picture's).
        fileprivate func features(side: Int) -> (features: [iv_feature], shrink: Double) {
            let m = min(1, Double(side) / Double(max(width, height)))
            let w = max(1, Int((Double(width) * m).rounded())), h = max(1, Int((Double(height) * m).rounded()))
            var gray = [UInt8](repeating: 0, count: w * h)
            guard let image else { return ([], 1) }
            let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.interpolationQuality = m < 1 ? .high : .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return ([], 1) }
            var found = [iv_feature](repeating: iv_feature(), count: 6000)
            let n = iv_stitch_features(gray, Int32(w), Int32(h), &found, Int32(found.count))
            return (Array(found.prefix(Int(n))), Double(w) / Double(max(fullSize.width, 1)))
        }
    }

    /// The focal length of the picture `properties` are of, in its pixels (it `pixels` in size), from the 35 mm
    /// equivalent a camera writes.
    static func focal(from properties: [String: Any], pixels: CGSize) -> Double? {
        guard let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let f35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.doubleValue, f35 > 4, f35 < 2000 else { return nil }
        return f35 / 43.27 * hypot(pixels.width, pixels.height)
    }

    // MARK: How the pictures lie on each other

    /// How the pictures lie on each other, and how the whole is best looked at.
    struct Layout: Sendable {
        /// For each picture, the homography taking its (full-size) pixels onto the middle picture's; nil for
        /// one that shows nothing the others do.
        var onto: [simd_double3x3?]
        /// What each picture's pixels are multiplied by, to even out their exposures.
        var gains: [Float]
        /// The middle picture: the one the others are laid on.
        var reference: Int
        /// The middle picture's focal length and middle, in its full-size pixels.
        var focal: Double
        var center: SIMD2<Double>
        /// Whether any file said what its lens was. (Without, as with scans, the pictures are joined flat.)
        var knowsLens: Bool
        /// The view to look from, as seen from the middle picture's camera: its columns are the view's right,
        /// down and ahead. Level when `isLevel`: the cameras' own level, worked out from how they were turned.
        var upright: simd_double3x3
        var isLevel: Bool

        var joined: [Int] { onto.indices.filter { onto[$0] != nil } }

        /// The layout of just the pictures that were joined, in their order, and which of the pictures those are.
        func joinedOnly() -> (layout: Layout, indices: [Int]) {
            let keep = joined
            var only = self
            only.onto = keep.map { onto[$0] }
            only.gains = keep.map { gains[$0] }
            only.reference = keep.firstIndex(of: reference) ?? 0
            return (only, keep)
        }
    }

    private struct Link {
        var a: Int, b: Int
        /// b's full-size pixels onto a's.
        var h: simd_double3x3
        var agreeing: Int
        /// How much brighter b is than a.
        var gain: Double
    }

    /// Lines the pictures up. Throws `noOverlap` when no two of them can be joined; pictures that can't be
    /// joined to the rest are left out (`onto` nil).
    static func layout(of pictures: [Picture], seed: UInt64 = 1, progress: (@Sendable (Double) -> Bool)? = nil) throws -> Layout {
        let n = pictures.count
        guard n >= 2 else { throw StitchError.tooFew }
        var corners: [(features: [iv_feature], shrink: Double)] = []
        for (i, p) in pictures.enumerated() {
            corners.append(p.features(side: workingSide))
            if progress?(0.6 * Double(i + 1) / Double(n)) == true { throw StitchError.cancelled }
        }
        // Every pair that shows the same things.
        var links: [Link] = []
        let pairs = n * (n - 1) / 2
        var tried = 0
        for a in 0..<n {
            for b in (a + 1)..<n {
                tried += 1
                var h = [Double](repeating: 0, count: 9), matched: Int32 = 0, gain = 1.0
                let agreeing = iv_stitch_align(corners[a].features, Int32(corners[a].features.count), corners[b].features, Int32(corners[b].features.count),
                                               2.5, seed &+ UInt64(a * 131 + b), &h, &matched, &gain)
                #if DEBUG
                if ProcessInfo.processInfo.environment["AOK_STITCH_TRACE"] != nil {
                    print("  pictures \(a) and \(b): \(corners[a].features.count) and \(corners[b].features.count) corners, \(matched) paired, \(agreeing) agree, gain \(gain), h \(h)")
                }
                #endif
                if agreeing >= 20, Double(agreeing) >= 0.1 * Double(matched) {
                    // From the sizes they were compared at to full size.
                    let sa = corners[a].shrink, sb = corners[b].shrink
                    let full = normalized(diagonal(1 / sa) * matrix(h) * diagonal(sb))
                    if plausible(full, from: pictures[b].fullSize, onto: pictures[a].fullSize) {
                        links.append(Link(a: a, b: b, h: full, agreeing: Int(agreeing), gain: gain))
                    }
                }
                if progress?(0.6 + 0.4 * Double(tried) / Double(pairs)) == true { throw StitchError.cancelled }
            }
        }
        guard !links.isEmpty else { throw StitchError.noOverlap }

        // The biggest set of pictures joined to each other, by their surest links (a spanning tree).
        var group = Array(0..<n)
        func root(_ i: Int) -> Int { var i = i; while group[i] != i { i = group[i] }; return i }
        var tree: [Link] = []
        for link in links.sorted(by: { $0.agreeing > $1.agreeing }) {
            let ra = root(link.a), rb = root(link.b)
            guard ra != rb else { continue }
            group[max(ra, rb)] = min(ra, rb)
            tree.append(link)
        }
        let sizes = Dictionary(grouping: 0..<n, by: root).mapValues(\.count)
        let chosen = sizes.max { ($0.value, -$0.key) < ($1.value, -$1.key) }!.key
        let members = (0..<n).filter { root($0) == chosen }
        tree = tree.filter { root($0.a) == chosen }
        var neighbors = [[(to: Int, link: Link)]](repeating: [], count: n)
        for link in tree {
            neighbors[link.a].append((link.b, link))
            neighbors[link.b].append((link.a, link))
        }
        /// How many links away each picture is from `start`, and in what order they're reached.
        func walk(from start: Int) -> (order: [Int], depth: [Int: Int]) {
            var depth = [start: 0], order = [start], next = 0
            while next < order.count {
                let i = order[next]
                next += 1
                for (to, _) in neighbors[i] where depth[to] == nil {
                    depth[to] = depth[i]! + 1
                    order.append(to)
                }
            }
            return (order, depth)
        }
        // The middle picture: the one the furthest picture is fewest links from.
        let reference = members.min { a, b in
            let da = walk(from: a).depth.values.max() ?? 0, db = walk(from: b).depth.values.max() ?? 0
            return da != db ? da < db : a < b
        }!

        var onto = [simd_double3x3?](repeating: nil, count: n)
        var brightness = [Double](repeating: 1, count: n)
        onto[reference] = matrix_identity_double3x3
        for i in walk(from: reference).order {
            guard let mine = onto[i] else { continue }
            for (to, link) in neighbors[i] where onto[to] == nil {
                // (The link takes b onto a.)
                onto[to] = normalized(mine * (link.b == to ? link.h : link.h.inverse))
                brightness[to] = brightness[i] * (link.b == to ? link.gain : 1 / max(link.gain, 0.01))
            }
        }
        // Each is brought to the brightness between them all, not to the middle picture's.
        let logs = members.map { log(max(brightness[$0], 0.01)) }
        let middle = exp(logs.reduce(0, +) / Double(logs.count))
        let gains = (0..<n).map { Float(min(max(middle / max(brightness[$0], 0.01), 0.5), 2)) }

        let ref = pictures[reference]
        let across = hypot(ref.fullSize.width, ref.fullSize.height)
        let known = members.compactMap { i in pictures[i].focal.map { $0 / hypot(pictures[i].fullSize.width, pictures[i].fullSize.height) } }.sorted()
        // (Without a lens, about a phone's main camera: it only shapes a view that isn't flat.)
        let focal = ref.focal ?? (known.isEmpty ? 0.6 : known[known.count / 2]) * across
        var layout = Layout(onto: onto, gains: gains, reference: reference, focal: focal,
                            center: SIMD2(ref.fullSize.width / 2, ref.fullSize.height / 2), knowsLens: !known.isEmpty,
                            upright: matrix_identity_double3x3, isLevel: false)
        if layout.knowsLens { (layout.upright, layout.isLevel) = upright(pictures, layout: layout) }
        return layout
    }

    /// Whether `h`, taking a picture `from` this size onto one `onto` that size, is how one picture can lie on
    /// another: where they overlap, it's the right way round and neither squeezed nor blown up. (Not judged by
    /// the picture's corners: with a wide lens, one of them can be behind the other picture's camera.)
    private static func plausible(_ h: simd_double3x3, from: CGSize, onto: CGSize) -> Bool {
        var overlapping = 0
        for iy in 0...8 {
            for ix in 0...8 {
                let x = Double(ix) / 8 * from.width, y = Double(iy) / 8 * from.height
                let p = h * SIMD3(x, y, 1)
                guard p.z > 1e-9 else { continue }
                let u = p.x / p.z, v = p.y / p.z
                guard u >= 0, v >= 0, u <= onto.width, v <= onto.height else { continue }
                // How the picture is stretched and turned there.
                let a = (h[0][0] - u * h[0][2]) / p.z, b = (h[1][0] - u * h[1][2]) / p.z
                let c = (h[0][1] - v * h[0][2]) / p.z, d = (h[1][1] - v * h[1][2]) / p.z
                let area = a * d - b * c
                guard area > 0.09, area < 11 else { return false }
                overlapping += 1
            }
        }
        return overlapping > 0
    }

    /// The view to look at the pictures from: ahead, where they look between them; down, the cameras' own down
    /// when the files say (a phone's does) or when it can be told from how they were turned (a camera panned
    /// keeps its sides level, so the pictures' left-to-right directions lie in a level plane).
    private static func upright(_ pictures: [Picture], layout: Layout) -> (simd_double3x3, Bool) {
        let ref = pictures[layout.reference]
        var rights: [SIMD3<Double>] = [], downs: [SIMD3<Double>] = [], aheads: [SIMD3<Double>] = [], gravity: [SIMD3<Double>] = []
        let kRef = intrinsics(layout.focal, layout.center)
        for i in layout.joined {
            guard let h = layout.onto[i] else { continue }
            let p = pictures[i]
            let f = p.focal ?? layout.focal * hypot(p.fullSize.width, p.fullSize.height) / hypot(ref.fullSize.width, ref.fullSize.height)
            let turn = rotation(nearest: kRef.inverse * h * intrinsics(f, SIMD2(p.fullSize.width / 2, p.fullSize.height / 2)))
            rights.append(turn.columns.0)
            downs.append(turn.columns.1)
            aheads.append(turn.columns.2)
            if let down = p.down { gravity.append(simd_normalize(turn * down)) }
        }
        let meanAhead = simd_normalize(aheads.reduce(SIMD3<Double>(repeating: 0), +))
        var down = simd_normalize(downs.reduce(SIMD3<Double>(repeating: 0), +))
        var level = false
        // From how the cameras were turned: the plane their left-to-right directions lie in is level, if they
        // were turned at least a dozen degrees between them (less, and the plane is anyone's guess) and what's
        // then down is roughly down in each picture (a camera rolled between pictures wasn't panned).
        var scatter = simd_double3x3(0)
        for r in rights { scatter += simd_double3x3(rows: [r * r.x, r * r.y, r * r.z]) }
        let (values, vectors) = eigen(scatter)
        var panned: SIMD3<Double>?
        if values[2] > 0, values[1] / values[2] > 0.011 {
            let normal = simd_dot(vectors[0], down) < 0 ? -vectors[0] : vectors[0]
            if downs.allSatisfy({ simd_dot($0, normal) > 0.77 }) { panned = normal }
        }
        // From the files: what each camera's motion sensor read, if they agree (within ten degrees).
        var sensed: SIMD3<Double>?
        if !gravity.isEmpty {
            let mean = simd_normalize(gravity.reduce(SIMD3<Double>(repeating: 0), +))
            if gravity.allSatisfy({ simd_dot($0, mean) > 0.985 }) { sensed = mean }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["AOK_STITCH_TRACE"] != nil {
            func degrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { acos(min(1, max(-1, simd_dot(a, b)))) * 180 / .pi }
            print("  down from the sensors: \(sensed.map { "\($0)" } ?? "none") (\(gravity.count) readings\(gravity.count > 1 ? ", \(degrees(gravity[0], gravity[1]))° apart" : ""))")
            print("  down from the panning: \(panned.map { "\($0)" } ?? "none")\(sensed != nil && panned != nil ? ", \(degrees(sensed!, panned!))° from the sensors'" : "")")
        }
        #endif
        // (Not for pictures looking steeply up or down, more than 50° from level: there's no horizon to set
        // level in them, and a level view would look away from what they show.)
        if let found = sensed ?? panned, abs(simd_dot(meanAhead, found)) < 0.77 {
            down = found
            level = true
        }
        var ahead = meanAhead - down * simd_dot(meanAhead, down)
        if simd_length(ahead) < 0.05 {
            // (Looking straight up or down: ahead is as the middle picture has it.)
            ahead = SIMD3(0, 0, 1) - down * down.z
            if simd_length(ahead) < 0.05 { return (matrix_identity_double3x3, false) }
        }
        ahead = simd_normalize(ahead)
        if !level {
            // No telling which way is down: the pictures are looked at as they were taken, from between them.
            ahead = meanAhead
            let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), ahead))
            return (simd_double3x3(columns: (right, simd_cross(ahead, right), ahead)), false)
        }
        let right = simd_normalize(simd_cross(down, ahead))
        return (simd_double3x3(columns: (right, down, ahead)), true)
    }

    // MARK: The view

    enum Shape: String, CaseIterable, Identifiable, Sendable {
        case automatic, flat, cylinder, sphere

        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .flat: "Flat"
            case .cylinder: "Cylinder"
            case .sphere: "Sphere"
            }
        }
        fileprivate var projection: Int32 {
            switch self {
            case .cylinder: Int32(IV_STITCH_CYLINDER)
            case .sphere: Int32(IV_STITCH_SPHERE)
            default: Int32(IV_STITCH_FLAT)
            }
        }
    }

    /// How the stitched picture is looked at.
    struct Look: Equatable, Sendable {
        var shape = Shape.automatic
        /// Degrees: the picture turned clockwise; the view tilted up; the view turned to the right.
        var level = 0.0
        var tilt = 0.0
        var turn = 0.0

        var isStraight: Bool { level == 0 && tilt == 0 && turn == 0 }
    }

    /// A stitched picture.
    struct Stitched: @unchecked Sendable {
        /// Transparent where no picture covers.
        let image: CGImage
        /// The largest upright rectangle of it that's covered everywhere (pixels, from the top left).
        let covered: CGRect?
        /// How much of it is covered (0...1).
        let coverage: Double
        /// The shape it was made in (never `automatic`).
        let shape: Shape
        /// Whether parts of the pictures were too far round to show in this shape.
        let trimmed: Bool
        /// Its pixels to one unit of the view, and the view's coordinates (in units) of its top left corner:
        /// what places a fill made at another size on it.
        let scale: Double
        let origin: CGPoint
    }

    private final class Reporter {
        let report: @Sendable (Double) -> Bool
        init(_ report: @escaping @Sendable (Double) -> Bool) { self.report = report }
    }

    /// The shape `automatic` stands for with these pictures: flat while they take in little enough for that,
    /// a cylinder for a wide view, a sphere for one that's tall as well.
    static func shape(for pictures: [Picture], layout: Layout, look: Look = Look()) -> Shape {
        guard look.shape == .automatic else { return look.shape }
        guard layout.knowsLens else { return .flat }
        // (As the pictures lie, not as the user has turned them: the shape doesn't change under a slider.)
        let sources = sources(pictures, layout: layout, look: Look())
        var bounds = [Double](repeating: 0, count: 4), trimmed: Int32 = 0
        guard iv_stitch_bounds(sources, Int32(sources.count), Int32(IV_STITCH_SPHERE), 1, &bounds, &trimmed) != 0 else { return .flat }
        let wide = (bounds[2] - bounds[0]) * 180 / .pi, tall = (bounds[3] - bounds[1]) * 180 / .pi
        if max(wide, tall) <= 80 { return .flat }
        return tall <= 95 ? .cylinder : .sphere
    }

    /// How big the stitched picture is at full size (before `maxSide` and `maxPixels` hold it down), and how
    /// much smaller than that it has to be made: 1, or less for one too big.
    static func size(for pictures: [Picture], layout: Layout, look: Look) -> (size: CGSize, fit: Double)? {
        let shape = shape(for: pictures, layout: layout, look: look)
        let sources = sources(pictures, layout: layout, look: look)
        var bounds = [Double](repeating: 0, count: 4), trimmed: Int32 = 0
        guard iv_stitch_bounds(sources, Int32(sources.count), shape.projection, layout.focal, &bounds, &trimmed) != 0 else { return nil }
        let w = bounds[2] - bounds[0], h = bounds[3] - bounds[1]
        guard w >= 1, h >= 1 else { return nil }
        let fit = min(1, Double(maxSide) / max(w, h), (Double(maxPixels) / (w * h)).squareRoot())
        return (CGSize(width: w, height: h), fit)
    }

    /// The pictures stitched, no bigger than `maxSide` (nil: as big as they make it, within the limits).
    /// `sharp` samples them at their best, for the picture that's saved. `progress` returns true to cancel.
    static func render(_ pictures: [Picture], layout: Layout, look: Look, maxSide: Int? = nil, sharp: Bool = false,
                       progress: (@Sendable (Double) -> Bool)? = nil) throws -> Stitched {
        let shape = shape(for: pictures, layout: layout, look: look)
        let sources = sources(pictures, layout: layout, look: look)
        guard !sources.isEmpty else { throw StitchError.noOverlap }
        var unit = [Double](repeating: 0, count: 4), trimmed: Int32 = 0
        guard iv_stitch_bounds(sources, Int32(sources.count), shape.projection, 1, &unit, &trimmed) != 0 else { throw StitchError.failed }
        let w = (unit[2] - unit[0]) * layout.focal, h = (unit[3] - unit[1]) * layout.focal
        guard w >= 1, h >= 1 else { throw StitchError.failed }
        var fit = min(1, Double(Self.maxSide) / max(w, h), (Double(maxPixels) / (w * h)).squareRoot())
        if let maxSide { fit = min(fit, Double(maxSide) / max(w, h)) }
        let scale = layout.focal * fit
        let width = max(1, Int((w * fit).rounded(.up))), height = max(1, Int((h * fit).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: pictures[0].space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { throw StitchError.failed }
        let out = data.assumingMemoryBound(to: UInt8.self)
        var view = iv_stitch_view(projection: shape.projection, scale: scale, left: unit[0] * scale, top: unit[1] * scale)
        let reporter = progress.map(Reporter.init)
        let callback: iv_fill_progress? = reporter == nil ? nil : { context, fraction in
            guard let context else { return 0 }
            return Unmanaged<Reporter>.fromOpaque(context).takeUnretainedValue().report(fraction) ? 1 : 0
        }
        let status = withExtendedLifetime(pictures) {
            iv_stitch_render(sources, Int32(sources.count), &view, out, Int32(width), Int32(height), sharp ? 1 : 0,
                             callback, reporter.map { Unmanaged.passUnretained($0).toOpaque() })
        }
        withExtendedLifetime(reporter) {}
        switch Int(status) {
        case IV_FILL_OK: break
        case IV_FILL_CANCELLED: throw StitchError.cancelled
        default: throw StitchError.failed
        }
        var rect = [Int32](repeating: 0, count: 4)
        let covered = iv_stitch_covered_rect(out, Int32(width), Int32(height), &rect) != 0
            ? CGRect(x: Int(rect[0]), y: Int(rect[1]), width: Int(rect[2]), height: Int(rect[3])) : nil
        var opaque = 0
        for i in stride(from: 3, to: width * height * 4, by: 4 * max(1, (width * height) / 200_000)) where out[i] == 255 { opaque += 1 }
        let sampled = (width * height + max(1, (width * height) / 200_000) - 1) / max(1, (width * height) / 200_000)
        guard let image = ctx.makeImage() else { throw StitchError.failed }
        return Stitched(image: image, covered: covered, coverage: Double(opaque) / Double(max(sampled, 1)), shape: shape, trimmed: trimmed != 0,
                        scale: scale, origin: CGPoint(x: unit[0], y: unit[1]))
    }

    /// The pictures as the C engine takes them: each with what takes a direction of the view to its pixels.
    private static func sources(_ pictures: [Picture], layout: Layout, look: Look) -> [iv_stitch_source] {
        let view = layout.upright * turned(look)
        let k = intrinsics(layout.focal, layout.center)
        return layout.joined.compactMap { i in
            guard let onto = layout.onto[i] else { return nil }
            let p = pictures[i]
            let m = diagonal(p.scale) * onto.inverse * k * view
            return iv_stitch_source(rgba: p.pixels, width: Int32(p.width), height: Int32(p.height), low: UnsafePointer(p.low),
                                    lowWidth: Int32(p.lowWidth), lowHeight: Int32(p.lowHeight),
                                    toSource: (m[0][0], m[1][0], m[2][0], m[0][1], m[1][1], m[2][1], m[0][2], m[1][2], m[2][2]),
                                    gain: layout.gains[i])
        }
    }

    /// The user's turning of the view: to the right, up, and the picture clockwise.
    private static func turned(_ look: Look) -> simd_double3x3 {
        let y = look.turn * .pi / 180, p = look.tilt * .pi / 180, r = -look.level * .pi / 180
        let ry = simd_double3x3(rows: [SIMD3(cos(y), 0, sin(y)), SIMD3(0, 1, 0), SIMD3(-sin(y), 0, cos(y))])
        let rx = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(p), -sin(p)), SIMD3(0, sin(p), cos(p))])
        let rz = simd_double3x3(rows: [SIMD3(cos(r), -sin(r), 0), SIMD3(sin(r), cos(r), 0), SIMD3(0, 0, 1)])
        return ry * rx * rz
    }

    // MARK: Matrices

    private static func matrix(_ rows: [Double]) -> simd_double3x3 {
        simd_double3x3(rows: [SIMD3(rows[0], rows[1], rows[2]), SIMD3(rows[3], rows[4], rows[5]), SIMD3(rows[6], rows[7], rows[8])])
    }

    private static func diagonal(_ s: Double) -> simd_double3x3 { simd_double3x3(diagonal: SIMD3(s, s, 1)) }

    static func intrinsics(_ focal: Double, _ center: SIMD2<Double>) -> simd_double3x3 {
        simd_double3x3(rows: [SIMD3(focal, 0, center.x), SIMD3(0, focal, center.y), SIMD3(0, 0, 1)])
    }

    /// `h` scaled so its determinant is 1 (and so the right way round: what's in front stays in front).
    private static func normalized(_ h: simd_double3x3) -> simd_double3x3 {
        let d = h.determinant
        guard d.isFinite, abs(d) > 1e-30 else { return h }
        return h * (1 / cbrt(d))
    }

    /// The rotation nearest to `m` (which is one but for the errors in it and in the focal lengths).
    private static func rotation(nearest m: simd_double3x3) -> simd_double3x3 {
        var r = normalized(m)
        for _ in 0..<30 {
            let next = (r + r.inverse.transpose) * 0.5
            let moved = simd_length(next.columns.0 - r.columns.0) + simd_length(next.columns.1 - r.columns.1) + simd_length(next.columns.2 - r.columns.2)
            r = next
            if moved < 1e-12 { break }
        }
        return r
    }

    /// A symmetric matrix's eigenvalues, smallest first, and their vectors (Jacobi's turns).
    private static func eigen(_ m: simd_double3x3) -> (values: [Double], vectors: [SIMD3<Double>]) {
        var a = [[m[0][0], m[1][0], m[2][0]], [m[0][1], m[1][1], m[2][1]], [m[0][2], m[1][2], m[2][2]]]
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<40 {
            var off = 0.0
            for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                off += abs(a[p][q])
                guard abs(a[p][q]) > 1e-300 else { continue }
                let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<3 {
                    let akp = a[k][p], akq = a[k][q]
                    a[k][p] = c * akp - s * akq
                    a[k][q] = s * akp + c * akq
                }
                for k in 0..<3 {
                    let apk = a[p][k], aqk = a[q][k]
                    a[p][k] = c * apk - s * aqk
                    a[q][k] = s * apk + c * aqk
                }
                for k in 0..<3 {
                    let vkp = v[k][p], vkq = v[k][q]
                    v[k][p] = c * vkp - s * vkq
                    v[k][q] = s * vkp + c * vkq
                }
            }
            if off < 1e-14 { break }
        }
        let order = [0, 1, 2].sorted { a[$0][$0] < a[$1][$1] }
        return (order.map { a[$0][$0] }, order.map { SIMD3(v[0][$0], v[1][$0], v[2][$0]) })
    }
}
