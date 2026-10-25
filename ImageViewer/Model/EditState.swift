import CoreGraphics
import Foundation

nonisolated enum FilterPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, vivid, warm, cool, dramatic, mono, noir, silvertone, chrome, fade, instant, process, transfer, sepia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Original"
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .dramatic: "Dramatic"
        case .mono: "Mono"
        case .noir: "Noir"
        case .silvertone: "Silvertone"
        case .chrome: "Chrome"
        case .fade: "Fade"
        case .instant: "Instant"
        case .process: "Process"
        case .transfer: "Transfer"
        case .sepia: "Sepia"
        }
    }
}

/// What part of the image to keep when cutting out.
nonisolated enum Cutout: Codable, Equatable, Hashable, Sendable {
    /// Foreground subjects detected by Vision.
    case subject
    /// A user-selected object (click-to-select); mask lives in `MaskStore`.
    case object(UUID)
}

/// What shows where a cutout removed the background.
nonisolated enum Backdrop: Codable, Equatable, Hashable, Sendable {
    /// A solid sRGB color, components 0...1.
    case color(red: Double, green: Double, blue: Double, alpha: Double)
    /// The image's own original pixels, blurred; `amount` 0...1.
    case blur(amount: Double)
    /// A picture kept by `BackdropStore`, drawn to fill the frame.
    case image(path: String)

    var isOpaque: Bool {
        if case .color(_, _, _, let alpha) = self { return alpha >= 1 }
        return true
    }

    /// A transplanted picture (chosen or generated), whose light the subject can be matched to.
    var isPicture: Bool {
        if case .image = self { return true }
        return false
    }
}

/// Content synthesized beyond the image's edges by Extend.
nonisolated struct ExtendFill: Codable, Equatable, Hashable, Sendable {
    /// A picture kept by `ExtendFillStore`, covering `canvas` (original pixels included, drawn underneath).
    var path: String
    /// The frame it was made for: normalized, top-left origin, same space as `EditState.crop` (exceeds 0...1).
    var canvas: CGRect
    /// Generated fills: the photo cross-fades into the fill over this band just inside its extended edges
    /// (a fraction of the photo's shorter side), where the fill holds a generated version of the photo's
    /// edge. nil: the photo sits on the fill with a hard edge.
    var feather: Double?
    /// A generated fill's quick first version, shown while the final one is made.
    var isDraft: Bool?
    /// For a scanned print, the picture inside its border (normalized, in the image): only that part of the
    /// photo is drawn over the fill, which replaces the border. nil: all of it.
    var content: CGRect?

    /// Whether a crop can use this fill (it lies within the canvas the fill covers).
    func covers(_ crop: CGRect) -> Bool {
        canvas.insetBy(dx: -0.002, dy: -0.002).contains(crop)
    }
}

/// An area painted out by Remove Objects: a patch over the original pixels, before any other edit.
nonisolated struct Removal: Codable, Equatable, Hashable, Sendable {
    /// A picture kept by `RemovalStore`, see-through around what it replaces so it blends in.
    var path: String
    /// Where it goes: normalized, top-left origin, in the image as decoded (upright, before other edits).
    var rect: CGRect
    /// How much of it shows (Change Objects' strength); nil is all of it.
    var opacity: Double?
}

/// How Extend fills the new area.
nonisolated enum ExtendMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Content-aware: texture copied from the photo itself (fast, always available).
    case match
    /// New content drawn by the on-device generative model (needs the model installed).
    case generate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .match: "Match Photo"
        case .generate: "Generate"
        }
    }
}

/// Black and white, the darkroom way: a camera filter decides how colors become grays (a red filter turns
/// blue skies dark), and the print can be toned. Image ▸ Black & White makes a copy with it.
nonisolated struct BlackAndWhite: Codable, Equatable, Hashable, Sendable {
    enum Filter: String, Codable, CaseIterable, Identifiable, Sendable {
        case neutral, red, orange, yellow, green, blue

        var id: String { rawValue }

        var title: String {
            switch self {
            case .neutral: "Neutral"
            case .red: "Red Filter"
            case .orange: "Orange Filter"
            case .yellow: "Yellow Filter"
            case .green: "Green Filter"
            case .blue: "Blue Filter"
            }
        }

        var help: String {
            switch self {
            case .neutral: "Grays as the eye sees brightness"
            case .red: "Dark, dramatic skies; smooth skin"
            case .orange: "Darker skies, warm skin tones lifted"
            case .yellow: "A little more contrast in skies"
            case .green: "Lighter foliage, more defined skin"
            case .blue: "Brighter skies and haze, darker skin and reds"
            }
        }

        /// How much each of red, green and blue (linear light) counts toward the gray; they add up to 1.
        var weights: (red: Double, green: Double, blue: Double) {
            switch self {
            case .neutral: (0.2126, 0.7152, 0.0722)
            case .red: (0.75, 0.25, 0)
            case .orange: (0.55, 0.40, 0.05)
            case .yellow: (0.40, 0.55, 0.05)
            case .green: (0.15, 0.80, 0.05)
            case .blue: (0.10, 0.30, 0.60)
            }
        }
    }

    enum Toning: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, sepia, warm, cool

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "None"
            case .sepia: "Sepia"
            case .warm: "Warm"
            case .cool: "Cool"
            }
        }

        /// What the gray is multiplied by, per channel, at full strength.
        var tint: (red: Double, green: Double, blue: Double) {
            switch self {
            case .none: (1, 1, 1)
            case .sepia: (1.12, 0.98, 0.76)
            case .warm: (1.06, 1, 0.9)
            case .cool: (0.9, 0.98, 1.1)
            }
        }
    }

    var filter = Filter.neutral
    var toning = Toning.none
    var toningAmount = 0.6

    /// The choice used last (Black & White starts from it).
    static var last: BlackAndWhite {
        get {
            UserDefaults.standard.data(forKey: PrefKey.blackAndWhite).flatMap { try? JSONDecoder().decode(BlackAndWhite.self, from: $0) }
                ?? BlackAndWhite()
        }
        set { Prefs.set(try? JSONEncoder().encode(newValue), PrefKey.blackAndWhite) }
    }
}

/// Four corners in normalized, lower-left-origin coordinates (Vision / Core Image convention).
nonisolated struct Quad: Codable, Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
}

/// Non-destructive edit recipe. Rendering it over the original produces the edited image.
nonisolated struct EditState: Codable, Equatable, Sendable {
    // Geometry
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    var straighten: Double = 0 {        // degrees, clockwise positive
        didSet { if straighten != oldValue { extendFill = nil } }
    }
    var crop: CGRect?                   // normalized, top-left origin, in post-rotation space; past 0...1 = Extend
    var perspective: Quad? {            // document/keystone correction, applied first
        didSet { if perspective != oldValue { extendFill = nil } }
    }
    /// What fills a crop that reaches past the image (made from the image at the current geometry).
    var extendFill: ExtendFill?
    /// Seed for the fill, so redoing an edit reproduces the same fill; "Try Again" picks a new one.
    var extendSeed: UInt64?
    /// nil means `.match`. (Optional, like everything added later, so saved edits still decode.)
    var extendMethod: ExtendMethod? {
        didSet { if extendMethod != oldValue { extendFill = nil } }
    }
    /// What to generate in the new area; nil or empty lets the model continue the scene on its own.
    var extendPrompt: String? {
        didSet { if extendPrompt != oldValue { extendFill = nil } }
    }

    var effectiveExtendMethod: ExtendMethod { extendMethod ?? .match }

    /// Objects painted out (Remove Objects), in the order they were removed. Extend continues the result.
    var removals: [Removal]? {
        didSet { if removals != oldValue { extendFill = nil } }
    }

    // Light
    var autoEnhance = false
    var exposure: Double = 0            // EV, -2...2
    var brightness: Double = 0          // -1...1
    var contrast: Double = 0            // -1...1
    var highlights: Double = 0          // -1...1
    var shadows: Double = 0             // -1...1

    // Color
    var saturation: Double = 0          // -1...1
    var vibrance: Double = 0            // -1...1
    var temperature: Double = 0         // -1...1 (warm positive)
    var tint: Double = 0                // -1...1 (magenta positive)

    // Detail & effects
    var sharpness: Double = 0           // 0...1
    var noiseReduction: Double = 0      // 0...1
    var vignette: Double = 0            // 0...1

    var filter: FilterPreset = .none
    var filterIntensity: Double = 1

    var cutout: Cutout?
    /// Drawn behind a cutout; nil leaves the removed area transparent.
    var background: Backdrop?
    /// 0...1: how far the subject's light and color move toward a picture background (nil: off).
    var matchLighting: Double?

    static let identity = EditState()

    /// No edits that show: also when what's left can't change the picture (a slider within a hair of zero, an
    /// empty list of removals, a crop of the whole picture, Extend's settings with nothing extended, a filter's
    /// strength with no filter), so an image isn't "edited" with nothing to see or undo.
    var isIdentity: Bool { shown == .identity }

    /// These edits without what can't show (see `isIdentity`).
    var shown: EditState {
        var e = self
        for key in [\EditState.exposure, \.brightness, \.contrast, \.highlights, \.shadows, \.saturation, \.vibrance,
                    \.temperature, \.tint, \.sharpness, \.noiseReduction, \.vignette] where abs(e[keyPath: key]) < 0.005 {
            e[keyPath: key] = 0
        }
        if abs(e.straighten) < 0.05 { e.straighten = 0 }
        e.quarterTurns = ((e.quarterTurns % 4) + 4) % 4
        if let c = e.crop, abs(c.minX) < 0.0005, abs(c.minY) < 0.0005, abs(c.width - 1) < 0.0005, abs(c.height - 1) < 0.0005 { e.crop = nil }
        if e.removals?.isEmpty == true { e.removals = nil }
        if !e.cropExtendsBeyondImage {
            e.extendFill = nil
            e.extendSeed = nil
            e.extendMethod = nil
            e.extendPrompt = nil
        }
        if e.filter == .none { e.filterIntensity = 1 }
        return e
    }

    /// True when the result has see-through areas that the edits introduced.
    var hasTransparency: Bool {
        cutout != nil && background?.isOpaque != true
    }

    /// Removes the cutout along with whatever was drawn behind it.
    mutating func removeCutout() {
        cutout = nil
        background = nil
        matchLighting = nil
    }

    /// The crop reaches past the image's edges (Extend).
    var cropExtendsBeyondImage: Bool {
        guard let c = crop else { return false }
        return c.minX < -0.001 || c.minY < -0.001 || c.maxX > 1.001 || c.maxY > 1.001
    }

    /// The crop reaches past the image but no current fill covers it.
    var needsExtendFill: Bool {
        guard cropExtendsBeyondImage, let c = crop else { return false }
        guard let fill = extendFill, fill.covers(c) else { return true }
        return fill.isDraft == true
    }

    var hasGeometryChange: Bool {
        quarterTurns % 4 != 0 || flipHorizontal || flipVertical || straighten != 0 || crop != nil || perspective != nil
    }

    var hasAdjustments: Bool {
        var copy = self
        copy.quarterTurns = 0
        copy.flipHorizontal = false
        copy.flipVertical = false
        copy.straighten = 0
        copy.crop = nil
        copy.perspective = nil
        copy.extendFill = nil
        copy.extendSeed = nil
        copy.extendMethod = nil
        copy.extendPrompt = nil
        copy.removals = nil
        copy.removeCutout()
        return !copy.isIdentity
    }

    /// Rotates the visible image by 90°, carrying the crop rectangle along.
    mutating func rotate(clockwise: Bool) {
        quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
        extendFill = nil
        if let c = crop {
            crop = clockwise
                ? CGRect(x: 1 - c.maxY, y: c.minX, width: c.height, height: c.width)
                : CGRect(x: c.minY, y: 1 - c.maxX, width: c.height, height: c.width)
        }
    }

    /// Flips the visible image. Flips are applied before rotation in the pipeline, so a visual
    /// horizontal flip on a sideways image is a vertical flip of the source.
    mutating func flip(horizontal: Bool) {
        let sourceHorizontal = (quarterTurns % 2 == 0) == horizontal
        if sourceHorizontal { flipHorizontal.toggle() } else { flipVertical.toggle() }
        straighten = -straighten
        extendFill = nil
        if let c = crop {
            crop = horizontal
                ? CGRect(x: 1 - c.maxX, y: c.minY, width: c.width, height: c.height)
                : CGRect(x: c.minX, y: 1 - c.maxY, width: c.width, height: c.height)
        }
    }

    /// What belongs to this picture alone, as opposed to its adjustments (light, color, detail, the filter): its
    /// turn, crop and straightening, Extend, retouching, cutout and background.
    private var ownParts: (Int, Bool, Bool, Double, CGRect?, Quad?, Cutout?, Backdrop?, Double?, [Removal]?, UInt64?, ExtendMethod?,
                           String?, ExtendFill?) {
        get {
            (quarterTurns, flipHorizontal, flipVertical, straighten, crop, perspective, cutout, background, matchLighting,
             removals, extendSeed, extendMethod, extendPrompt, extendFill)
        }
        set {
            // The fill comes last: setting straighten or perspective clears it.
            (quarterTurns, flipHorizontal, flipVertical, straighten, crop, perspective, cutout, background, matchLighting,
             removals, extendSeed, extendMethod, extendPrompt, extendFill) = newValue
        }
    }

    mutating func resetAdjustments() {
        let own = ownParts
        self = EditState()
        ownParts = own
    }

    /// The adjustments alone, for Copy Edits.
    var adjustments: EditState {
        var e = self
        e.ownParts = EditState().ownParts
        return e
    }

    /// Paste Edits: `other`'s adjustments, this picture keeping its own parts.
    mutating func takeAdjustments(from other: EditState) {
        let own = ownParts
        self = other
        ownParts = own
    }

    mutating func resetGeometry() {
        quarterTurns = 0
        flipHorizontal = false
        flipVertical = false
        straighten = 0
        crop = nil
        perspective = nil
        extendFill = nil
        extendSeed = nil
        extendMethod = nil
        extendPrompt = nil
    }

    /// The pictures the edits use (an Extend fill, a background, removed objects' patches) are all on this Mac.
    var referencedFilesExist: Bool {
        var paths = (removals ?? []).map(\.path)
        if let fill = extendFill { paths.append(fill.path) }
        if case .image(let path) = background { paths.append(path) }
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    /// What an Extend fill is made from: everything up to the geometry stage, plus how it's filled. Equal
    /// keys give the same fill (for any crop the fill covers).
    var extendSourceKey: String {
        var g = self
        g.resetAdjustments()
        g.crop = nil
        g.extendFill = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(g)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
