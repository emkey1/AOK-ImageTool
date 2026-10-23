import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ViewerModel {
    /// The files an action applies to: the grid selection when several are selected, else the current image.
    var actionTargets: [URL] {
        if viewMode == .grid, selection.count > 1 {
            return items.lazy.filter { self.selection.contains($0.url) }.map(\.url)
        }
        return currentURL.map { [$0] } ?? []
    }

    // MARK: - Trash

    func trashSelection() {
        moveToTrash(actionTargets)
    }

    /// A photo from Photos (Edit With) belongs to Photos: renaming, moving or trashing its file there would
    /// break the edit. Says so, and returns true, if any of `urls` is one.
    func refuseForPhotos(_ urls: [URL]) -> Bool {
        guard urls.contains(where: PhotosRoundTrip.isFromPhotos) else { return false }
        alert = AlertInfo(title: "This photo belongs to Photos",
                          message: "Rename, move or delete it in Photos. Here you can edit it and Save, which sends the edit back to Photos.")
        return true
    }

    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty, !refuseForPhotos(urls) else { return }
        var moved: [(original: URL, trashed: URL)] = []
        for url in urls {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let trashed = result as URL? { moved.append((url, trashed)) }
            } catch {
                showError("Couldn't move “\(url.lastPathComponent)” to the Trash", error)
            }
        }
        guard !moved.isEmpty else { return }
        removeItems(Set(moved.map(\.original)))
        undoManager?.registerUndo(withTarget: self) { model in
            model.restoreFromTrash(moved)
        }
        undoManager?.setActionName("Move to Trash")
        let text = moved.count == 1 ? "Moved “\(moved[0].original.lastPathComponent)” to Trash" : "Moved \(moved.count) images to Trash"
        showToast(text, systemImage: "trash", actionTitle: "Undo") { [weak self] in
            self?.undoManager?.undo()
        }
    }

    private func restoreFromTrash(_ moved: [(original: URL, trashed: URL)]) {
        var restored: [URL] = []
        for pair in moved {
            do {
                try FileManager.default.moveItem(at: pair.trashed, to: pair.original)
                restored.append(pair.original)
                if let item = FolderScanner.item(for: pair.original) {
                    insertItem(item, select: pair.original == moved.first?.original)
                }
            } catch {
                showError("Couldn't restore “\(pair.original.lastPathComponent)”", error)
            }
        }
        undoManager?.registerUndo(withTarget: self) { model in
            model.moveToTrash(restored)
        }
        undoManager?.setActionName("Move to Trash")
    }

    /// Culling helper: trash every image flagged as a reject in this folder.
    func trashRejects() {
        let rejects = allItems.filter { $0.flag == .reject }.map(\.url)
        guard !rejects.isEmpty else {
            showToast("No rejected images", systemImage: "xmark.circle")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move \(rejects.count) rejected image\(rejects.count == 1 ? "" : "s") to the Trash?"
        alert.informativeText = "You can put them back from the Trash or with Undo."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.moveToTrash(rejects) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handler) } else { handler(alert.runModal()) }
    }

    /// Targets for a context menu on `url`: the whole selection if `url` is part of it, else just `url`.
    func contextTargets(for url: URL) -> [URL] {
        if selection.contains(url), selection.count > 1 {
            return items.lazy.filter { self.selection.contains($0.url) }.map(\.url)
        }
        return [url]
    }

    /// Finder-style click handling in the grid (⌘ toggles, ⇧ extends).
    func gridClick(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        if modifiers.contains(.command) {
            if selection.contains(url), selection.count > 1 {
                selection.remove(url)
            } else {
                let keep = selection
                show(index: index)
                selection = keep.union([url])
            }
        } else if modifiers.contains(.shift), let anchor = (gridAnchor ?? currentIndex).map({ min($0, items.count - 1) }) {
            let range = min(anchor, index)...max(anchor, index)
            show(index: index)
            gridAnchor = anchor
            selection = Set(range.map { items[$0].url })
        } else {
            show(index: index)
        }
    }

    // MARK: - Folder navigation

    func openEnclosingFolder() {
        guard let folder = folderURL else { return }
        let parent = folder.deletingLastPathComponent()
        guard parent != folder else { return }
        openFolder(parent, selecting: nil)
    }

    /// Jumps to the next/previous sibling folder that contains something — handy for date-named photo folders.
    func openSiblingFolder(_ delta: Int) {
        guard let folder = folderURL else { return }
        let parent = folder.deletingLastPathComponent()
        let siblings = ((try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? [])
            .filter {
                let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return v?.isDirectory == true && v?.isPackage != true
            }
            .map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let i = siblings.firstIndex(of: folder) else { return }
        let j = i + delta
        guard siblings.indices.contains(j) else {
            NSSound.beep()
            return
        }
        openFolder(siblings[j], selecting: LastViewed.file(in: siblings[j]))
        showToast(siblings[j].lastPathComponent, systemImage: "folder")
    }

    // MARK: - Flags (Finder color labels)

    func setFlag(_ flag: Flag, for explicitTargets: [URL]? = nil) {
        let urls = explicitTargets ?? actionTargets
        guard !urls.isEmpty else { return }
        for url in urls {
            var values = URLResourceValues()
            values.labelNumber = flag.rawValue
            var u = url
            do {
                try u.setResourceValues(values)
                updateItem(url) { $0.flag = flag }
            } catch {
                showError("Couldn't flag “\(url.lastPathComponent)”", error)
                return
            }
        }
        let name = switch flag {
        case .pick: "Picked"
        case .reject: "Rejected"
        case .none: "Unflagged"
        }
        let icon = switch flag {
        case .pick: "flag.fill"
        case .reject: "xmark.circle.fill"
        case .none: "flag.slash"
        }
        showToast(urls.count == 1 ? name : "\(name) \(urls.count) images", systemImage: icon)
        if flagFilter != .all {
            applySortAndFilter()
        } else if Prefs.advanceAfterFlag, viewMode == .viewer, urls.count == 1, flag != .none {
            step(1, wrap: false)
        }
    }

    // MARK: - Rename / move / copy

    func beginRename() {
        guard let item = currentItem, !refuseForPhotos([item.url]) else { return }
        renameTarget = item
    }

    @discardableResult
    func rename(_ item: ImageItem, to newStem: String) -> Bool {
        guard !refuseForPhotos([item.url]) else { return false }
        let stem = newStem.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !stem.isEmpty else { return false }
        let ext = item.url.pathExtension
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(ext)
        guard dest != item.url else { return true }
        // (A change of case only is the same file on a case-insensitive volume.)
        if FileManager.default.fileExists(atPath: dest.path), dest.path.lowercased() != item.url.path.lowercased() {
            alert = AlertInfo(title: "A file named “\(dest.lastPathComponent)” already exists.", message: "Choose a different name.")
            return false
        }
        do {
            if dest.path.lowercased() == item.url.path.lowercased() {
                // A change of case only: by way of another name, since to the volume it's the same file.
                let step = dest.deletingLastPathComponent().appendingPathComponent(".renaming-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: item.url, to: step)
                try FileManager.default.moveItem(at: step, to: dest)
            } else {
                try FileManager.default.moveItem(at: item.url, to: dest)
            }
            let newURL = dest.standardizedFileURL
            relinkCopies(of: item.url, to: newURL)
            if let fresh = FolderScanner.item(for: dest) {
                replaceURL(item.url, with: fresh)
                intelligence.rename(from: item.url, to: fresh.url)
            }
            undoManager?.registerUndo(withTarget: self) { model in
                if let current = model.allItems.first(where: { $0.url == newURL }) {
                    model.rename(current, to: item.url.deletingPathExtension().lastPathComponent)
                }
            }
            undoManager?.setActionName("Rename")
            return true
        } catch {
            showError("Couldn't rename “\(item.name)”", error)
            return false
        }
    }

    func moveOrCopySelection(copy: Bool) {
        let urls = actionTargets
        guard !urls.isEmpty, copy || !refuseForPhotos(urls) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = copy ? "Copy" : "Move"
        panel.message = copy ? "Copy \(urls.count) image(s) to…" : "Move \(urls.count) image(s) to…"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let dest = panel.url, let self else { return }
            var done: [URL] = []
            for url in urls {
                let target = ImageWriter.uniqueURL(in: dest, baseName: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
                do {
                    if copy { try FileManager.default.copyItem(at: url, to: target) } else { try FileManager.default.moveItem(at: url, to: target) }
                    done.append(url)
                } catch {
                    self.showError("Couldn't \(copy ? "copy" : "move") “\(url.lastPathComponent)”", error)
                }
            }
            if !copy { self.removeItems(Set(done)) }
            self.showToast("\(copy ? "Copied" : "Moved") \(done.count) image\(done.count == 1 ? "" : "s") to \(dest.lastPathComponent)",
                           systemImage: copy ? "doc.on.doc" : "folder", actionTitle: "Show") {
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    // MARK: - Pasteboard

    func copyImage() {
        if viewMode == .viewer, let text = canvas?.selectedLiveText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        if viewMode == .grid || actionTargets.count > 1 {
            let urls = actionTargets
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
            showToast("Copied \(urls.count) file\(urls.count == 1 ? "" : "s")", systemImage: "doc.on.doc")
            return
        }
        guard let d = decoded, let url = currentURL else { return }
        let e = currentEdits
        Task {
            let image: CGImage? = e.isIdentity ? d.cgImage : await EditRenderer.shared.render(d, edits: e, maxDimension: nil)?.image
            guard let image else { return }
            let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            NSPasteboard.general.clearContents()
            if e.isIdentity {
                NSPasteboard.general.writeObjects([ns, url as NSURL])
            } else {
                NSPasteboard.general.writeObjects([ns])
            }
            showToast("Copied image", systemImage: "doc.on.doc")
        }
    }

    func copyPath() {
        let paths = actionTargets.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
        showToast("Copied path", systemImage: "link")
    }

    // MARK: - Paste

    /// Whether the clipboard holds a picture, or image files, to paste.
    static func clipboardHasImage(_ pb: NSPasteboard = .general) -> Bool {
        pb.canReadObject(forClasses: [NSImage.self], options: nil) || !clipboardImageFiles(pb).isEmpty
    }

    nonisolated private static func clipboardImageFiles(_ pb: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: SupportedFormats.readableTypes.map(\.identifier),
        ]
        return (pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// Edit ▸ Paste as New Image (⌘V with the image or grid in focus): a picture on the clipboard becomes a new
    /// file in this folder ("Pasted Image <date>"), kept as it was copied when it's a JPEG or HEIC and as PNG
    /// otherwise; image files copied in Finder are copied in. With no folder open, or a photo from Photos
    /// showing, they go to Pictures and open there.
    func pasteImage(from pb: NSPasteboard = .general) {
        let fm = FileManager.default
        let here = folderURL.flatMap { folder -> URL? in
            guard !PhotosRoundTrip.isFromPhotos(folder.appendingPathComponent("x")), fm.isWritableFile(atPath: folder.path) else { return nil }
            return folder
        }
        let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let destination = here ?? pictures
        var made: [URL] = []
        do {
            let files = Self.clipboardImageFiles(pb)
            if !files.isEmpty {
                for file in files {
                    let dest = ImageWriter.uniqueURL(in: destination, baseName: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension)
                    try fm.copyItem(at: file, to: dest)
                    made.append(dest)
                }
            } else {
                let stamp = DateFormatter()
                stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let name = "Pasted Image \(stamp.string(from: Date()))"
                if let (data, ext) = [(NSPasteboard.PasteboardType(UTType.heic.identifier), "heic"),
                                      (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg")]
                    .lazy.compactMap({ type, ext in pb.data(forType: type).map { ($0, ext) } }).first {
                    let dest = ImageWriter.uniqueURL(in: destination, baseName: name, ext: ext)
                    try data.write(to: dest)
                    made.append(dest)
                } else if let image = NSImage(pasteboard: pb), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let dest = ImageWriter.uniqueURL(in: destination, baseName: name, ext: "png")
                    try ImageWriter.write(cg, to: dest, format: .png, quality: 1, sourceProperties: [:], metadata: .removeAll)
                    made.append(dest)
                }
            }
        } catch {
            return showError("Couldn't paste the image", error)
        }
        guard let first = made.first else {
            return showToast("There's no picture on the clipboard", systemImage: "doc.on.clipboard")
        }
        if here != nil {
            for url in made { if let item = FolderScanner.item(for: url) { insertItem(item, select: url == first) } }
        } else {
            open(made.count == 1 ? [first] : made)
        }
        showToast(made.count == 1 ? "Pasted as “\(first.lastPathComponent)”" : "Pasted \(made.count) images",
                  systemImage: "doc.on.clipboard")
    }

    // MARK: - System integration

    func revealInFinder() {
        let urls = actionTargets
        if urls.isEmpty, let folderURL {
            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func applicationsForCurrent() -> [URL] {
        guard let url = currentURL else { return [] }
        let me = Bundle.main.bundleURL
        return NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0 != me }
    }

    func open(with appURL: URL) {
        let urls = actionTargets
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    func setAsDesktopPicture() {
        guard let url = currentURL else { return }
        do {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
            showToast("Set as desktop picture", systemImage: "menubar.dock.rectangle")
        } catch {
            showError("Couldn't set the desktop picture", error)
        }
    }

    func printImage() {
        guard let d = decoded else { return }
        let e = currentEdits
        Task {
            let image: CGImage? = e.isIdentity ? d.cgImage : await EditRenderer.shared.render(d, edits: e, maxDimension: nil)?.image
            guard let image else { return }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.isHorizontallyCentered = true
            info.isVerticallyCentered = true
            info.orientation = image.width > image.height ? .landscape : .portrait
            let page = info.imageablePageBounds.size
            let scale = min(page.width / CGFloat(image.width), page.height / CGFloat(image.height), 1)
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
            view.image = NSImage(cgImage: image, size: view.frame.size)
            view.imageScaling = .scaleProportionallyUpOrDown
            let op = NSPrintOperation(view: view, printInfo: info)
            op.jobTitle = currentItem?.name ?? "Image"
            if let window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
        }
    }

    // MARK: - Context menu (canvas right-click)

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        guard currentItem != nil else {
            menu.addItem(ClosureMenuItem("Open…") { [weak self] in self?.showOpenPanel() })
            return menu
        }
        menu.addItem(ClosureMenuItem("Copy Image", image: "doc.on.doc") { [weak self] in self?.copyImage() })
        menu.addItem(ClosureMenuItem("Copy Subject", image: "person.crop.rectangle") { [weak self] in self?.intelligence.copySubject() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rotate Left", image: "rotate.left") { [weak self] in self?.rotate(clockwise: false) })
        menu.addItem(ClosureMenuItem("Rotate Right", image: "rotate.right") { [weak self] in self?.rotate(clockwise: true) })
        menu.addItem(ClosureMenuItem("Crop…", image: "crop") { [weak self] in self?.activeTool = .crop })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Pick", image: "flag") { [weak self] in self?.setFlag(.pick) })
        menu.addItem(ClosureMenuItem("Reject", image: "xmark.circle") { [weak self] in self?.setFlag(.reject) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show in Finder", image: "folder") { [weak self] in self?.revealInFinder() })
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        let sub = NSMenu()
        for app in applicationsForCurrent().prefix(12) {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: app.path)) { [weak self] in self?.open(with: app) }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            sub.addItem(item)
        }
        openWith.submenu = sub
        menu.addItem(openWith)
        menu.addItem(ClosureMenuItem("Set as Desktop Picture", image: "menubar.dock.rectangle") { [weak self] in self?.setAsDesktopPicture() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Move to Trash", image: "trash") { [weak self] in self?.trashSelection() })
        return menu
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let image { self.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}
