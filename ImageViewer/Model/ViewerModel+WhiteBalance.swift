import AppKit

extension ViewerModel {
    // MARK: - White balance

    /// The eyedropper out or put away: while it's out, the pointer is a crosshair and a click on the picture
    /// picks (clicks anywhere else work as usual).
    func whiteBalancePickerChanged() {
        if pickingWhiteBalance {
            viewMode = .viewer
            showOriginal = false
            showToast("Click something in the photo that should be white or gray", systemImage: "eyedropper")
            window?.disableCursorRects()
            NSCursor.crosshair.push()
            whiteBalanceMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, let canvas = self.canvas,
                      let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: canvas.container) else { return event }
                let doc = canvas.documentView
                let point = doc.convert(event.locationInWindow, from: nil)
                guard doc.bounds.contains(point) else { return event }
                self.pickWhiteBalance(at: CGPoint(x: point.x / doc.bounds.width, y: point.y / doc.bounds.height))
                return nil
            }
        } else {
            if let whiteBalanceMonitor { NSEvent.removeMonitor(whiteBalanceMonitor) }
            whiteBalanceMonitor = nil
            NSCursor.pop()
            window?.enableCursorRects()
            if let doc = canvas?.documentView { window?.invalidateCursorRects(for: doc) }
        }
    }

    /// The eyedropper's click (`point` normalized in the picture, Core Image's y up): Warmth and Tint set so what's
    /// there comes out neutral.
    func pickWhiteBalance(at point: CGPoint) {
        pickingWhiteBalance = false
        guard let url = currentURL, let d = decoded, d.url == url else { return }
        let e = currentEdits
        Task {
            guard let pick = await WhiteBalance.neutral(d, edits: e, at: point) else {
                return showToast("That's too dark, or outside the photo, to go by. Click something white or gray that's lit.", systemImage: "eyedropper")
            }
            guard currentURL == url else { return }
            updateEdits("White Balance") {
                $0.temperature = pick.temperature
                $0.tint = pick.tint
            }
            if pick.target == .skin {
                showToast("Balanced for natural skin, from the face clicked", systemImage: "eyedropper")
            } else if pick.colorful {
                showToast("That was quite colorful for something white or gray: if the photo looks wrong, ⌘Z and pick again",
                          systemImage: "eyedropper")
            }
        }
    }

    /// White Balance ▸ Auto: the color cast taken out, going by what in the photo should be neutral.
    func autoWhiteBalance() {
        guard let url = currentURL, let d = decoded, d.url == url else { return }
        let e = currentEdits
        Task {
            guard let balance = await WhiteBalance.auto(d, edits: e) else {
                return showToast("Nothing in this photo looks like it should be neutral. Use the eyedropper on something white or gray.",
                                 systemImage: "eyedropper")
            }
            guard currentURL == url else { return }
            updateEdits("Auto White Balance") {
                $0.temperature = balance.temperature
                $0.tint = balance.tint
            }
        }
    }

    /// White Balance ▸ Lit By: corrected for `light`, or (nil) as shot.
    func setWhiteBalance(_ light: WhiteBalance.Light?) {
        let setting = light?.setting ?? (temperature: 0, tint: 0)
        updateEdits(light == nil ? "White Balance As Shot" : "White Balance") {
            $0.temperature = setting.temperature
            $0.tint = setting.tint
        }
    }
}
