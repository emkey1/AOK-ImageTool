import AppKit
import ObjectiveC

/// Lets a viewer stop its window from closing while it has unsaved edits. SwiftUI recognizes its
/// windows by their delegate, so rather than replacing the delegate, this wraps the delegate class's
/// `windowShouldClose:` (once per class) to ask the window's viewer before SwiftUI's own handling.
enum WindowCloseInterception {
    private static var wrappedClasses: Set<ObjectIdentifier> = []

    static func install(for window: NSWindow) {
        guard let delegate = window.delegate else { return }
        let cls: AnyClass = object_getClass(delegate) ?? type(of: delegate)
        guard wrappedClasses.insert(ObjectIdentifier(cls)).inserted else { return }

        typealias ShouldClose = @convention(c) (AnyObject, Selector, NSWindow) -> Bool
        let selector = #selector(NSWindowDelegate.windowShouldClose(_:))
        let inherited = class_getInstanceMethod(cls, selector)
        let types = inherited.flatMap { method_getTypeEncoding($0) }
            ?? protocol_getMethodDescription(NSWindowDelegate.self, selector, false, true).types.map { UnsafePointer($0) }
        // SwiftUI's own (or an inherited) implementation, called once the viewer agrees to close.
        let original = inherited.map { unsafeBitCast(method_getImplementation($0), to: ShouldClose.self) }
        let wrapper: @convention(block) (AnyObject, NSWindow) -> Bool = { object, window in
            let allowed = MainActor.assumeIsolated {
                ViewerRegistry.shared.all.first { $0.window === window }?.windowShouldClose(window) ?? true
            }
            return allowed && (original?(object, selector, window) ?? true)
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(wrapper), types)
        if inherited == nil {
            // The window looks up which delegate methods exist when the delegate is assigned.
            window.delegate = nil
            window.delegate = delegate
        }
    }
}

extension ViewerModel {
    /// The close button (or any other `performClose`) asks what to do with unsaved edits first.
    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard !isSavingBeforeClose else { return false }
        guard hasUnsavedEdits else { return true }
        guard window.attachedSheet == nil else { return false }

        let urls = unsavedURLs
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Do you want to save the changes to “\(urls[0].lastPathComponent)”?"
            : "Do you want to save the changes to \(urls.count) images?"
        let saving = switch (urls.count == 1, Prefs.trashOriginalOnSave) {
        case (true, true): "Saving replaces the file and moves the original to the Trash."
        case (false, true): "Saving replaces the files and moves the originals to the Trash."
        case (true, false): "Saving replaces the original file."
        case (false, false): "Saving replaces the original files."
        }
        let toPhotos = urls.allSatisfy { PhotosLibrary.shared.photo(for: $0) != nil }
        alert.informativeText = (toPhotos ? "Saving sends the edits to Photos." : saving) + " If you discard, your changes are lost."
        alert.addButton(withTitle: urls.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.saveAllAndClose()
            case .alertThirdButtonReturn: self?.discardAllAndClose()
            default: break
            }
        }
        return false
    }

    private func saveAllAndClose() {
        isSavingBeforeClose = true
        let count = unsavedURLs.count
        showToast(count == 1 ? "Saving…" : "Saving \(count) images…", systemImage: "arrow.down.doc")
        Task {
            let failures = await saveAllEdits()
            isSavingBeforeClose = false
            if failures.isEmpty {
                window?.performClose(nil)
            } else {
                dismissToast()
                let one = failures.count == 1
                alert = AlertInfo(title: one ? "An image couldn't be saved" : "\(failures.count) images couldn't be saved",
                                  message: failures.joined(separator: "\n")
                                      + "\n\nExport \(one ? "it" : "them") instead, or close the window again and choose Discard.")
            }
        }
    }

    private func discardAllAndClose() {
        for url in Array(edits.keys) { setEditsDictionary(url, nil) }
        undoManager?.removeAllActions(withTarget: self)
        window?.isDocumentEdited = false
        // Let the sheet finish ending before closing its window.
        Task { window?.performClose(nil) }
    }
}
