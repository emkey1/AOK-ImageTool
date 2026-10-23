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
        BackdropStore.prune(keeping: PendingEdits.shared.backdropPaths)
        ExtendFillStore.prune(keeping: PendingEdits.shared.extendFillPaths)
        RemovalStore.prune(keeping: PendingEdits.shared.removalPaths)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = ViewerRegistry.shared.all.flatMap(\.unsavedURLs)
        let count = unsaved.count
        guard count > 0, !Updater.isRelaunchingForUpdate else { return .terminateNow }
        let fromPhotos = unsaved.filter { PhotosLibrary.shared.photo(for: $0) != nil }.count
        let alert = NSAlert()
        alert.messageText = "You have unsaved edits to \(count) image\(count == 1 ? "" : "s")."
        alert.informativeText = fromPhotos == 0
            ? "They're kept, and come back the next time you open their folder."
            : fromPhotos == count
                ? "They're edits to photos from Photos, which are lost when you quit. Save them first (⌘S) to keep them in Photos."
                : "Edits to files come back the next time you open their folder; edits to photos from Photos are lost unless you save them first."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
