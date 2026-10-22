import AppKit

/// Single-key shortcuts. Handled with a window-scoped event monitor (not menu key equivalents) so
/// arrow keys and letters never steal input from text fields such as search or rename.
extension ViewerModel {
    struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    static let shortcutGroups: [(title: String, items: [Shortcut])] = [
        ("Browse", [
            Shortcut(keys: "← →", action: "Previous / next image"),
            Shortcut(keys: "↑ ↓", action: "Previous / next image (configurable)"),
            Shortcut(keys: "Space  ⇧Space", action: "Next / previous image"),
            Shortcut(keys: "Home  End", action: "First / last image"),
            Shortcut(keys: "Page Up / Down", action: "Previous / next page"),
            Shortcut(keys: "Swipe  ·  Scroll wheel", action: "Previous / next (when image fits)"),
            Shortcut(keys: "G  ·  Return", action: "Toggle grid / open image"),
        ]),
        ("Zoom", [
            Shortcut(keys: "Z  ·  Double-click", action: "Toggle fit / actual size"),
            Shortcut(keys: "+  −", action: "Zoom in / out"),
            Shortcut(keys: "0  ·  1", action: "Fit / 100%"),
            Shortcut(keys: "⌘ or ⌥ + Scroll  ·  Pinch", action: "Zoom at pointer"),
            Shortcut(keys: "L", action: "Lock zoom & position across images"),
        ]),
        ("Cull", [
            Shortcut(keys: "P", action: "Pick (green label)"),
            Shortcut(keys: "X", action: "Reject (red label)"),
            Shortcut(keys: "U", action: "Unflag"),
            Shortcut(keys: "⌘⌫", action: "Move to Trash (undoable)"),
        ]),
        ("Edit", [
            Shortcut(keys: "R  ·  ⇧R", action: "Rotate right / left"),
            Shortcut(keys: "C", action: "Crop & straighten"),
            Shortcut(keys: "\\", action: "Show original (before / after)"),
            Shortcut(keys: "⌘S  ·  ⇧⌘E", action: "Save / Export"),
        ]),
        ("View", [
            Shortcut(keys: "F", action: "Full screen"),
            Shortcut(keys: "S", action: "Slideshow (Space pauses)"),
            Shortcut(keys: "I  ·  E  ·  A", action: "Info / Adjust / Intelligence panel"),
            Shortcut(keys: "T", action: "Show / hide filmstrip"),
            Shortcut(keys: "Esc", action: "Exit tool, slideshow or full screen"),
            Shortcut(keys: "?", action: "This help"),
        ]),
    ]

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private var isTextEditing: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSText || responder is NSTextView
    }

    /// Gives keyboard focus back to the image so single-key shortcuts work.
    func focusCanvas() {
        if viewMode == .viewer, let doc = canvas?.documentView {
            window?.makeFirstResponder(doc)
        } else {
            window?.makeFirstResponder(nil)
        }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        if isTextEditing {
            // Esc in an empty text field hands focus back to the image.
            if event.keyCode == 53, (window.firstResponder as? NSTextView)?.string.isEmpty == true {
                focusCanvas()
                return true
            }
            return false
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)

        // Tools (crop, object selection) own Return / Escape.
        if activeTool != nil {
            switch event.keyCode {
            case 53: // Esc
                NotificationCenter.default.post(name: .toolCancel, object: self)
                return true
            case 36, 76: // Return, Enter
                NotificationCenter.default.post(name: .toolCommit, object: self)
                return true
            default:
                return false
            }
        }

        let isGrid = viewMode == .grid
        switch event.specialKey {
        case .leftArrow?:
            isGrid ? moveGridSelection(by: -1, extend: shift) : previous()
            return true
        case .rightArrow?:
            isGrid ? moveGridSelection(by: 1, extend: shift) : next()
            return true
        case .upArrow?:
            if isGrid { moveGridSelection(by: -gridColumns, extend: shift) } else if Prefs.upDownNavigates { previous() } else { zoomIn() }
            return true
        case .downArrow?:
            if isGrid { moveGridSelection(by: gridColumns, extend: shift) } else if Prefs.upDownNavigates { next() } else { zoomOut() }
            return true
        case .home?:
            first()
            return true
        case .end?:
            last()
            return true
        case .pageUp?:
            pageCount > 1 ? previousPage() : previous()
            return true
        case .pageDown?:
            pageCount > 1 ? nextPage() : next()
            return true
        case .carriageReturn?, .enter?:
            if isGrid, currentItem != nil {
                viewMode = .viewer
                return true
            }
            return false
        default:
            break
        }

        if event.keyCode == 53 { // Escape
            if isSlideshowRunning { stopSlideshow() } else if showOriginal { showOriginal = false } else if isFullScreen { toggleFullScreen() } else if !searchText.isEmpty { searchText = "" } else { return false }
            return true
        }

        guard let chars = event.charactersIgnoringModifiers, let ch = chars.first else { return false }
        switch ch {
        case " ":
            if isSlideshowRunning { toggleSlideshowPause() } else if isGrid { viewMode = .viewer } else if Prefs.spaceAdvances { shift ? previous() : next() } else { return false }
        case "f", "F": toggleFullScreen()
        case "g", "G": toggleViewMode()
        case "t", "T": showFilmstrip.toggle()
        case "s", "S": toggleSlideshow()
        case "i", "I": toggleInspector(.info)
        case "e", "E": toggleInspector(.adjust)
        case "a", "A": toggleInspector(.intelligence)
        case "p", "P": setFlag(.pick)
        case "x", "X": setFlag(.reject)
        case "u", "U": setFlag(.none)
        case "r": rotate(clockwise: true)
        case "R": rotate(clockwise: false)
        case "]": rotate(clockwise: true)
        case "[": rotate(clockwise: false)
        case "c", "C":
            guard canEdit else { return false }
            viewMode = .viewer
            activeTool = .crop
        case "\\": if !currentEdits.isIdentity { showOriginal.toggle() }
        case "z", "Z": toggleFitActual()
        case "+", "=": zoomIn()
        case "-", "_": zoomOut()
        case "0": zoomToFit()
        case "1": zoomToActualSize()
        case "l", "L":
            lockZoom.toggle()
            showToast(lockZoom ? "Zoom locked across images" : "Zoom unlocked", systemImage: lockZoom ? "lock" : "lock.open")
        case "?", "/": showShortcuts = true
        default:
            return false
        }
        return true
    }

    func moveGridSelection(by delta: Int, extend: Bool) {
        guard !items.isEmpty else { return }
        let current = currentIndex ?? 0
        let target = min(max(current + delta, 0), items.count - 1)
        guard target != current || currentIndex == nil else { return }
        if extend {
            let anchor = gridAnchor ?? current
            let range = min(anchor, target)...max(anchor, target)
            let keepAnchor = anchor
            show(index: target)
            gridAnchor = keepAnchor
            selection = Set(range.map { items[$0].url })
        } else {
            show(index: target)
        }
    }
}

extension Notification.Name {
    static let toolCommit = Notification.Name("ImageViewer.toolCommit")
    static let toolCancel = Notification.Name("ImageViewer.toolCancel")
}
