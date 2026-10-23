import AppKit
import WebKit

/// The user guide (Help/guide.html), in its own window. Its search field searches only the guide, unlike
/// the system Help menu's search, which mixes in menu items and unrelated results.
final class GuideWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    static let shared = GuideWindowController()

    /// Sections of guide.html that the app links to.
    enum Section: String {
        case top = "", start, viewing, culling, stacks, search, editing, extend, remove, cutouts, intelligence, files, photos, settings, keys, macos, model, updates, privacy
    }

    private let webView = WKWebView()
    private static let searchID = NSToolbarItem.Identifier("guideSearch")

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(Self.appName) Guide"
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName(DebugHooks.isActive ? "" : "Guide")
        super.init(window: window)
        window.contentView = webView
        let toolbar = NSToolbar(identifier: "Guide")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AOK-ImageTool"
    }

    static var guideURL: URL? { Bundle.main.url(forResource: "guide", withExtension: "html") }

    func show(_ section: Section = .top) {
        guard let url = Self.guideURL else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = section.rawValue.isEmpty ? nil : section.rawValue
        if webView.url?.path == url.path {
            let target = section.rawValue.isEmpty ? "window.scrollTo(0, 0)" : "document.getElementById('\(section.rawValue)')?.scrollIntoView()"
            webView.evaluateJavaScript(target)
        } else {
            webView.loadFileURL(components.url!, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Toolbar search: finds within the guide only

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.searchID] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.searchID] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.searchID else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: id)
        item.searchField.placeholderString = "Search the Guide"
        item.searchField.delegate = self
        item.searchField.target = self
        item.searchField.action = #selector(searchChanged(_:))
        item.preferredWidthForSearchField = 240
        return item
    }

    @objc private func searchChanged(_ field: NSSearchField) { find(field.stringValue, backwards: false) }

    /// Return finds the next match, Shift-Return the previous one.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let field = control as? NSSearchField else { return false }
        find(field.stringValue, backwards: NSEvent.modifierFlags.contains(.shift))
        return true
    }

    private func find(_ text: String, backwards: Bool) {
        guard !text.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(text, configuration: config) { result in
            if !result.matchFound { NSSound.beep() }
        }
    }
}
