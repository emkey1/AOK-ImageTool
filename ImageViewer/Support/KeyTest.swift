#if DEBUG
import AppKit

/// `-debugKeys <folder>` (Debug builds): presses the window's keyboard shortcuts as if they were typed, through
/// the event queue (so the key monitor and the menus get them as they would a real key), checks what each did,
/// writes the report and pictures of the toolbar to the folder, and quits. It brings its window forward, so
/// it's for a test machine (the macOS 15 VM), and the picture it opens should be a copy: the rating keys write
/// to the file.
@MainActor
enum KeyTest {
    private static var started = false
    private static var lines: [String] = []
    private static var failures = 0

    static func start(_ model: ViewerModel) {
        guard let out = DebugHooks.keyTestFolder, !started else { return }
        started = true
        Task {
            await run(model, out: URL(fileURLWithPath: out))
            let passed = lines.filter { $0.hasPrefix("PASS") }.count
            let report = lines.joined(separator: "\n") + "\nKEYTEST \(passed) passed, \(failures) failed\n"
            try? report.write(to: URL(fileURLWithPath: out).appendingPathComponent("keytest.txt"), atomically: true, encoding: .utf8)
            print(report)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ ok: Bool, _ message: String) {
        lines.append((ok ? "PASS  " : "FAIL  ") + message)
        if !ok { failures += 1 }
    }

    private enum Key {
        static let r: UInt16 = 15, l: UInt16 = 37, m: UInt16 = 46, s: UInt16 = 1, g: UInt16 = 5
        static let zero: UInt16 = 29, three: UInt16 = 20, rightBracket: UInt16 = 30, leftBracket: UInt16 = 33
        static let returnKey: UInt16 = 36, down: UInt16 = 125, option: UInt16 = 58
    }

    /// SwiftUI brings its menu items up to date (which window they act on, what's enabled) when the menu is
    /// about to be searched for a typed key; a posted key event doesn't get that, so it's done here first.
    private static func refreshMenus() {
        func refresh(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            menu.items.compactMap(\.submenu).forEach(refresh)
        }
        NSApp.mainMenu.map(refresh)
    }

    /// One key, pressed and let go (or only one of them), the way the keyboard sends it.
    private static func press(_ model: ViewerModel, _ ignoring: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [],
                              typed: String? = nil, down: Bool = true, up: Bool = true) async {
        guard let window = model.window else { return }
        refreshMenus()
        try? await Task.sleep(for: .milliseconds(200))
        var types: [NSEvent.EventType] = []
        if down { types.append(.keyDown) }
        if up { types.append(.keyUp) }
        for type in types {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: typed ?? ignoring, charactersIgnoringModifiers: ignoring,
                                            isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// A menu shortcut as the window server would deliver it: a keyboard event posted to this process, so it
    /// has the system event behind it that SwiftUI's menus go by.
    private static func type(_ code: UInt16, _ flags: CGEventFlags) async {
        refreshMenus()
        var received = 0
        let counter = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == code { received += 1 }
            return event
        }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.postToPid(getpid())
            try? await Task.sleep(for: .milliseconds(150))
        }
        try? await Task.sleep(for: .milliseconds(300))
        if received == 0 {
            // Not delivered (posting to a process can need Accessibility): the same event through the app's queue.
            for down in [true, false] {
                guard let cg = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
                cg.flags = flags
                if let event = NSEvent(cgEvent: cg) { NSApp.postEvent(event, atStart: false) }
                try? await Task.sleep(for: .milliseconds(150))
            }
            lines.append("      key \(code): posted to the process didn't arrive; through the queue: \(received) key down")
        } else {
            lines.append("      key \(code): posted to the process, \(received) key down arrived")
        }
        counter.map(NSEvent.removeMonitor)
        try? await Task.sleep(for: .milliseconds(600))
    }

    private static func option(_ model: ViewerModel, held: Bool) async {
        guard let window = model.window,
              let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: held ? .option : [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                           keyCode: Key.option) else { return }
        NSApp.postEvent(event, atStart: false)
        try? await Task.sleep(for: .milliseconds(800))
    }

    /// The window with its toolbar, as a PNG.
    private static func snapshot(_ model: ViewerModel, to url: URL) {
        guard let frame = model.window?.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func run(_ model: ViewerModel, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        // Menu shortcuts go to the frontmost window only (they find its model through SwiftUI's focus), so
        // wait until this one is (a click on it does it, if macOS keeps a launch from ssh in the background).
        for _ in 0..<60 where !(NSApp.isActive && model.window?.isKeyWindow == true) {
            NSApp.activate(ignoringOtherApps: true)
            model.window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
        }
        model.focusCanvas()
        try? await Task.sleep(for: .seconds(1))
        check(NSApp.isActive && model.window?.isKeyWindow == true, "the window is in front (active \(NSApp.isActive))")
        guard model.currentItem != nil, model.canEdit else {
            check(false, "a picture that can be edited is open (\(String(describing: model.currentURL)))")
            return
        }
        func turns() -> Int { model.currentEdits.quarterTurns }
        let start = turns()

        // Rotating, as in Photos.
        await type(Key.r, .maskCommand)
        check(turns() == (start + 3) % 4, "⌘R rotates left (\(start) → \(turns()))")
        await type(Key.r, [.maskCommand, .maskAlternate])
        check(turns() == start, "⌥⌘R rotates right (back to \(turns()))")
        await type(Key.l, .maskCommand)
        check(turns() == start, "⌘L no longer rotates (\(turns()))")
        await press(model, "r", Key.r)
        check(turns() == (start + 1) % 4, "R still rotates right (\(turns()))")
        await press(model, "R", Key.r, .shift)
        check(turns() == start, "⇧R still rotates left (\(turns()))")

        // The menus: no two items with the same keys, and the new ones where they should be.
        var seen: [String: String] = [:]
        var clashes: [String] = []
        var found: [String: String] = [:]
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub, path + item.title + " › ") }
                // (macOS's own Dictation and Emoji items come in hidden pairs.)
                guard !item.keyEquivalent.isEmpty, !item.isHidden,
                      !["Start Dictation…", "Emoji & Symbols"].contains(item.title) else { continue }
                var mask = item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                let key = item.keyEquivalent
                if key != key.lowercased() { mask.insert(.shift) }
                let id = "\(key.lowercased().unicodeScalars.map { String($0.value, radix: 16) }.joined())-\(mask.rawValue)"
                if let other = seen[id], !item.isAlternate { clashes.append("\(other) and \(path + item.title)") }
                seen[id] = path + item.title
                found[item.title] = id
                if item.title == "Rotate Left" { lines.append("      Rotate Left is \(item.isEnabled ? "enabled" : "disabled")") }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, "") }
        func id(_ key: String, _ mask: NSEvent.ModifierFlags) -> String {
            "\(key.unicodeScalars.map { String($0.value, radix: 16) }.joined())-\(mask.rawValue)"
        }
        check(clashes.isEmpty, "no two menu items have the same keys (\(clashes))")
        check(found["Rotate Left"] == id("r", .command), "Rotate Left is ⌘R in the Image menu")
        check(found["Rotate Right"] == id("r", [.command, .option]), "Rotate Right is ⌥⌘R in the Image menu")
        check(found["Rename…"] == id("\r", .option), "Rename… is ⌥↩ in the File menu")
        check(found["Import from Photos…"] == id("i", [.command, .shift]), "Import from Photos… is ⇧⌘I in the File menu")
        lines.append("      \(seen.count) menu shortcuts: " + seen.values.sorted().joined(separator: "; "))

        // Stars, as in Photos.
        func rating() -> Double { model.currentItem?.rating ?? -1 }
        await press(model, "3", Key.three, .option, typed: "£")
        check(rating() == 3, "⌥3 rates three stars (\(rating()))")
        await press(model, "]", Key.rightBracket, .option, typed: "‘")
        check(rating() == 4, "⌥] adds a star (\(rating()))")
        await press(model, "[", Key.leftBracket, .option, typed: "“")
        check(rating() == 3, "⌥[ takes one away (\(rating()))")
        await press(model, "0", Key.zero, .option, typed: "º")
        check(rating() == 0, "⌥0 takes the rating off (\(rating()))")

        // Thumbnails.
        let strip = model.showFilmstrip
        await press(model, "s", Key.s, .option, typed: "ß")
        check(model.showFilmstrip == !strip, "⌥S shows or hides the filmstrip")
        await press(model, "s", Key.s, .option, typed: "ß")
        check(model.showFilmstrip == strip, "⌥S again puts it back")

        // The original while M is held.
        await type(Key.r, .maskCommand)
        await press(model, "m", Key.m, up: false)
        check(model.showOriginal, "holding M shows the original")
        await press(model, "m", Key.m, down: false)
        check(!model.showOriginal, "letting go of M shows the edits again")
        await type(Key.r, [.maskCommand, .maskAlternate])
        await press(model, "m", Key.m, up: false)
        check(!model.showOriginal, "M does nothing on a picture without edits")
        await press(model, "m", Key.m, down: false)

        // Rename, and not while typing.
        await type(Key.returnKey, .maskAlternate)
        check(model.renameTarget != nil, "⌥↩ starts Rename")
        model.renameTarget = nil
        try? await Task.sleep(for: .milliseconds(800))
        func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for sub in view.subviews { if let field = searchField(in: sub) { return field } }
            return nil
        }
        if let window = model.window, let frame = window.contentView?.superview, let field = searchField(in: frame) {
            window.makeFirstResponder(field)
            try? await Task.sleep(for: .milliseconds(400))
            await type(Key.returnKey, .maskAlternate)
            check(model.renameTarget == nil, "⌥↩ while typing in the search field doesn't start Rename")
            model.renameTarget = nil
            model.searchText = ""
            model.focusCanvas()
            try? await Task.sleep(for: .milliseconds(400))
        } else {
            lines.append("SKIP  ⌥↩ in the search field: no search field found")
        }

        // ⌘↓ opens the picture selected in the grid.
        await press(model, "g", Key.g)
        check(model.viewMode == .grid, "G shows the grid")
        await press(model, String(UnicodeScalar(NSDownArrowFunctionKey)!), Key.down, [.command, .numericPad, .function])
        check(model.viewMode == .viewer, "⌘↓ opens the selected picture")

        // Option held turns the toolbar's Rotate button.
        snapshot(model, to: out.appendingPathComponent("toolbar.png"))
        await option(model, held: true)
        check(model.optionKeyDown, "holding Option is noticed")
        snapshot(model, to: out.appendingPathComponent("toolbar-option.png"))
        await option(model, held: false)
        check(!model.optionKeyDown, "letting go of Option is noticed")
        check(turns() == start, "the picture ends as it began (\(turns()))")
    }
}
#endif
