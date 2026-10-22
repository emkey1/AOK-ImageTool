import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// Black and white to color with DDColor (Apache-2.0, github.com/piddnad/DDColor), converted to Core ML and
/// installed per user like the generative fill model. The model looks at the photo in gray at 512 × 512 and
/// gives its color channels (CIE a*b*); those are enlarged and laid on the photo's own lightness (L*) at
/// full resolution, so every bit of light and detail stays as it was and only the color is new.
nonisolated enum Colorizer {
    static let side = 512
    static let modelName = "DDColor.mlmodelc"

    enum Failure: LocalizedError {
        case missingModel, badOutput

        var errorDescription: String? {
            switch self {
            case .missingModel: "The colorizing model isn't installed."
            case .badOutput: "The colorizing model returned an unexpected result."
            }
        }
    }

    static var directory: URL {
        AppStorageLocation.models.appendingPathComponent("Colorize")
    }

    static var isInstalled: Bool {
        GenerativeModel.isSupported && FileManager.default.fileExists(atPath: directory.appendingPathComponent(modelName).path)
    }

    /// Installs a converted model: the .mlmodelc itself or a folder holding it.
    static func install(from source: URL) throws {
        let model = source.lastPathComponent == modelName ? source : source.appendingPathComponent(modelName)
        guard FileManager.default.fileExists(atPath: model.path) else { throw GenerativeModel.InstallError.notAModel }
        unload()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(modelName)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: model, to: dest)
    }

    static func remove() throws {
        unload()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static var sizeOnDisk: Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Model (loaded on first use, released after a few idle minutes)

    private static let queue = DispatchQueue(label: "Colorizer", qos: .userInitiated)
    nonisolated(unsafe) private static var model: MLModel?    // queue only
    nonisolated(unsafe) private static var jobs = 0           // queue only

    private static func unload() {
        queue.async {
            model = nil
            jobs += 1
        }
    }

    /// The model's a*b* for `gray` (1 × 3 × 512 × 512, 0...1), as two 512 × 512 planes.
    private static func predict(_ gray: [Float]) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if model == nil {
                        let config = MLModelConfiguration()
                        config.computeUnits = .cpuAndGPU
                        model = try MLModel(contentsOf: directory.appendingPathComponent(modelName), configuration: config)
                    }
                    let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
                    let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: gray.count)
                    gray.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: gray.count) }
                    let output = try model!.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]))
                    guard let ab = output.featureValue(for: "ab")?.multiArrayValue, ab.count == 2 * side * side else { throw Failure.badOutput }
                    let values: [Float]
                    switch ab.dataType {
                    case .float32:
                        values = MLShapedArray<Float>(ab).scalars
                    #if arch(arm64)
                    case .float16:
                        values = MLShapedArray<Float16>(ab).scalars.map(Float.init)
                    #endif
                    default:
                        throw Failure.badOutput
                    }
                    continuation.resume(returning: values)
                } catch {
                    continuation.resume(throwing: error)
                }
                jobs += 1
                let job = jobs
                queue.asyncAfter(deadline: .now() + 180) { if jobs == job { model = nil } }
            }
        }
    }

    // MARK: Colorizing

    static func colorize(_ photo: CGImage) async throws -> CGImage {
        guard isInstalled else { throw Failure.missingModel }
        let w = photo.width, h = photo.height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        // The model's input: the photo's luminance at 512 × 512, as gray sRGB (as DDColor was trained).
        var small = RGBABitmap(width: side, height: side)
        small.draw(photo, topLeftRect: CGRect(x: 0, y: 0, width: side, height: side), space: srgb, quality: .high)
        var gray = [Float](repeating: 0, count: 3 * side * side)
        let plane = side * side
        for i in 0..<plane {
            let y = Lab.luminance(small.pixels[i * 4], small.pixels[i * 4 + 1], small.pixels[i * 4 + 2])
            let g = Lab.encode(y)
            gray[i] = g; gray[plane + i] = g; gray[2 * plane + i] = g
        }
        let ab = try await predict(gray)

        // Its a*b*, enlarged, on the photo's own L*.
        var full = RGBABitmap(width: w, height: h)
        full.draw(photo, topLeftRect: CGRect(x: 0, y: 0, width: w, height: h), space: srgb, quality: .none)
        let sx = Float(side) / Float(w), sy = Float(side) / Float(h)
        full.pixels.withUnsafeMutableBufferPointer { px in
            ab.withUnsafeBufferPointer { ab in
                for y in 0..<h {
                    let fy = min(max((Float(y) + 0.5) * sy - 0.5, 0), Float(side - 1))
                    let y0 = Int(fy), y1 = min(y0 + 1, side - 1), ty = fy - Float(y0)
                    for x in 0..<w {
                        let fx = min(max((Float(x) + 0.5) * sx - 0.5, 0), Float(side - 1))
                        let x0 = Int(fx), x1 = min(x0 + 1, side - 1), tx = fx - Float(x0)
                        func sample(_ c: Int) -> Float {
                            let o = c * plane
                            let top = ab[o + y0 * side + x0] * (1 - tx) + ab[o + y0 * side + x1] * tx
                            let bottom = ab[o + y1 * side + x0] * (1 - tx) + ab[o + y1 * side + x1] * tx
                            return top * (1 - ty) + bottom * ty
                        }
                        let i = (y * w + x) * 4
                        let l = Lab.lightness(Lab.luminance(px[i], px[i + 1], px[i + 2]))
                        let (r, g, b) = Lab.toSRGB(l, sample(0), sample(1))
                        px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255
                    }
                }
            }
        }
        guard let result = full.makeImage(space: srgb) else { throw Failure.badOutput }
        return result
    }
}

/// CIE L*a*b* (D65) for 8-bit sRGB, with lookup tables for the sRGB curve.
nonisolated private enum Lab {
    static let decodeTable: [Float] = (0..<256).map { i in
        let v = Float(i) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    static let encodeTable: [UInt8] = (0..<4096).map { i in
        let v = Float(i) / 4095
        let e = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(min(max(e * 255, 0), 255).rounded())
    }

    /// Relative luminance (linear) of an sRGB pixel.
    @inline(__always) static func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Float {
        0.2126 * decodeTable[Int(r)] + 0.7152 * decodeTable[Int(g)] + 0.0722 * decodeTable[Int(b)]
    }

    /// Linear → sRGB-encoded, 0...1.
    @inline(__always) static func encode(_ linear: Float) -> Float {
        Float(encodeTable[Int(min(max(linear, 0), 1) * 4095)]) / 255
    }

    @inline(__always) static func lightness(_ y: Float) -> Float {
        116 * f(y) - 16
    }

    @inline(__always) private static func f(_ t: Float) -> Float {
        t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116
    }

    @inline(__always) private static func fInverse(_ t: Float) -> Float {
        t > 0.206893 ? t * t * t : (t - 16 / 116) / 7.787
    }

    static func toSRGB(_ l: Float, _ a: Float, _ b: Float) -> (UInt8, UInt8, UInt8) {
        let fy = (l + 16) / 116
        let x = 0.95047 * fInverse(fy + a / 500), y = fInverse(fy), z = 1.08883 * fInverse(fy - b / 200)
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        func out(_ v: Float) -> UInt8 { encodeTable[Int(min(max(v, 0), 1) * 4095)] }
        return (out(r), out(g), out(bl))
    }
}
