import AppKit
import Foundation
import Observation

/// A look the user saved: a picture's adjustments (light, color, white balance, detail, vignette, the filter and
/// Auto), put on other pictures with a click, as Paste Edits would. Never a picture's own parts (its crop, turn,
/// retouching, cutout or objects adjusted on their own), which fit only that picture.
nonisolated struct AdjustmentPreset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// The adjustments alone, as they show (`EditState.adjustments.shown`).
    var edits: EditState

    init(id: UUID = UUID(), name: String, edits: EditState) {
        self.id = id
        self.name = name
        self.edits = edits.adjustments.shown
    }

    /// `e`'s adjustments are this preset's.
    func matches(_ e: EditState) -> Bool { e.adjustments.shown == edits }
}

/// The saved presets, shared by every window, kept in "Presets.json" in Application Support (a private
/// temporary folder for test runs: `AppStorageLocation`).
@Observable
final class PresetStore {
    static let shared = PresetStore()

    private(set) var presets: [AdjustmentPreset] = []
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = AppStorageLocation.support.appendingPathComponent("Presets.json")) {
        self.fileURL = fileURL
        load()
    }

    /// The preset called `name` (ignoring case and spaces around it), other than `except`.
    func preset(named name: String, except: UUID? = nil) -> AdjustmentPreset? {
        let wanted = Self.clean(name)
        return presets.first { $0.id != except && $0.name.compare(wanted, options: [.caseInsensitive]) == .orderedSame }
    }

    /// Saves `edits`' adjustments as `name`: a new preset at the end, or in place of one already called that.
    @discardableResult
    func save(_ name: String, edits: EditState) -> AdjustmentPreset {
        let name = Self.clean(name)
        if let i = presets.firstIndex(where: { $0.id == preset(named: name)?.id }) {
            presets[i] = AdjustmentPreset(id: presets[i].id, name: name, edits: edits)
            write()
            return presets[i]
        }
        let preset = AdjustmentPreset(name: name, edits: edits)
        presets.append(preset)
        write()
        return preset
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = Self.clean(name)
        write()
    }

    /// The preset becomes `edits`' adjustments (keeping its name and place).
    func update(_ id: UUID, edits: EditState) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].edits = edits.adjustments.shown
        write()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        write()
    }

    static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let saved = try? JSONDecoder().decode([AdjustmentPreset].self, from: data) {
            presets = saved
        } else {
            // A file this version can't read is put aside rather than written over by the next save.
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("Presets (unreadable \(Int(Date().timeIntervalSince1970))).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Couldn't save presets: \(error.localizedDescription)")
        }
    }
}

/// Naming a preset: saving the current picture's adjustments as one, or renaming one.
struct PresetNaming: Identifiable {
    enum Kind {
        case save(EditState)
        case rename(AdjustmentPreset)
    }

    let id = UUID()
    let kind: Kind
}

extension ViewerModel {
    /// Image ▸ Save as Preset… (or the Adjust panel's): asks for a name for the current picture's adjustments.
    func beginSavingPreset() {
        guard canEdit else { return }
        let adjustments = currentEdits.adjustments.shown
        guard !adjustments.isIdentity else {
            return showToast("No adjustments to save: change the light, color or filter first", systemImage: "slider.horizontal.3")
        }
        presetNaming = PresetNaming(kind: .save(adjustments))
    }

    /// Puts `preset`'s adjustments on the selected pictures (or `targets`), replacing theirs, as Paste Edits does:
    /// each keeps its own crop, turn, retouching and objects adjusted on their own. One step to undo.
    func applyPreset(_ preset: AdjustmentPreset, to targets: [URL]? = nil) {
        guard objectSession == nil else { return }
        let urls = targets ?? actionTargets
        guard !urls.isEmpty else { return }
        let changed = putAdjustments(preset.edits, on: urls, undoName: "Preset “\(preset.name)”")
        if changed == 0 {
            showToast(urls.count == 1 ? "It already has this preset" : "They already have this preset", systemImage: "checkmark.circle")
        } else if urls.count > 1 {
            showToast("Applied “\(preset.name)” to \(changed) image\(changed == 1 ? "" : "s")", systemImage: "camera.filters")
        }
    }

    /// `adjustments` on `urls` in place of theirs, as one undo step; how many changed.
    @discardableResult
    func putAdjustments(_ adjustments: EditState, on urls: [URL], undoName: String) -> Int {
        let urls = urls.filter { !savingURLs.contains($0) }
        guard !urls.isEmpty else { return 0 }
        undoManager?.beginUndoGrouping()
        var changed = 0
        for url in urls {
            let old = edits[url] ?? .identity
            var new = old
            new.takeAdjustments(from: adjustments)
            guard new.shown != old.shown else { continue }
            applyEdits(new, to: url, undoName: undoName, previous: old)
            changed += 1
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(undoName)
        return changed
    }
}
