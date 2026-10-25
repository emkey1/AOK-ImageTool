import SwiftUI

@main
struct ImageViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        LegacyMigration.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup(id: "viewer") {
            ViewerWindow()
        }
        .defaultSize(width: 1280, height: 840)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { ViewerCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SelfTest.isRequested {
            NSApp.setActivationPolicy(.prohibited)
            Task { await SelfTest.run() }
        } else if ExtendLab.isRequested {
            NSApp.setActivationPolicy(.prohibited)
            Task { await ExtendLab.run() }
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppStorageLocation.removeStaleIsolatedFolders()
        if let appearance = DebugHooks.appearance {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        // Another running copy may still need files its pending edits haven't recorded yet (or its undo
        // history uses), so only prune when this is the only one.
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        guard !AppStorageLocation.isIsolated else { return }
        Updater.shared.checkInBackgroundIfDue()
        guard copies.count <= 1 else { return }
        ModelDownloads.removeLeftovers()
        PhotosLibrary.removeOldWorkingFiles()
        Updater.removeLeftovers()
        // (Also what edits saved to Photos refer to.)
        let photos = PhotosLibrary.keptFiles
        BackdropStore.prune(keeping: PendingEdits.shared.backdropPaths.union(photos))
        ExtendFillStore.prune(keeping: PendingEdits.shared.extendFillPaths.union(photos))
        RemovalStore.prune(keeping: PendingEdits.shared.removalPaths.union(photos))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let viewers = ViewerRegistry.shared.all
        // (Two windows on one folder have the same edits.)
        let unsaved = Set(viewers.flatMap(\.unsavedURLs)).sorted { $0.path < $1.path }
        let count = unsaved.count
        guard count > 0, !Updater.isRelaunchingForUpdate else { return .terminateNow }
        let fromPhotos = unsaved.filter { PhotosLibrary.shared.photo(for: $0) != nil }.count
        // Edits to files are kept for next time, so the reminder can be turned off; edits to photos from Photos are
        // lost, so they're always asked about.
        if fromPhotos == 0, !Prefs.remindOfKeptEdits { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "You have unsaved edits to \(count) image\(count == 1 ? "" : "s")."
        let names = unsaved.prefix(4).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ") + (count > 4 ? ", and \(count - 4) more" : "")
        let what = fromPhotos == 0
            ? "They're kept, and come back the next time you open their folder."
            : fromPhotos == count
                ? "They're edits to photos from Photos, which are lost when you quit. Save them first (⌘S) to keep them in Photos."
                : "Edits to files come back the next time you open their folder; edits to photos from Photos are lost unless you save them first."
        alert.informativeText = names + ".\n\n" + what + " Show Them lists them, to save them (⌘S), or revert them (File ▸ Revert All Edited Images)."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Show Them")
        alert.addButton(withTitle: "Cancel")
        if fromPhotos == 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't remind me (Settings ▸ Editing turns it back on)"
        }
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { Prefs.setBool(false, PrefKey.remindOfKeptEdits) }
        switch response {
        case .alertFirstButtonReturn:
            return .terminateNow
        case .alertSecondButtonReturn:
            // The window with the most of them, showing just its edited images.
            if let viewer = viewers.max(by: { $0.unsavedURLs.count < $1.unsavedURLs.count }) {
                viewer.flagFilter = .edited
                viewer.viewMode = .grid
                viewer.window?.makeKeyAndOrderFront(nil)
            }
            return .terminateCancel
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PendingEdits.shared.flush()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

/// URLs chosen before a window existed to receive them (e.g. File ▸ Open with no windows open).
enum PendingOpen {
    static var urls: [URL] = []

    static func take() -> [URL] {
        defer { urls = [] }
        return urls
    }
}

extension FocusedValues {
    @Entry var viewer: ViewerModel?
}
