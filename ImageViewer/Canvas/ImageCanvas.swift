import SwiftUI

/// SwiftUI bridge to the AppKit canvas.
struct ImageCanvas: NSViewRepresentable {
    let model: ViewerModel

    @AppStorage(PrefKey.canvasBackground) private var background = CanvasBackground.dark.rawValue
    @AppStorage(PrefKey.checkerboard) private var checkerboard = true
    @AppStorage(PrefKey.pixelatedZoom) private var pixelated = false
    @AppStorage(PrefKey.upscaleSmallImages) private var enlargeSmall = false
    @AppStorage(PrefKey.liveTextEnabled) private var liveText = true

    func makeCoordinator() -> CanvasController {
        CanvasController()
    }

    func makeNSView(context: Context) -> CanvasContainerView {
        let controller = context.coordinator
        controller.model = model
        model.canvas = controller
        return controller.container
    }

    func updateNSView(_ view: CanvasContainerView, context: Context) {
        let controller = context.coordinator
        view.background = CanvasBackground(rawValue: background) ?? .dark
        let appearanceChanged = controller.checkerboard != checkerboard || controller.pixelated != pixelated
        controller.checkerboard = checkerboard
        controller.pixelated = pixelated
        controller.liveTextEnabled = liveText
        controller.enlargeSmallImages = enlargeSmall
        let display = model.display
        if display?.revision != controller.display?.revision {
            controller.show(display, transition: model.isSlideshowRunning)
        } else if appearanceChanged {
            controller.refreshAppearance()
        }
    }
}
