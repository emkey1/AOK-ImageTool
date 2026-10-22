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
        withUpscalingModel { [weak self] in
            guard let self else { return }
            if d.isAnimated, let animation = Animation(url: url) {
                if let estimate = animationUpscale(by: scale), !estimate.allowed {
                    let container = Prefs.upscaledAnimationFormat
                    alert = AlertInfo(title: "This animation is too large to upscale \(scale)× as \(container.shortName)",
                                      message: "It would be about \(ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file)) "
                                        + "(\(animation.count) frames). Try a smaller scale"
                                        + (container == .png ? ", or GIF, which is smaller (Upscale ▸ Save Animation As)." : "."))
                    return
                }
                saveUpscaledAnimation(url: url, decoded: d, animation: animation, edits: e, scale: scale)
            } else {
                saveUpscaled(url: url, decoded: d, edits: e, scale: scale)
            }
        }
    }

    private func saveUpscaled(url: URL, decoded d: DecodedImage, edits e: EditState, scale: Int) {
        saveCopy(of: url, decoded: d, edits: e, label: "\(scale)×", defaultFormat: .png,
                 working: "Upscaling…", systemImage: "arrow.up.left.and.arrow.down.right",
                 failure: "Couldn't upscale “\(url.lastPathComponent)”") {
            try await SuperResolution.upscale($0, scale: CGFloat(scale))
        }
    }

    /// Saves an upscaled copy of an animation, every frame, as an animated GIF or PNG with the original's
    /// timing and looping. Edits that hold for every frame (turns, crop, light and color) are applied; a cutout
    /// or Extend, made for the first frame, isn't.
    /// For an animation: the size `scale`× would make in the chosen format, and whether that's allowed
    /// (see `Animation.Container.maxOutputPixels`). Nil for a still image.
    func animationUpscale(by scale: Int) -> Animation.UpscaleEstimate? {
        guard let d = decoded, d.url == currentURL, d.isAnimated, d.frameCount > 1 else { return nil }
        let e = Self.frameEdits(currentEdits)
        let size = e.isIdentity ? d.pixelSize : EditRenderer.shared.outputSize(d, edits: e)
        return Animation.upscaleEstimate(frames: d.frameCount, width: size.width, height: size.height, scale: scale,
                                         as: Prefs.upscaledAnimationFormat)
    }

    /// The edits that hold for every frame of an animation: turns, crop, light and color, but not a cutout or
    /// Extend, which were made for the first frame.
    nonisolated private static func frameEdits(_ edits: EditState) -> EditState {
        var e = edits
        e.removeCutout()
        if e.cropExtendsBeyondImage, let crop = e.crop {
            let inside = crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            e.crop = inside.isEmpty ? nil : inside
            e.extendFill = nil
        }
        return e
    }

    private func saveUpscaledAnimation(url: URL, decoded d: DecodedImage, animation: Animation, edits: EditState, scale: Int) {
        let e = Self.frameEdits(edits)
        let container = Prefs.upscaledAnimationFormat
        let dest = ImageWriter.uniqueURL(in: copyFolder(for: url), baseName: url.deletingPathExtension().lastPathComponent + " (\(scale)×)",
                                         ext: container.fileExtension)
        let first = animation.frame(0)
        let size = first.map { image -> CGSize in
            guard !e.isIdentity, let out = EditRenderer.shared.renderSync(Self.frameImage(image, of: d), edits: e, maxDimension: nil)?.image else {
                return CGSize(width: image.width, height: image.height)
            }
            return CGSize(width: out.width, height: out.height)
        } ?? .zero
        let count = animation.count
        showToast("Upscaling frame 1 of \(count)…", systemImage: "arrow.up.left.and.arrow.down.right")
        let report: @Sendable (Int) -> Void = { [weak self] n in
            let model = self
            Task { @MainActor in
                // (After the last frame, every frame still has to be encoded into the file.)
                let text = n > count ? "Saving “\(dest.lastPathComponent)”…" : "Upscaling frame \(n) of \(count)…"
                model?.showToast(text, systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let writer = try Animation.Writer(url: dest, container: container, delays: animation.delays, loopCount: animation.loopCount)
                    var first: CGImage?
                    try await SuperResolution.upscaleFrames(count: count, width: Int(size.width), height: Int(size.height), scale: CGFloat(scale),
                                                            frame: { i in
                        guard let image = animation.frame(i) else { throw ImageWriteError.finalizeFailed }
                        guard !e.isIdentity else { return image }
                        guard let out = EditRenderer.shared.renderSync(Self.frameImage(image, of: d), edits: e, maxDimension: nil)?.image
                        else { throw ImageWriteError.finalizeFailed }
                        return out
                    }, emit: { frame in
                        if first == nil { first = frame }
                        writer.add(frame)
                    }, progress: { fraction in
                        report(min(count, Int(fraction * Double(count)) + 1))
                        return false
                    })
                    report(count + 1)
                    try writer.finish()
                    Self.copyWritten(dest, picture: first, from: url)
                }.value
                try await finishCopy(dest, from: url)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                dismissToast()
                showError("Couldn't upscale “\(url.lastPathComponent)”", error)
            }
        }
    }

    /// One frame of an animation, to render with edits.
    nonisolated private static func frameImage(_ image: CGImage, of d: DecodedImage) -> DecodedImage {
        DecodedImage(url: d.url, cgImage: image, isHDR: false, isAnimated: false, pageCount: 1, pageIndex: 0,
                     typeIdentifier: d.typeIdentifier, properties: d.properties, sourceOrientation: .up, isVector: false)
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
