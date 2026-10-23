import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// A converted Core ML model that takes a square picture (and, for some, a mask) and gives one back, installed
/// per user in its own folder of the models directory. It's loaded on first use, runs one job at a time and is
/// let go after a few idle minutes.
nonisolated final class ImageModel: @unchecked Sendable {
    enum Failure: LocalizedError {
        case missingModel(String), badOutput(String)

        var errorDescription: String? {
            switch self {
            case .missingModel(let name): "The \(name) model isn't installed."
            case .badOutput(let name): "The \(name) model returned an unexpected result."
            }
        }
    }

    /// For messages: “the object removal model”.
    let purpose: String
    let folder: String
    let modelName: String
    /// The width and height it takes.
    let side: Int

    private let queue: DispatchQueue
    private var model: MLModel?    // queue only
    private var jobs = 0           // queue only

    init(purpose: String, folder: String, modelName: String, side: Int) {
        self.purpose = purpose
        self.folder = folder
        self.modelName = modelName
        self.side = side
        queue = DispatchQueue(label: "ImageModel.\(folder)", qos: .userInitiated)
    }

    var directory: URL { AppStorageLocation.models.appendingPathComponent(folder) }

    var isInstalled: Bool {
        GenerativeModel.isSupported && FileManager.default.fileExists(atPath: directory.appendingPathComponent(modelName).path)
    }

    /// Installs a converted model: the .mlmodelc itself or a folder holding it.
    func install(from source: URL) throws {
        try InstalledModel.install(modelName, from: source, into: directory) { unload() }
    }

    func remove() throws {
        unload()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    var sizeOnDisk: Int64 { InstalledModel.size(of: directory) }

    func unload() {
        queue.async {
            self.model = nil
            self.jobs += 1
        }
    }

    /// `image` (`side` × `side`, drawn in `space`) through the model; `mask` (`side` × `side` bytes, rows
    /// top-down) for one that takes it. On the GPU at the precision it was converted at.
    func predict(_ image: CGImage, mask: [UInt8]? = nil, space: CGColorSpace) async throws -> CGImage {
        guard isInstalled else { throw Failure.missingModel(purpose) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.model == nil {
                        let config = MLModelConfiguration()
                        config.computeUnits = .cpuAndGPU
                        self.model = try MLModel(contentsOf: self.directory.appendingPathComponent(self.modelName), configuration: config)
                    }
                    var inputs: [String: Any] = ["image": MLFeatureValue(pixelBuffer: try self.pixelBuffer(image, space: space))]
                    if let mask { inputs["mask"] = MLFeatureValue(pixelBuffer: try self.maskBuffer(mask)) }
                    let output = try self.model!.prediction(from: try MLDictionaryFeatureProvider(dictionary: inputs))
                    guard let buffer = output.featureValue(for: "output")?.imageBufferValue else { throw Failure.badOutput(self.purpose) }
                    continuation.resume(returning: try self.picture(buffer, space: space))
                } catch {
                    continuation.resume(throwing: error)
                }
                self.jobs += 1
                let job = self.jobs
                self.queue.asyncAfter(deadline: .now() + 180) { if self.jobs == job { self.model = nil } }
            }
        }
    }

    private func newBuffer(_ format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, side, side, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure.badOutput(purpose) }
        return buffer
    }

    private func pixelBuffer(_ image: CGImage, space: CGColorSpace) throws -> CVPixelBuffer {
        let buffer = try newBuffer(kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure.badOutput(purpose) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }

    private func maskBuffer(_ mask: [UInt8]) throws -> CVPixelBuffer {
        let buffer = try newBuffer(kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.badOutput(purpose) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let n = side
        mask.withUnsafeBufferPointer { m in
            for y in 0..<n {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<n { row[x] = m[y * n + x] != 0 ? 255 : 0 }
            }
        }
        return buffer
    }

    /// The model's output as a picture in `space` (copied out: Core ML reuses its buffers).
    private func picture(_ buffer: CVPixelBuffer, space: CGColorSpace) throws -> CGImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let order: CGBitmapInfo
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA: order = .byteOrder32Little
        case kCVPixelFormatType_32ARGB: order = .byteOrder32Big
        default: throw Failure.badOutput(purpose)
        }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.badOutput(purpose) }
        let data = Data(bytes: base, count: rowBytes * h)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | order.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw Failure.badOutput(purpose) }
        return image
    }
}
