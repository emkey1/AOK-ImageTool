import CoreImage
import Foundation
import ImageIO
import SwiftUI

/// A selected object's own light, color and detail: the Adjust panel's sliders for it, laid over the whole
/// picture's through its selection (a soft-edged mask), so the rest of the picture stays as it was.
nonisolated struct LocalAdjustment: Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    /// The selection: a grayscale picture kept by `SelectionStore` (white = adjusted), over the image as decoded
    /// (upright, before other edits), so it turns and crops with the picture. Any size: it's stretched over it.
    var mask: String

    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0
    var noiseReduction: Double = 0

    /// The Adjust panel's sliders that an object has its own of (the rest are the whole picture's).
    nonisolated(unsafe) static let keys: [WritableKeyPath<EditState, Double>] = [
        \.exposure, \.brightness, \.contrast, \.highlights, \.shadows, \.saturation, \.vibrance, \.temperature, \.tint,
        \.sharpness, \.noiseReduction,
    ]

    init(id: UUID = UUID(), mask: String) {
        self.id = id
        self.mask = mask
    }

    /// These values as edits of a picture (everything else as it was), to render with and to set by the sliders'
    /// key paths.
    var edits: EditState {
        get {
            var e = EditState()
            e.exposure = exposure
            e.brightness = brightness
            e.contrast = contrast
            e.highlights = highlights
            e.shadows = shadows
            e.saturation = saturation
            e.vibrance = vibrance
            e.temperature = temperature
            e.tint = tint
            e.sharpness = sharpness
            e.noiseReduction = noiseReduction
            return e
        }
        set {
            exposure = newValue.exposure
            brightness = newValue.brightness
            contrast = newValue.contrast
            highlights = newValue.highlights
            shadows = newValue.shadows
            saturation = newValue.saturation
            vibrance = newValue.vibrance
            temperature = newValue.temperature
            tint = newValue.tint
            sharpness = newValue.sharpness
            noiseReduction = newValue.noiseReduction
        }
    }

    /// Without what can't show (a slider within a hair of zero), as `EditState.shown`.
    var shown: LocalAdjustment {
        var a = self
        a.edits = edits.shown
        return a
    }

    /// Nothing changed (yet).
    var isEmpty: Bool { edits.isIdentity }

    // Every value is optional when read, so edits saved by a later version, with more of them, still open.
    private enum CodingKeys: String, CodingKey {
        case id, mask, exposure, brightness, contrast, highlights, shadows, saturation, vibrance, temperature, tint,
             sharpness, noiseReduction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mask = try c.decode(String.self, forKey: .mask)
        func value(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        exposure = try value(.exposure)
        brightness = try value(.brightness)
        contrast = try value(.contrast)
        highlights = try value(.highlights)
        shadows = try value(.shadows)
        saturation = try value(.saturation)
        vibrance = try value(.vibrance)
        temperature = try value(.temperature)
        tint = try value(.tint)
        sharpness = try value(.sharpness)
        noiseReduction = try value(.noiseReduction)
    }
}

/// An object the Adjust panel adjusts on its own: `id` in `url`'s `localAdjustments`, selected by `mask` (it may
/// have no adjustments there yet).
struct AdjustTarget: Equatable {
    let url: URL
    let id: UUID
    let mask: String
}

extension ViewerModel {
    /// The object the Adjust panel's sliders change, when it's of the picture showing (nil: the whole picture).
    var currentAdjustTarget: AdjustTarget? {
        guard let t = adjustTarget, t.url == currentURL else { return nil }
        return t
    }

    /// The objects the Adjust panel can adjust on their own, in the order they were selected: those with
    /// adjustments, and the one just selected (which has none yet).
    var adjustableObjects: [AdjustTarget] {
        guard let url = currentURL else { return [] }
        var list = (currentEdits.localAdjustments ?? []).map { AdjustTarget(url: url, id: $0.id, mask: $0.mask) }
        if let t = currentAdjustTarget, !list.contains(where: { $0.id == t.id }) { list.append(t) }
        return list
    }

    /// Adjusts the object selected by `mask` (on the image's own pixels) on its own from now on.
    func adjustSelection(_ mask: CIImage, of url: URL, size: CGSize) throws {
        let path = try SelectionStore.save(mask, size: size)
        adjustTarget = AdjustTarget(url: url, id: UUID(), mask: path)
        inspectorTab = .adjust
        showInspector = true
    }

    /// Takes the object's own adjustments away, and goes back to adjusting the whole picture.
    func removeObjectAdjustments(_ target: AdjustTarget) {
        updateEdits("Remove Object Adjustments", of: target.url) { $0.removeLocalAdjustment(target.id) }
        if adjustTarget?.id == target.id { adjustTarget = nil }
    }
}

nonisolated extension EditState {
    /// The selected object `id`'s value for the slider `key` (0 when it has none yet).
    func localValue(_ key: WritableKeyPath<EditState, Double>, of id: UUID) -> Double {
        localAdjustments?.first { $0.id == id }?.edits[keyPath: key] ?? 0
    }

    /// Sets the selected object `id`'s value for the slider `key`, adding the object (selected by `mask`) if it
    /// has no adjustments yet.
    mutating func setLocalValue(_ key: WritableKeyPath<EditState, Double>, _ value: Double, of id: UUID, mask: String) {
        var list = localAdjustments ?? []
        if let i = list.firstIndex(where: { $0.id == id }) {
            list[i].edits[keyPath: key] = value
        } else {
            var a = LocalAdjustment(id: id, mask: mask)
            a.edits[keyPath: key] = value
            list.append(a)
        }
        localAdjustments = list
    }

    /// Takes the selected object `id`'s adjustments away.
    mutating func removeLocalAdjustment(_ id: UUID) {
        localAdjustments?.removeAll { $0.id == id }
        if localAdjustments?.isEmpty == true { localAdjustments = nil }
    }
}

/// Selections whose objects are adjusted on their own (`LocalAdjustment.mask`), kept in Application Support so
/// the edit keeps working across relaunches (with pending edits).
nonisolated enum SelectionStore {
    /// Selections are kept at most this big (on the long side): their edges are soft anyway.
    static let maxSide: CGFloat = 2048

    static var directory: URL {
        AppStorageLocation.support.appendingPathComponent("Selections")
    }

    /// Keeps `mask` (white = selected, on the image's own pixels, `size` big) and returns its path.
    static func save(_ mask: CIImage, size: CGSize) throws -> String {
        let s = min(1, maxSide / max(size.width, size.height, 1))
        let w = max(1, Int((size.width * s).rounded())), h = max(1, Int((size.height * s).rounded()))
        let ext = mask.extent
        guard ext.width > 0, ext.height > 0 else { throw ImageWriteError.finalizeFailed }
        // Stretched over the picture by its extent, as a mask is.
        let fitted = mask
            .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / ext.width, y: CGFloat(h) / ext.height))
        let bytes = EditRenderer.shared.context.renderGray(fitted, bounds: CGRect(x: 0, y: 0, width: w, height: h))
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let gray = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ImageWriteError.finalizeFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try ImageWriter.writeAsIs(gray, to: url, format: .png, quality: 1)
        return url.path
    }

    /// A kept selection as a mask, its values as they were kept (not taken for gray levels).
    static func load(_ path: String) -> CIImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }

    /// Deletes selections nothing refers to any more (at launch, when only pending edits can).
    static func prune(keeping paths: Set<String>) {
        let keep = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
