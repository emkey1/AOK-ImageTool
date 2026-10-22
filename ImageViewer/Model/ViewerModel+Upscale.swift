import AppKit

extension ViewerModel {
    // MARK: - AI upscaling (see `SuperResolution`)

    /// Turns AI sharpening of enlarged images on or off; turning it on may first need the model.
    func setAIEnhancement(_ on: Bool) {
        guard on else {
            Prefs.setBool(false, PrefKey.aiEnhanceEnlarged)
            refreshDisplay()
            return
        }
        withUpscalingModel { [weak self] in
            Prefs.setBool(true, PrefKey.aiEnhanceEnlarged)
            self?.enhanceDisplayIfNeeded()
        }
    }

    /// Saves an AI-upscaled copy (`scale` 2, 3 or 4) of the current image, with its edits, next to the original.
    func upscaleCurrent(by scale: Int) {
        guard let url = currentURL, let d = decoded, d.url == url else { return }
        let e = currentEdits
        withUpscalingModel { [weak self] in self?.saveUpscaled(url: url, decoded: d, edits: e, scale: scale) }
    }

    private func saveUpscaled(url: URL, decoded d: DecodedImage, edits e: EditState, scale: Int) {
        saveCopy(of: url, decoded: d, edits: e, label: "\(scale)×", defaultFormat: .png,
                 working: "Upscaling…", systemImage: "arrow.up.left.and.arrow.down.right",
                 failure: "Couldn't upscale “\(url.lastPathComponent)”") {
            try await SuperResolution.upscale($0, scale: CGFloat(scale))
        }
    }

    /// Runs `then` once Apple's upscaling model is on this Mac, asking before its one-time download.
    func withUpscalingModel(_ then: @escaping () -> Void) {
        switch SuperResolution.modelState {
        case .ready:
            then()
        case .unsupported:
            alert = AlertInfo(title: "AI upscaling isn't available", message: SuperResolution.Failure.unsupported.localizedDescription)
        case .downloading:
            showToast("The upscaling model is still downloading…", systemImage: "arrow.down.circle")
        case .needsDownload:
            let alert = NSAlert()
            alert.messageText = "Download the AI upscaling model?"
            alert.informativeText = "AI upscaling uses a machine-learning model from Apple that runs on this Mac. It needs a one-time download."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                if response == .alertFirstButtonReturn { self?.downloadUpscalingModel(then: then) }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
        }
    }

    private func downloadUpscalingModel(then: @escaping () -> Void) {
        let progress = Task {
            while !Task.isCancelled {
                showToast("Downloading the upscaling model… \(Int(SuperResolution.downloadProgress * 100))%", systemImage: "arrow.down.circle")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task {
            do {
                try await SuperResolution.downloadModel()
                progress.cancel()
                showToast("Upscaling model ready", systemImage: "checkmark.circle")
                then()
            } catch {
                progress.cancel()
                dismissToast()
                showError("Couldn't download the upscaling model", error)
            }
        }
    }
}
