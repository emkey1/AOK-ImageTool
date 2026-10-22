import Foundation
import SwiftUI

/// UserDefaults keys shared by `@AppStorage` (Settings UI) and `Prefs` (model code).
nonisolated enum PrefKey {
    static let wrapAround = "wrapAround"
    static let upDownNavigates = "upDownNavigates"
    static let spaceAdvances = "spaceAdvances"
    static let includeSubfolders = "includeSubfolders"
    static let showHiddenFiles = "showHiddenFiles"
    static let canvasBackground = "canvasBackground"
    static let extendMethod = "extendMethod"
    static let checkerboard = "checkerboardForTransparency"
    static let upscaleSmallImages = "upscaleSmallImages"
    static let aiEnhanceEnlarged = "aiEnhanceEnlarged"
    static let pixelatedZoom = "pixelatedZoom"
    static let hdrEnabled = "hdrEnabled"
    static let liveTextEnabled = "liveTextEnabled"
    static let slideshowInterval = "slideshowInterval"
    static let advanceAfterFlag = "advanceAfterFlag"
    static let trashOriginalOnSave = "trashOriginalOnSave"
    static let confirmOverwrite = "confirmOverwrite"
    static let exportFormat = "exportFormat"
    static let exportQuality = "exportQuality"
    static let exportMetadata = "exportMetadata"
    static let gridThumbnailSize = "gridThumbnailSize"
    static let showFilmstrip = "showFilmstrip"
    static let showGridLabels = "showGridLabels"
    static let autoDescribe = "autoDescribe"
    static let recentFolders = "recentFolders"
    static let lastViewedFiles = "lastViewedFiles"
    static let sortKey = "sortKey"
    static let sortAscending = "sortAscending"
    static let stackCopies = "stackCopies"
    static let blackAndWhite = "blackAndWhite"
}

nonisolated enum CanvasBackground: String, CaseIterable, Identifiable {
    case black, dark, gray, light, white, window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: "Black"
        case .dark: "Dark Gray"
        case .gray: "Gray"
        case .light: "Light Gray"
        case .white: "White"
        case .window: "Match Window"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .black: .black
        case .dark: NSColor(white: 0.11, alpha: 1)
        case .gray: NSColor(white: 0.45, alpha: 1)
        case .light: NSColor(white: 0.85, alpha: 1)
        case .white: .white
        case .window: .windowBackgroundColor
        }
    }
}

/// Typed, thread-safe accessors for preferences used outside of SwiftUI views.
nonisolated enum Prefs {
    private static var d: UserDefaults { .standard }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? fallback
    }

    static var wrapAround: Bool { bool(PrefKey.wrapAround, true) }
    static var upDownNavigates: Bool { bool(PrefKey.upDownNavigates, true) }
    static var spaceAdvances: Bool { bool(PrefKey.spaceAdvances, true) }
    static var includeSubfolders: Bool { bool(PrefKey.includeSubfolders, false) }
    static var showHiddenFiles: Bool { bool(PrefKey.showHiddenFiles, false) }
    static var checkerboard: Bool { bool(PrefKey.checkerboard, true) }
    static var aiEnhanceEnlarged: Bool { bool(PrefKey.aiEnhanceEnlarged, false) }
    static var pixelatedZoom: Bool { bool(PrefKey.pixelatedZoom, false) }
    static var hdrEnabled: Bool { bool(PrefKey.hdrEnabled, true) }
    static var liveTextEnabled: Bool { bool(PrefKey.liveTextEnabled, true) }
    static var advanceAfterFlag: Bool { bool(PrefKey.advanceAfterFlag, true) }
    static var trashOriginalOnSave: Bool { bool(PrefKey.trashOriginalOnSave, true) }
    static var confirmOverwrite: Bool { bool(PrefKey.confirmOverwrite, true) }
    static var showFilmstrip: Bool { bool(PrefKey.showFilmstrip, true) }
    static var autoDescribe: Bool { bool(PrefKey.autoDescribe, false) }
    static var stackCopies: Bool { bool(PrefKey.stackCopies, true) }

    static var canvasBackground: CanvasBackground {
        CanvasBackground(rawValue: d.string(forKey: PrefKey.canvasBackground) ?? "") ?? .dark
    }

    static var slideshowInterval: Double {
        let v = d.double(forKey: PrefKey.slideshowInterval)
        return v > 0 ? v : 4
    }

    static var exportQuality: Double {
        let v = d.double(forKey: PrefKey.exportQuality)
        return v > 0 ? v : 0.88
    }

    static func setBool(_ value: Bool, _ key: String) { set(value, key) }

    /// How Extend fills a new frame: the last one chosen, else Generate when its model is installed.
    static var preferredExtendMethod: ExtendMethod {
        let chosen = d.string(forKey: PrefKey.extendMethod).flatMap(ExtendMethod.init(rawValue:))
        let method = chosen ?? (GenerativeModel.isInstalled ? .generate : .match)
        return method == .generate && !GenerativeModel.isInstalled ? .match : method
    }

    /// Saves a preference, except in debug-hook runs (screenshots, `-debugExtend`), which share the
    /// user's preferences domain and must leave it as it was. (The self-test saves and restores.)
    static func set(_ value: Any?, _ key: String) {
        guard !DebugHooks.isActive else { return }
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
    }
}

/// Recently opened folders, most recent first.
enum RecentFolders {
    static let maxCount = 12

    static var all: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: PrefKey.recentFolders) ?? []
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: PrefKey.recentFolders) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        Prefs.set(Array(paths.prefix(maxCount)), PrefKey.recentFolders)
    }

    static func clear() {
        Prefs.set(nil, PrefKey.recentFolders)
    }
}

/// Remembers the last image viewed in each folder so reopening a folder resumes there.
enum LastViewed {
    static func file(in folder: URL) -> URL? {
        let map = UserDefaults.standard.dictionary(forKey: PrefKey.lastViewedFiles) as? [String: String] ?? [:]
        guard let name = map[folder.standardizedFileURL.path] else { return nil }
        return folder.appendingPathComponent(name)
    }

    static func remember(_ file: URL, in folder: URL) {
        var map = UserDefaults.standard.dictionary(forKey: PrefKey.lastViewedFiles) as? [String: String] ?? [:]
        let rel = file.path.hasPrefix(folder.path + "/") ? String(file.path.dropFirst(folder.path.count + 1)) : file.lastPathComponent
        map[folder.standardizedFileURL.path] = rel
        if map.count > 300 { map.removeAll() }
        Prefs.set(map, PrefKey.lastViewedFiles)
    }
}

/// Where the app keeps files that outlive a launch (pending edits, background pictures, Extend fills).
/// Self-tests get a private temporary folder so they never touch the user's data.
nonisolated enum AppStorageLocation {
    static let isIsolated: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-selfTest") || args.contains("-extendTest") || DebugHooks.isActive
    }()

    private static let isolatedPrefix = "ImageViewerSelfTestSupport-"

    static let support: URL = {
        if isIsolated {
            return FileManager.default.temporaryDirectory.appendingPathComponent(isolatedPrefix + "\(ProcessInfo.processInfo.processIdentifier)")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ImageViewer")
    }()

    /// Installed models: the real Application Support folder, even for isolated test runs and test copies
    /// with another bundle ID, since they're large, only read, and shared by every build.
    static var models: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["AOK_MODELS_DIR"] { return URL(fileURLWithPath: override) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(LegacyMigration.newID).appendingPathComponent("Models")
    }

    /// Deletes isolated (test run) storage whose process has quit.
    static func removeStaleIsolatedFolders() {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix(isolatedPrefix) {
            guard let pid = Int32(name.dropFirst(isolatedPrefix.count)), pid != ProcessInfo.processInfo.processIdentifier,
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }
}

/// Debug-only launch switches for looking at UI states without driving the app.
nonisolated enum DebugHooks {
    /// `-debugExtend`: open the first image straight into the Crop tool, extending to 16:9.
    static let extendOnLaunch: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-debugExtend")
        #else
        false
        #endif
    }()
    /// With `-debugExtend`, `-debugGenerate` also switches the fill to Generate.
    static let generateOnLaunch: Bool = extendOnLaunch && ProcessInfo.processInfo.arguments.contains("-debugGenerate")
    /// `-debugScene viewer|grid|adjust|intelligence|background`: puts the first window in that state, for
    /// the Guide's screenshots. `-debugAppearance light|dark` and `-debugWindowSize 1280x800` go with it.
    static let scene: String? = value(after: "-debugScene")
    static let appearance: String? = value(after: "-debugAppearance")
    static let windowSize: CGSize? = value(after: "-debugWindowSize").flatMap { text in
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
    /// Any debug hook: such runs use isolated storage and don't save preferences.
    static let isActive: Bool = extendOnLaunch || scene != nil || ProcessInfo.processInfo.arguments.contains("-extendTest")

    private static func value(after flag: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }
}
