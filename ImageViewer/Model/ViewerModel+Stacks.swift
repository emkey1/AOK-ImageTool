import AppKit

/// Stacks: an image and the copies made from it (see `ImageStacks`) take one place in the list, showing the
/// newest copy, until the stack is spread out. ⌥← and ⌥→ step through a stack's copies in place.
extension ViewerModel {
    struct StackedList {
        var items: [ImageItem]
        var stacks: [URL: [URL]] = [:]
        var stackOf: [URL: URL] = [:]
    }

    /// `list` (sorted and filtered) with each closed stack down to the copy it shows. Each stack takes the
    /// place of its first member in `list`. `keep` (the image to stay on) is shown even if its stack is closed.
    func stacked(_ list: [ImageItem], keeping keep: URL?) -> StackedList {
        guard stacksEnabled else { return StackedList(items: list) }
        let found = ImageStacks.stacks(list)
        guard !found.isEmpty else { return StackedList(items: list) }
        var result = StackedList(items: [])
        for (root, members) in found {
            let urls = members.map(\.url)
            result.stacks[root] = urls
            for url in urls { result.stackOf[url] = root }
        }
        if let keep, let root = result.stackOf[keep] { stackFront[root] = keep }
        var placed: Set<URL> = []
        result.items.reserveCapacity(list.count)
        for item in list {
            guard let root = result.stackOf[item.url] else {
                result.items.append(item)
                continue
            }
            guard placed.insert(root).inserted, let members = found[root] else { continue }
            if expandedStacks.contains(root) {
                result.items.append(contentsOf: members)
            } else {
                result.items.append(members.first { $0.url == stackFront[root] } ?? members[0])
            }
        }
        return result
    }

    struct StackBadge: Equatable {
        /// Images in the stack, the original included.
        let count: Int
        /// From the top: 0 is the newest copy.
        let position: Int
        let expanded: Bool
    }

    func stackBadge(for url: URL) -> StackBadge? {
        guard let root = stackOf[url], let members = stacks[root], let i = members.firstIndex(of: url) else { return nil }
        return StackBadge(count: members.count, position: i, expanded: expandedStacks.contains(root))
    }

    /// The current image's place in its stack: (position from the top, count), or nil when it isn't stacked.
    var currentStackPosition: (index: Int, count: Int)? {
        guard let url = currentURL, let root = stackOf[url], let members = stacks[root],
              let i = members.firstIndex(of: url) else { return nil }
        return (i, members.count)
    }

    /// Shows the next copy down the stack (`delta` 1, toward the original) or up it (-1, toward the newest).
    func stepInStack(_ delta: Int) {
        guard let url = currentURL, let root = stackOf[url], let members = stacks[root],
              let i = members.firstIndex(of: url), members.indices.contains(i + delta) else {
            NSSound.beep()
            return
        }
        let target = members[i + delta]
        if let index = items.firstIndex(where: { $0.url == target }) {
            show(index: index)
        } else if let ci = currentIndex, let item = allItems.first(where: { $0.url == target }) {
            stackFront[root] = target
            replaceListedItem(at: ci, with: item)
            show(index: ci)
        }
    }

    func isStackExpanded(_ url: URL) -> Bool {
        stackOf[url].map(expandedStacks.contains) ?? false
    }

    /// Spreads out the stack `url` is in, or closes it (showing the image being viewed, if it's in it).
    func toggleStack(_ url: URL) {
        guard let root = stackOf[url] else { return }
        if expandedStacks.remove(root) == nil { expandedStacks.insert(root) }
        let current = currentURL
        if let current, stackOf[current] != root, !expandedStacks.contains(root) { stackFront[root] = url }
        applySortAndFilter(selecting: current)
    }

    func setAllStacks(expanded: Bool) {
        expandedStacks = expanded ? Set(stacks.keys) : []
        applySortAndFilter(selecting: currentURL)
    }

    /// Copies whose recorded source is `original`, re-pointed at its new name after a rename.
    func relinkCopies(of original: URL, to renamed: URL) {
        let parents = ImageStacks.parents(allItems)
        for (copy, parent) in parents where parent == original {
            ImageStacks.markDerived(copy, from: renamed)
            updateItem(copy) { $0.source = renamed.lastPathComponent }
        }
    }
}
