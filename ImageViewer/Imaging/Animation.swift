import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An animated image's frames as they're shown (ImageIO composites each GIF or APNG frame over the ones
/// before it), with their timing, and writing a new animation.
nonisolated struct Animation {
    let source: CGImageSource
    let count: Int
    /// Seconds each frame shows.
    let delays: [Double]
    /// 0 plays forever.
    let loopCount: Int
    let width: Int
    let height: Int

    /// Where each format keeps its timing.
    private static let keys: [(dictionary: CFString, delay: CFString, unclamped: CFString, loop: CFString)] = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFLoopCount),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGLoopCount),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPLoopCount),
        (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSDelayTime, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSLoopCount),
    ]

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.source = source
        count = CGImageSourceGetCount(source)
        width = first.width
        height = first.height
        let file = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any]) ?? [:]
        loopCount = Self.keys.lazy.compactMap { (file[$0.dictionary] as? [CFString: Any])?[$0.loop] as? Int }.first ?? 0
        delays = (0..<count).map { i in
            let props = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]) ?? [:]
            for key in Self.keys {
                guard let dict = props[key.dictionary] as? [CFString: Any] else { continue }
                let delay = (dict[key.unclamped] as? Double) ?? (dict[key.delay] as? Double) ?? 0
                // As browsers do: a frame with (almost) no delay shows for a tenth of a second.
                return delay < 0.011 ? 0.1 : delay
            }
            return 0.1
        }
    }

    func frame(_ index: Int) -> CGImage? {
        CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    /// Animated GIF, which plays everywhere (256 colors a frame), or animated PNG, in full color.
    enum Container: String, CaseIterable, Identifiable, Sendable {
        case gif, png

        var id: String { rawValue }
        var fileExtension: String { rawValue }
        var title: String { self == .gif ? "GIF" : "Animated PNG (Full Color)" }
        fileprivate var type: UTType { self == .gif ? .gif : .png }
    }

    /// Writes frames as they come, with these timings and looping, as `container`.
    final class Writer {
        private let destination: CGImageDestination
        private let container: Container
        private let delays: [Double]
        private var index = 0

        init(url: URL, container: Container, delays: [Double], loopCount: Int) throws {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, container.type.identifier as CFString, delays.count, nil) else {
                throw ImageWriteError.cannotCreateDestination(container.title)
            }
            self.destination = destination
            self.container = container
            self.delays = delays
            let file: [CFString: Any] = container == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loopCount]]
            CGImageDestinationSetProperties(destination, file as CFDictionary)
        }

        func add(_ frame: CGImage) {
            let delay = delays[min(index, delays.count - 1)]
            let props: [CFString: Any] = container == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]]
            CGImageDestinationAddImage(destination, frame, props as CFDictionary)
            index += 1
        }

        func finish() throws {
            guard CGImageDestinationFinalize(destination) else { throw ImageWriteError.finalizeFailed }
        }
    }
}
