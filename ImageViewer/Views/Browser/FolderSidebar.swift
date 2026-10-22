import SwiftUI

struct FolderSidebar: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var subfolders: [URL] = []

    private var locations: [(String, String, URL)] {
        let fm = FileManager.default
        var result: [(String, String, URL)] = []
        for (name, icon, dir) in [("Pictures", "photo", FileManager.SearchPathDirectory.picturesDirectory),
                                  ("Desktop", "menubar.dock.rectangle", .desktopDirectory),
                                  ("Downloads", "arrow.down.circle", .downloadsDirectory),
                                  ("Documents", "doc", .documentDirectory)] {
            if let url = fm.urls(for: dir, in: .userDomainMask).first { result.append((name, icon, url)) }
        }
        result.append(("Home", "house", fm.homeDirectoryForCurrentUser))
        return result
    }

    var body: some View {
        List {
            if let folder = model.folderURL {
                Section("Folder") {
                    row(folder, name: folder.lastPathComponent, icon: "folder.fill", isCurrent: true)
                    if folder.pathComponents.count > 1 {
                        row(folder.deletingLastPathComponent(), name: "Enclosing Folder", icon: "arrow.turn.left.up")
                    }
                    ForEach(subfolders, id: \.self) { sub in
                        row(sub, name: sub.lastPathComponent, icon: "folder")
                    }
                }
            }
            let recents = RecentFolders.all.filter { $0 != model.folderURL }.prefix(8)
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(Array(recents), id: \.self) { url in
                        row(url, name: url.lastPathComponent, icon: "clock")
                    }
                }
            }
            Section("Locations") {
                ForEach(locations, id: \.2) { name, icon, url in
                    row(url, name: name, icon: icon)
                }
            }
        }
        .listStyle(.sidebar)
        .task(id: model.folderURL) {
            guard let folder = model.folderURL else {
                subfolders = []
                return
            }
            subfolders = await Task.detached(priority: .utility) {
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
                return urls.filter {
                    let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    return v?.isDirectory == true && v?.isPackage != true
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }.value
        }
    }

    private func row(_ url: URL, name: String, icon: String, isCurrent: Bool = false) -> some View {
        Button {
            guard !isCurrent else { return }
            model.openFolder(url, selecting: LastViewed.file(in: url))
        } label: {
            Label(name, systemImage: icon)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(isCurrent ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open in New Window") {
                PendingOpen.urls = [url]
                openWindow(id: "viewer")
            }
        }
    }
}

struct WelcomeView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            VStack(spacing: 6) {
                Text("AOK-ImageTool")
                    .font(.largeTitle.weight(.bold))
                Text("Drop images or a folder here, or open one to start browsing.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Open…") { model.showOpenPanel() }
                    .prominentButtonStyle()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
                    Button("Browse Pictures") { model.openFolder(pictures, selecting: LastViewed.file(in: pictures)) }
                        .glassButtonStyle()
                        .controlSize(.large)
                }
            }
            let recents = Array(RecentFolders.all.prefix(6))
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Folders").font(.headline).foregroundStyle(.secondary)
                    ForEach(recents, id: \.self) { url in
                        Button {
                            model.openFolder(url, selecting: LastViewed.file(in: url))
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(url.lastPathComponent)
                                    Text(url.deletingLastPathComponent().path(percentEncoded: false))
                                        .font(.caption).foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                            } icon: {
                                Image(systemName: "folder.fill").foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
                .padding(.top, 8)
            }
            Text("← → browse  ·  Space next  ·  F full screen  ·  G grid  ·  ? all shortcuts")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
