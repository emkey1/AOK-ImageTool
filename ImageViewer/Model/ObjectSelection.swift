import CoreGraphics
import CoreImage
import Foundation

/// Select Object's selection: a soft-edged mask over the picture as it's shown (one byte a pixel, rows
/// top-down, 255 = selected), built up in steps that can each be taken back: the objects found under clicks,
/// and what's painted in or out by hand. Every step changes the selection as it then is: what was painted in
/// stays in when a later click finds more, and what was painted out stays out unless a later click finds that
/// part anew.
nonisolated struct ObjectSelection: Sendable {
    /// A click, for showing where it was (normalized, lower-left origin, as Vision has it).
    struct Mark: Equatable, Sendable {
        let point: CGPoint
        let added: Bool
    }

    /// How the selection is shown over the picture.
    enum Look: String, CaseIterable, Identifiable, Sendable {
        /// The rest of the picture gray and dark, the selection as it is, a line around it.
        case dimmed
        /// The selection tinted, a line around it, the rest as it is.
        case tinted
        /// The selection on its own, as cutting it out leaves it.
        case alone

        var id: String { rawValue }
        var title: String {
            switch self {
            case .dimmed: "Dimmed"
            case .tinted: "Tinted"
            case .alone: "Alone"
            }
        }
    }

    /// A value above this is selected, for telling whether anything is (a faint edge isn't a selection).
    static let threshold: UInt8 = 25
    /// Steps kept to take back.
    static let maxSteps = 60

    let width: Int
    let height: Int
    private(set) var mask: [UInt8]
    /// The clicks Vision selects by together (normalized, lower-left origin), and what it made of them when
    /// they were last applied: its next result changes the selection only where the two differ.
    private(set) var included: [CGPoint] = []
    private(set) var excluded: [CGPoint] = []
    private var found: [UInt8]?
    private var foundPacked: Data?
    private(set) var marks: [Mark] = []
    /// Clear started it over: it no longer goes on from what it was opened with.
    private(set) var startedOver = false
    private var undone: [Step] = []
    private var redone: [Step] = []

    /// The selection as it was before a step (its masks packed: mostly runs of black and white).
    private struct Step: Sendable {
        let mask: Data
        let included: [CGPoint]
        let excluded: [CGPoint]
        let found: Data?
        let marks: [Mark]
        let startedOver: Bool
    }

    /// Nothing selected, or `mask` (`width` × `height` bytes, rows top-down) to start from.
    init(width: Int, height: Int, mask: [UInt8]? = nil) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        let count = self.width * self.height
        if let mask, mask.count == count {
            self.mask = mask
        } else {
            self.mask = [UInt8](repeating: 0, count: count)
        }
    }

    var size: CGSize { CGSize(width: width, height: height) }
    var canUndo: Bool { !undone.isEmpty }
    var canRedo: Bool { !redone.isEmpty }

    /// Nothing is selected.
    var isEmpty: Bool { !mask.contains { $0 > Self.threshold } }

    /// Nothing is selected and no click is in play (one that left everything out still refines the next): there's
    /// nothing for Clear to do.
    var isBlank: Bool { isEmpty && marks.isEmpty }

    /// How much of the picture is selected, 0...1.
    var coverage: Double {
        var sum = 0
        mask.withUnsafeBufferPointer { p in for v in p { sum &+= Int(v) } }
        return Double(sum) / (255 * Double(mask.count))
    }

    /// The selection at a pixel (x from the left, y from the top), 0...255.
    func value(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return mask[y * width + x]
    }

    /// The selection as a mask (white = selected), the picture's size.
    var image: CIImage? { Self.image(mask, width: width, height: height) }

    // MARK: Steps

    /// What's painted (`points` in pixels from the top left, a brush `diameter` pixels wide) added to the
    /// selection, or with `subtract` taken from it. A stroke that comes back around to where it began takes
    /// everything inside it as well. False when it changed nothing.
    @discardableResult
    mutating func paint(_ points: [CGPoint], diameter: CGFloat, subtract: Bool) -> Bool {
        guard let stroke = Self.stroke(points, diameter: diameter, width: width, height: height) else { return false }
        return combine(stroke.bytes, within: stroke.bounds, subtract: subtract, mark: nil)
    }

    /// An object found on its own under a click at `point` (`object`: the picture's size) added to the selection
    /// or taken from it.
    @discardableResult
    mutating func take(_ object: [UInt8], subtract: Bool, at point: CGPoint) -> Bool {
        guard object.count == mask.count else { return false }
        return combine(object, within: CGRect(x: 0, y: 0, width: width, height: height), subtract: subtract,
                       mark: Mark(point: point, added: !subtract))
    }

    /// What Vision makes of the clicks so far with the one at `point` added (`exclude`: as one to leave out):
    /// `result`, the picture's size. The selection changes where that differs from what the clicks before it
    /// gave, and stays as it is (as painted, say) everywhere else.
    mutating func refine(_ result: [UInt8], adding point: CGPoint, exclude: Bool) {
        guard result.count == mask.count else { return }
        remember()
        let count = mask.count
        let before = found
        var changed = mask
        changed.withUnsafeMutableBufferPointer { m in
            result.withUnsafeBufferPointer { new in
                if let before {
                    before.withUnsafeBufferPointer { old in
                        for i in 0..<count { m[i] = UInt8(clamping: Int(m[i]) + Int(new[i]) - Int(old[i])) }
                    }
                } else {
                    for i in 0..<count { m[i] = UInt8(clamping: Int(m[i]) + Int(new[i])) }
                }
            }
        }
        mask = changed
        found = result
        foundPacked = Self.packed(result)
        if exclude { excluded.append(point) } else { included.append(point) }
        marks.append(Mark(point: point, added: !exclude))
    }

    /// Nothing selected any more (a step, like the others).
    mutating func clear() {
        guard !isBlank else { return }
        remember()
        mask = [UInt8](repeating: 0, count: mask.count)
        included = []
        excluded = []
        found = nil
        foundPacked = nil
        marks = []
        startedOver = true
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let step = undone.popLast() else { return false }
        redone.append(current)
        restore(step)
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let step = redone.popLast() else { return false }
        undone.append(current)
        restore(step)
        return true
    }

    private var current: Step {
        Step(mask: Self.packed(mask), included: included, excluded: excluded, found: foundPacked, marks: marks, startedOver: startedOver)
    }

    private mutating func remember() {
        undone.append(current)
        if undone.count > Self.maxSteps { undone.removeFirst(undone.count - Self.maxSteps) }
        redone.removeAll()
    }

    private mutating func restore(_ step: Step) {
        mask = Self.unpacked(step.mask, count: mask.count)
        included = step.included
        excluded = step.excluded
        foundPacked = step.found
        found = step.found.map { Self.unpacked($0, count: mask.count) }
        marks = step.marks
        startedOver = step.startedOver
    }

    /// `other` (the picture's size) laid into the selection within `bounds` (pixels from the top left): the
    /// greater of the two where it's added, and the selection less its share of it where it's taken away.
    private mutating func combine(_ other: [UInt8], within bounds: CGRect, subtract: Bool, mark: Mark?) -> Bool {
        let area = bounds.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard area.width >= 1, area.height >= 1 else { return false }
        let x0 = Int(area.minX), x1 = Int(area.maxX), y0 = Int(area.minY), y1 = Int(area.maxY)
        var changed = false
        var result = mask
        let w = width
        result.withUnsafeMutableBufferPointer { m in
            other.withUnsafeBufferPointer { o in
                for y in y0..<y1 {
                    for i in (y * w + x0)..<(y * w + x1) {
                        let old = m[i], s = o[i]
                        guard s > 0 else { continue }
                        let new = subtract ? UInt8((Int(old) * (255 - Int(s)) + 127) / 255) : max(old, s)
                        if new != old {
                            m[i] = new
                            changed = true
                        }
                    }
                }
            }
        }
        guard changed else { return false }
        remember()
        mask = result
        if let mark { marks.append(mark) }
        return true
    }

    // MARK: Pixels

    /// A mask (Vision's, or one kept with the edits; any size) as bytes over a picture `width` × `height`.
    static func bytes(of mask: CIImage, width: Int, height: Int) -> [UInt8] {
        let ext = mask.extent
        guard ext.width > 0, ext.height > 0, !ext.isInfinite else { return [UInt8](repeating: 0, count: width * height) }
        let fitted = mask
            .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / ext.width, y: CGFloat(height) / ext.height))
        return ImageDecoder.ciContext.renderGray(fitted, bounds: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func image(_ bytes: [UInt8], width: Int, height: Int) -> CIImage? {
        guard bytes.count == width * height, let provider = CGDataProvider(data: Data(bytes) as CFData),
              let gray = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return CIImage(cgImage: gray, options: [.colorSpace: NSNull()])
    }

    /// A brush stroke as a mask the picture's size, and the part of the picture it touches. A stroke that
    /// circles something takes everything inside it.
    static func stroke(_ points: [CGPoint], diameter: CGFloat, width: Int, height: Int) -> (bytes: [UInt8], bounds: CGRect)? {
        guard let first = points.first, width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let d = max(diameter, 1)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // (The bitmap's rows run top-down; the points do too, so the drawing is flipped to match.)
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            let path = CGMutablePath()
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
            if points.count == 1 { path.addLine(to: first) }
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineWidth(d)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            if isLoop(points, diameter: d) {
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.addPath(path)
                ctx.closePath()
                ctx.fillPath()
            }
            return true
        }
        guard drawn else { return nil }
        var box = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        return (bytes, box.insetBy(dx: -d / 2 - 2, dy: -d / 2 - 2))
    }

    /// A stroke that comes back around to where it started and encloses more than it paints: circling something.
    static func isLoop(_ points: [CGPoint], diameter: CGFloat) -> Bool {
        guard points.count > 8, let first = points.first, let last = points.last else { return false }
        var length: CGFloat = 0
        var area: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            length += hypot(b.x - a.x, b.y - a.y)
            area += a.x * b.y - b.x * a.y
        }
        area += last.x * first.y - first.x * last.y
        let gap = hypot(last.x - first.x, last.y - first.y)
        return length > 6 * diameter && gap < max(1.5 * diameter, 0.12 * length) && abs(area) / 2 > length * diameter
    }

    private static func packed(_ bytes: [UInt8]) -> Data {
        let data = Data(bytes)
        return (try? (data as NSData).compressed(using: .lz4) as Data) ?? data
    }

    private static func unpacked(_ data: Data, count: Int) -> [UInt8] {
        if let plain = try? (data as NSData).decompressed(using: .lz4) as Data, plain.count == count { return [UInt8](plain) }
        return data.count == count ? [UInt8](data) : [UInt8](repeating: 0, count: count)
    }

    // MARK: Showing it

    /// The picture with the selection shown on it, `look`'s way: what Select Object draws. `picture` and `mask`
    /// may differ in size (the mask is stretched over the picture). The line around the selection is about a
    /// point and a half wide on screen where `pixelsPerPoint` of the picture's pixels make a point.
    static func shown(_ picture: CGImage, mask: CIImage, look: Look, pixelsPerPoint: CGFloat = 1) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        let ext = mask.extent
        guard ext.width > 0, ext.height > 0, rect.width > 0, rect.height > 0 else { return nil }
        let m = mask
            .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / ext.width, y: rect.height / ext.height))
            .cropped(to: rect)
        let source = CIImage(cgImage: picture)
        func blend(_ top: CIImage, over bottom: CIImage, where mask: CIImage) -> CIImage {
            top.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bottom, kCIInputMaskImageKey: mask])
        }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CIImage {
            CIImage(color: CIColor(red: r, green: g, blue: b, alpha: a)).cropped(to: rect)
        }
        // (As deep as the picture, so an HDR photo isn't flattened to show its selection.)
        let format: CIFormat = picture.bitsPerComponent > 8 ? .RGBAh : .RGBA8
        let space = picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var out: CIImage
        switch look {
        case .dimmed:
            // The rest gray and dark, so the selection stands out by its color as well as its light.
            let rest = source
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputBrightnessKey: 0.0, kCIInputContrastKey: 1.0])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.2, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.2, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.2, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
            out = blend(source, over: rest, where: m)
        case .tinted:
            out = blend(color(0.2, 0.5, 1, 0.45).composited(over: source), over: source, where: m)
        case .alone:
            // (Over nothing: the view draws its checkerboard behind.)
            return ImageDecoder.ciContext.createCGImage(blend(source, over: CIImage(color: .clear).cropped(to: rect), where: m).cropped(to: rect),
                                                        from: rect, format: format, colorSpace: space)
        }
        // The line: white between dark edges, so it shows on any color. It runs where the selection is half
        // selected, as strong along a soft edge (fur, hair) as along a hard one.
        let edge = m
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 8, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 8, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 8, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -3.5, y: -3.5, z: -3.5, w: 0),
            ])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                         "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .cropped(to: rect)
        let outer = edge.applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: max(1.5, 1.7 * pixelsPerPoint)])
        let inner = edge.applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: max(1, 0.85 * pixelsPerPoint)])
        out = blend(color(0, 0, 0, 0.6).composited(over: out), over: out, where: outer)
        out = blend(color(1, 1, 1, 0.97).composited(over: out), over: out, where: inner)
        return ImageDecoder.ciContext.createCGImage(out.cropped(to: rect), from: rect, format: format, colorSpace: space)
    }
}
