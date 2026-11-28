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

/// An object Adjust Objects adjusts: `id` in `url`'s `localAdjustments`, selected by `mask` (it may have no
/// adjustments there yet).
struct AdjustTarget: Equatable {
    let url: URL
    let id: UUID
    let mask: String
}

/// Adjust Objects in progress on `url`, like Remove Objects: `working` is the picture's edits with the objects'
/// adjustments so far, shown as they're made (`currentEdits`), while its edits stay as they were. Done saves a
/// copy with them (or, with its copies off, makes them an edit of the picture); Cancel drops them. `undo` and
/// `redo` are its own steps (⌘Z).
struct ObjectSession {
    let url: URL
    var working: EditState
    var undo: [EditState] = []
    var redo: [EditState] = []
}

extension ViewerModel {
    /// Adjust Objects is open on the picture showing (its bar over the picture, the Adjust panel's sliders on
    /// the object).
    var isAdjustingObjects: Bool {
        activeTool == .adjustObjects && objectSession != nil && objectSession?.url == currentURL
    }

    /// The object the Adjust panel's sliders change (nil: the whole picture).
    var currentAdjustTarget: AdjustTarget? {
        guard let t = adjustTarget, t.url == currentURL, objectSession?.url == t.url else { return nil }
        return t
    }

    /// The objects Adjust Objects has, in the order they were selected: those with adjustments, and the one just
    /// selected (which has none yet).
    var adjustableObjects: [AdjustTarget] {
        guard let url = currentURL else { return [] }
        var list = (currentEdits.localAdjustments ?? []).map { AdjustTarget(url: url, id: $0.id, mask: $0.mask) }
        if let t = currentAdjustTarget, !list.contains(where: { $0.id == t.id }) { list.append(t) }
        return list
    }

    /// Adjust Objects…: on the objects the picture already has adjusted on their own, or selecting one first.
    func beginAdjustingObjects() {
        guard let url = currentURL, canEdit else { return }
        viewMode = .viewer
        objectSession = ObjectSession(url: url, working: currentEdits)
        inspectorTab = .adjust
        showInspector = true
        if let first = currentEdits.localAdjustments?.first {
            adjustTarget = AdjustTarget(url: url, id: first.id, mask: first.mask)
            activeTool = .adjustObjects
        } else {
            adjustTarget = nil
            activeTool = .selectToAdjust
        }
    }

    /// Adjust in Select Object: the selection (`mask`, on the image's own pixels, `size` big) is the object
    /// adjusted from now on, in Adjust Objects (begun here if it isn't open).
    func adjustSelection(_ mask: CIImage, of url: URL, size: CGSize) throws {
        let path = try SelectionStore.save(mask, size: size)
        if objectSession?.url != url { objectSession = ObjectSession(url: url, working: edits[url] ?? .identity) }
        adjustTarget = AdjustTarget(url: url, id: UUID(), mask: path)
        inspectorTab = .adjust
        showInspector = true
        activeTool = .adjustObjects
    }

    /// Edit Selection… in Adjust Objects: Select Object opens on `target`'s selection, to add what it missed or
    /// take away what it shouldn't have.
    func editSelection(of target: AdjustTarget) {
        guard objectSession?.url == target.url, target.url == currentURL else { return }
        selectionEdit = target
        activeTool = .selectToAdjust
    }

    /// Done there: `mask` (on the image's own pixels, `size` big) is `target`'s selection from now on, its
    /// adjustments as they were (one of Adjust Objects' steps, when it has some).
    func replaceSelection(of target: AdjustTarget, with mask: CIImage, size: CGSize) throws {
        let path = try SelectionStore.save(mask, size: size)
        if currentEdits.localAdjustments?.contains(where: { $0.id == target.id }) == true {
            changeObjects { $0.setLocalMask(path, of: target.id) }
        }
        adjustTarget = AdjustTarget(url: target.url, id: target.id, mask: path)
        inspectorTab = .adjust
        showInspector = true
        activeTool = .adjustObjects
    }

    /// Cancel in Select Object, in Adjust Objects: back to the objects there are, or out if there are none.
    func cancelSelectingToAdjust() {
        guard objectSession != nil, let url = currentURL else { return activeTool = nil }
        if currentAdjustTarget == nil, let first = currentEdits.localAdjustments?.first {
            adjustTarget = AdjustTarget(url: url, id: first.id, mask: first.mask)
        }
        if currentAdjustTarget != nil { activeTool = .adjustObjects } else { cancelAdjustingObjects() }
    }

    /// A change in Adjust Objects, as one of its steps: `change` made now, or (after a slider drag) what changed
    /// since `before`.
    func changeObjects(from before: EditState? = nil, _ change: ((inout EditState) -> Void)? = nil) {
        guard objectSession != nil else { return }
        let previous = before ?? currentEdits
        if let change { previewEdits(change) }
        guard currentEdits != previous else { return }
        objectSession?.undo.append(previous)
        objectSession?.redo.removeAll()
    }

    func undoObjectChange() {
        guard let s = objectSession, let previous = s.undo.last else { return NSSound.beep() }
        objectSession?.undo.removeLast()
        objectSession?.redo.append(s.working)
        objectSession?.working = previous
        if s.url == currentURL { refreshDisplay() }
        keepTargetValid()
    }

    func redoObjectChange() {
        guard let s = objectSession, let next = s.redo.last else { return NSSound.beep() }
        objectSession?.redo.removeLast()
        objectSession?.undo.append(s.working)
        objectSession?.working = next
        if s.url == currentURL { refreshDisplay() }
        keepTargetValid()
    }

    /// The trash button: the object's adjustments taken away (another object adjusted instead, or selecting one).
    func removeObjectFromSession(_ target: AdjustTarget) {
        changeObjects { $0.removeLocalAdjustment(target.id) }
        adjustTarget = nil
        keepTargetValid()
        if currentAdjustTarget == nil { activeTool = .selectToAdjust }
    }

    /// (With none being adjusted, the first there is. One whose adjustments a step took away can still be
    /// adjusted: its selection is kept. And one whose selection a step changed, or changed back, is adjusted
    /// through the selection it has now.)
    private func keepTargetValid() {
        guard let url = currentURL else { return }
        if let t = adjustTarget, t.url == url {
            if let now = currentEdits.localAdjustments?.first(where: { $0.id == t.id }), now.mask != t.mask {
                adjustTarget = AdjustTarget(url: url, id: t.id, mask: now.mask)
            }
            return
        }
        guard adjustTarget == nil, let first = currentEdits.localAdjustments?.first else { return }
        adjustTarget = AdjustTarget(url: url, id: first.id, mask: first.mask)
    }

    /// Done in Adjust Objects: a copy, "<name> (Adjusted)", stacked on the original (which stays as it was), or,
    /// with its copies turned off, the adjustments made an edit of the picture (one step to undo).
    func finishAdjustingObjects() {
        guard let s = objectSession else { return activeTool = nil }
        let before = edits[s.url] ?? .identity
        guard s.working.shown.localAdjustments != before.shown.localAdjustments else { return cancelAdjustingObjects() }
        if extendIsPending(for: s.url) {
            return showToast("Extend is still filling in the new area — try again in a moment", systemImage: "hourglass")
        }
        guard let d = decoded, d.url == s.url else { return }
        leaveObjectSession()
        activeTool = nil
        if Prefs.makesCopy(.adjustObjects) {
            saveCopy(of: s.url, decoded: d, edits: s.working, label: "Adjusted", undoName: "Adjust Objects", defaultFormat: .heic, working: "Saving the adjusted copy…",
                     systemImage: "person.crop.rectangle", failure: "Couldn't save an adjusted copy of “\(s.url.lastPathComponent)”") { $0 }
        } else {
            applyEdits(s.working, to: s.url, undoName: "Adjust Objects", previous: before)
        }
    }

    /// Cancel in Adjust Objects: the picture as it was before.
    func cancelAdjustingObjects() {
        leaveObjectSession()
        activeTool = nil
    }

    /// Ends Adjust Objects, its adjustments dropped (whatever the open tool is now): the picture shows as its edits
    /// have it.
    func leaveObjectSession() {
        guard let s = objectSession else { return }
        objectSession = nil
        adjustTarget = nil
        if s.url == currentURL { refreshDisplay() }
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

    /// Gives the selected object `id` another selection (`mask`), its adjustments as they were.
    mutating func setLocalMask(_ mask: String, of id: UUID) {
        guard let i = localAdjustments?.firstIndex(where: { $0.id == id }) else { return }
        localAdjustments?[i].mask = mask
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

    /// Where an object's cutout (`Cutout.object`) is kept, so it's still cut out after a relaunch.
    static func cutoutURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("cutout-" + id.uuidString).appendingPathExtension("png")
    }

    /// Keeps `mask` (white = selected, on the image's own pixels, `size` big) and returns its path.
    static func save(_ mask: CIImage, size: CGSize) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try write(mask, size: size, to: url)
        return url.path
    }

    /// `mask` as a grayscale PNG at `url`, at most `maxSide` on its long side.
    static func write(_ mask: CIImage, size: CGSize, to url: URL) throws {
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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ImageWriter.writeAsIs(gray, to: url, format: .png, quality: 1)
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
