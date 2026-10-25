import AppKit

/// The windows open when the app quit, reopened at the next launch (Settings ▸ General ▸ "Reopen windows
/// from last time"). macOS reopens windows itself only after Quit and Keep Windows (⌥⌘Q), a restart, or with
/// "Close windows when quitting an application" off; when it has, this stays out of the way.
enum WindowSession {
    struct Window {
        var place: WindowPlace
        var frame: NSRect?
    }

    private static var launchHandled = false
    /// Launched to open files (from Finder, or dropped on the Dock icon): those, not last time's windows.
    static var launchedToOpenFiles = false

    /// Remembers the open windows, front to back (at quit).
    static func save() {
        guard !DebugHooks.isActive else { return }
        let ordered = NSApp.orderedWindows
        let viewers = ViewerRegistry.shared.all.compactMap { m in m.window.map { (m, $0) } }
            .sorted { a, b in (ordered.firstIndex { $0 === a.1 } ?? .max) < (ordered.firstIndex { $0 === b.1 } ?? .max) }
        let saved: [[String: String]] = viewers.compactMap { model, window in
            guard let place = model.place else { return nil }
            var entry = ["folder": place.folder, "frame": NSStringFromRect(window.frame)]
            entry["image"] = place.image
            entry["files"] = place.files
            return entry
        }
        Prefs.set(saved.isEmpty ? nil : saved, PrefKey.openWindows)
    }

    /// Last time's windows, for the launch's first window (none for later ones, or with the setting off).
    static func takeAtLaunch() -> [Window] {
        guard !launchHandled else { return [] }
        launchHandled = true
        guard Prefs.reopenWindows, !DebugHooks.isActive else { return [] }
        let saved = UserDefaults.standard.array(forKey: PrefKey.openWindows) as? [[String: String]] ?? []
        return saved.compactMap { entry in
            guard let folder = entry["folder"] else { return nil }
            let frame = entry["frame"].map(NSRectFromString).flatMap { f in
                NSScreen.screens.contains { $0.visibleFrame.intersects(f) } && f.width > 200 ? f : nil
            }
            return Window(place: WindowPlace(folder: folder, image: entry["image"], files: entry["files"]), frame: frame)
        }
    }
}
