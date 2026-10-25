import AppKit

extension ViewerModel {
    // MARK: - Star ratings (in the file's XMP, or a sidecar for RAW)

    /// 1–5: that many stars for the selected images; the same number again adds a half star (3, 3½, 3).
    /// 0 clears.
    func rateKey(_ stars: Int) {
        let n = Double(stars)
        let now = currentItem?.rating ?? 0
        setRating(stars == 0 ? 0 : now == n && n < 5 ? n + 0.5 : n)
    }

    /// Rates the selected images (or `targets`): shown at once (in every window), and written to each file, or
    /// to its sidecar, in the background.
    func setRating(_ rating: Double, for targets: [URL]? = nil) {
        let urls = targets ?? actionTargets
        guard !urls.isEmpty else { return }
        guard !urls.contains(where: PhotosRoundTrip.isFromPhotos) else {
            alert = AlertInfo(title: "Photos doesn't keep star ratings", message: "Mark the photo as a favorite in Photos instead.")
            return
        }
        let before = Dictionary(urls.map { url in (url, allItems.first { $0.url == url }?.rating ?? 0) }, uniquingKeysWith: { a, _ in a })
        showRating(rating, for: urls)
        showToast(rating == 0 ? (urls.count == 1 ? "Rating removed" : "Ratings removed from \(urls.count) images")
                  : urls.count == 1 ? "Rated \(starsText(rating))" : "Rated \(urls.count) images \(starsText(rating))",
                  systemImage: rating == 0 ? "star.slash" : "star.fill")
        Task {
            var failures: [String] = []
            for url in urls where before[url] != rating {
                do {
                    if let modified = try await FileTags.write(FileTags.Update(rating: rating), to: url) {
                        fileRewritten(url, modified: modified)
                    }
                } catch {
                    failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
                    showRating(before[url] ?? 0, for: [url])
                }
            }
            if !failures.isEmpty {
                alert = AlertInfo(title: failures.count == 1 ? "A rating couldn't be saved" : "\(failures.count) ratings couldn't be saved",
                                  message: failures.prefix(6).joined(separator: "\n"))
            }
        }
    }

    /// Every window showing these images shows the rating (and re-sorts or re-filters by it).
    private func showRating(_ rating: Double, for urls: [URL]) {
        for model in ViewerRegistry.shared.all {
            for url in urls { model.updateItem(url) { $0.rating = rating } }
            if model.sortKey == .rating || model.flagFilter.minimumStars != nil { model.applySortAndFilter() }
        }
    }

    /// A file rewritten with only its metadata changed: every window, and its unsaved edits, take the new
    /// modification date, so nothing takes it for a file changed by another app.
    func fileRewritten(_ url: URL, modified: Date) {
        for model in ViewerRegistry.shared.all { model.updateItem(url) { $0.modificationDate = modified } }
        PendingEdits.shared.fileRewritten(url, modificationDate: modified)
    }
}
