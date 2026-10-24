import AppKit
import ObjectiveC

/// Window states for the Guide's screenshots (`-debugScene`, Debug builds; see DebugHooks). Each run
/// opens one image and puts its window in one state; nothing is saved.
enum DebugScenes {
    private static var applied = false

    /// When the window appears: a fixed size, and no saved frame (the user's stays as it was).
    static func prepare(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        if scene != nil || DebugHooks.windowSize != nil { drawAsFrontmost(window) }
        if let size = DebugHooks.windowSize {
            window.setContentSize(size)
            window.center()
        }
    }

    private static var scene: String? { DebugHooks.scene }
    private static var swizzled = false

    /// Screenshot runs stay in the background, so they never take the focus from whoever is using the Mac;
    /// their windows draw as if they were frontmost instead.
    private static func drawAsFrontmost(_ window: NSWindow) {
        if !swizzled {
            swizzled = true
            let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
            for (cls, sel): (AnyClass, Selector) in [(NSWindow.self, #selector(getter: NSWindow.isKeyWindow)),
                               (NSWindow.self, #selector(getter: NSWindow.isMainWindow)),
                               (NSApplication.self, #selector(getter: NSApplication.isActive))] {
                if let method = class_getInstanceMethod(cls, sel) { method_setImplementation(method, imp_implementationWithBlock(yes)) }
            }
        }
        announceActive(window)
        // Again once SwiftUI has built the window's contents and toolbar.
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { announceActive(window) }
        }
    }

    private static func announceActive(_ window: NSWindow) {
        let nc = NotificationCenter.default
        nc.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        nc.post(name: NSWindow.didBecomeMainNotification, object: window)
        nc.post(name: NSWindow.didBecomeKeyNotification, object: window)
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.needsLayout = true
            view.subviews.forEach(redraw)
        }
        if let frame = window.contentView?.superview { redraw(frame) }
        window.displayIfNeeded()
    }

    /// Once the first image is on screen.
    static func apply(to model: ViewerModel) {
        guard let scene = DebugHooks.scene, !applied else { return }
        applied = true
        // The picture has the keyboard, as when the app is used (not the search field, which the window would
        // otherwise give it when the shot brings it forward).
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { model.focusCanvas() }
        }
        switch scene {
        case "grid":
            model.gridThumbnailSize = 200
            model.viewMode = .grid
        case "newimage":
            model.newImageDescription = "a lighthouse on a rocky coast at sunset"
            model.showNewImage = true
        case "adjust":
            model.updateEdits("Adjust") {
                $0.exposure = 0.2
                $0.contrast = 0.15
                $0.vibrance = 0.35
                $0.temperature = 0.12
            }
            model.inspectorTab = .adjust
            model.showInspector = true
        case "intelligence":
            model.inspectorTab = .intelligence
            model.showInspector = true
            model.intelligence.describeCurrent()
        case "info":
            model.inspectorTab = .info
            model.showInspector = true
        case "stack-open":
            Task {
                // The folder is still being scanned when the first image appears.
                for _ in 0..<100 where model.isScanning || model.stacks.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                if let root = model.stacks.keys.sorted(by: { $0.path < $1.path }).first { model.toggleStack(root) }
            }
        default:
            break
        }
    }

    static var showsSidebar: Bool { DebugHooks.scene == "viewer" || DebugHooks.scene == "grid" }
}
