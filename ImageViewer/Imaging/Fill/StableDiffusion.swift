import Accelerate
import CoreML
import Foundation

/// Stable Diffusion 1.5 Inpainting with Core ML: fills the masked part of a 512 × 512 image with new content
/// that continues the rest. Runs entirely on this Mac with the model in `GenerativeModel.directory`
/// (converted from the official weights with Apple's ml-stable-diffusion tools; see scripts/convert-inpainting-model.sh).
///
/// Apple's StableDiffusion Swift package does text-to-image and image-to-image but not inpainting (the
/// 9-channel UNet: noisy latents, the mask and the masked image's latents), so the loop is our own.
nonisolated final class StableDiffusionInpainter: @unchecked Sendable {
    static let size = 512
    static let latentSize = 64
    static let latentScale: Float = 0.18215

    struct Request: Sendable {
        /// `size` × `size` RGBA, rows top to bottom.
        var rgba: [UInt8]
        /// `size` × `size`, nonzero where new content goes.
        var mask: [UInt8]
        var prompt: String
        var negativePrompt: String
        var seed: UInt64
        var steps = 25
        var guidance: Float = 7.5
        /// A rough version of the result (`size` × `size` RGBA) to start from instead of pure noise, kept
        /// as much as `1 - strength`: it steers the layout so the model continues the picture rather than
        /// starting a new one.
        var initial: [UInt8]?
        var strength: Float = 1
    }

    enum Failure: LocalizedError {
        case missingModel
        case cancelled
        case badOutput

        var errorDescription: String? {
            switch self {
            case .missingModel: "The generative fill model isn't installed."
            case .cancelled: "Generating was cancelled."
            case .badOutput: "The generative fill model returned an unexpected result."
            }
        }
    }

    let tokenizer: CLIPTokenizer
    private let textEncoder: MLModel
    private let unet: MLModel
    private let vaeEncoder: MLModel
    private let vaeDecoder: MLModel

    static let modelFiles = ["TextEncoder.mlmodelc", "Unet.mlmodelc", "VAEEncoder.mlmodelc", "VAEDecoder.mlmodelc",
                             "vocab.json", "merges.txt"]

    static func isComplete(_ directory: URL) -> Bool {
        modelFiles.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Loading compiles the models for this Mac the first time (Core ML caches that), which can take a minute.
    init(directory: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        guard Self.isComplete(directory) else { throw Failure.missingModel }
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: config)
        }
        tokenizer = try CLIPTokenizer(vocabulary: directory.appendingPathComponent("vocab.json"),
                                      merges: directory.appendingPathComponent("merges.txt"))
        textEncoder = try load("TextEncoder.mlmodelc", .cpuAndGPU)
        unet = try load("Unet.mlmodelc", computeUnits)
        vaeEncoder = try load("VAEEncoder.mlmodelc", .cpuAndGPU)
        vaeDecoder = try load("VAEDecoder.mlmodelc", .cpuAndGPU)
    }

    /// Returns `size` × `size` RGBA. `progress` gets 0...1 and returns true to cancel.
    func inpaint(_ r: Request, progress: (Double) -> Bool = { _ in false }) throws -> [UInt8] {
        let n = Self.size, ln = Self.latentSize
        precondition(r.rgba.count == n * n * 4 && r.mask.count == n * n)

        // Text: unconditional (negative) and conditional halves of the batch.
        let negative = try encode(r.negativePrompt)
        let positive = try encode(r.prompt)
        let hidden = try Self.half(negative + positive, shape: [2, 768, 1, 77])

        // The masked image (new area mid-gray, i.e. 0 in -1...1) and the mask, in latent space.
        var pixels = [Float](repeating: 0, count: 3 * n * n)
        for i in 0..<(n * n) where r.mask[i] == 0 {
            for c in 0..<3 { pixels[c * n * n + i] = Float(r.rgba[i * 4 + c]) / 127.5 - 1 }
        }
        let moments = try floats(vaeEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "x": MLFeatureValue(multiArray: Self.half(pixels, shape: [1, 3, n, n])),
        ])), "latent")
        guard moments.count == 8 * ln * ln else { throw Failure.badOutput }
        let maskedLatents = moments[0..<(4 * ln * ln)].map { $0 * Self.latentScale }   // the mean
        // A latent cell is new if any of its 8 × 8 pixels is.
        var latentMask = [Float](repeating: 0, count: ln * ln)
        for y in 0..<n { for x in 0..<n where r.mask[y * n + x] != 0 { latentMask[(y / 8) * ln + x / 8] = 1 } }
        if progress(0.04) { throw Failure.cancelled }

        var scheduler = DPMSolverMultistepScheduler(steps: r.steps)
        var rng = GaussianNoise(seed: r.seed)
        var latents = (0..<(4 * ln * ln)).map { _ in rng.next() }
        var start = 0
        if let initial = r.initial, initial.count == n * n * 4, r.strength < 1 {
            var picture = [Float](repeating: 0, count: 3 * n * n)
            for i in 0..<(n * n) { for c in 0..<3 { picture[c * n * n + i] = Float(initial[i * 4 + c]) / 127.5 - 1 } }
            let encoded = try floats(vaeEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "x": MLFeatureValue(multiArray: Self.half(picture, shape: [1, 3, n, n])),
            ])), "latent")
            guard encoded.count == 8 * ln * ln else { throw Failure.badOutput }
            start = min(r.steps - 1, max(0, r.steps - Int((Float(r.steps) * r.strength).rounded())))
            latents = scheduler.noised(encoded[0..<(4 * ln * ln)].map { $0 * Self.latentScale }, noise: latents, index: start)
        }
        let plane = ln * ln
        let total = scheduler.timesteps.count - start
        for (i, t) in scheduler.timesteps.enumerated() where i >= start {
            // [latents, mask, masked image latents] for each half of the batch.
            var sample = [Float](repeating: 0, count: 2 * 9 * plane)
            for b in 0..<2 {
                let o = b * 9 * plane
                sample.replaceSubrange(o..<(o + 4 * plane), with: latents)
                sample.replaceSubrange((o + 4 * plane)..<(o + 5 * plane), with: latentMask)
                sample.replaceSubrange((o + 5 * plane)..<(o + 9 * plane), with: maskedLatents)
            }
            let out = try floats(unet.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "sample": MLFeatureValue(multiArray: Self.half(sample, shape: [2, 9, ln, ln])),
                "timestep": MLFeatureValue(multiArray: Self.half([Float(t), Float(t)], shape: [2])),
                "encoder_hidden_states": MLFeatureValue(multiArray: hidden),
            ])), "noise_pred")
            guard out.count == 2 * 4 * plane else { throw Failure.badOutput }
            // Classifier-free guidance.
            var noise = [Float](repeating: 0, count: 4 * plane)
            for j in 0..<(4 * plane) {
                let u = out[j], c = out[4 * plane + j]
                noise[j] = u + r.guidance * (c - u)
            }
            latents = scheduler.step(noise: noise, index: i, sample: latents)
            if progress(0.04 + 0.92 * Double(i + 1 - start) / Double(total)) { throw Failure.cancelled }
        }

        let decoded = try floats(vaeDecoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "z": MLFeatureValue(multiArray: Self.half(latents.map { $0 / Self.latentScale }, shape: [1, 4, ln, ln])),
        ])), "image")
        guard decoded.count == 3 * n * n else { throw Failure.badOutput }
        var rgba = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) {
            for c in 0..<3 {
                let v = (decoded[c * n * n + i] + 1) * 127.5
                // (Float.maximum and .minimum turn a NaN, from a float16 overflow, into 0 instead of trapping.)
                rgba[i * 4 + c] = UInt8(Float.minimum(Float.maximum(v, 0), 255).rounded())
            }
        }
        _ = progress(1)
        return rgba
    }

    /// CLIP's last hidden state, laid out [768, 1, 77] as the UNet takes it.
    private func encode(_ text: String) throws -> [Float] {
        let ids = tokenizer.encode(text).map(Float.init)
        let out = try floats(textEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: Self.single(ids, shape: [1, 77])),
        ])), "last_hidden_state")
        guard out.count == 77 * 768 else { throw Failure.badOutput }
        var hidden = [Float](repeating: 0, count: 768 * 77)
        for t in 0..<77 { for c in 0..<768 { hidden[c * 77 + t] = out[t * 768 + c] } }
        return hidden
    }

    // MARK: Multi-array plumbing

    private static func contiguousStrides(_ shape: [Int]) -> [NSNumber] {
        var strides = [Int](repeating: 1, count: shape.count)
        for i in stride(from: shape.count - 2, through: 0, by: -1) { strides[i] = strides[i + 1] * shape[i + 1] }
        return strides.map(NSNumber.init)
    }

    /// A Float16 multi-array (what the converted models take) from 32-bit values.
    private static func half(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let count = values.count
        let data = UnsafeMutableRawPointer.allocate(byteCount: count * 2, alignment: 64)
        values.withUnsafeBufferPointer { src in
            var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                  width: vImagePixelCount(count), rowBytes: count * 4)
            var d = vImage_Buffer(data: data, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
            vImageConvert_PlanarFtoPlanar16F(&s, &d, vImage_Flags(kvImageNoFlags))
        }
        return try MLMultiArray(dataPointer: data, shape: shape.map(NSNumber.init), dataType: .float16,
                                strides: contiguousStrides(shape), deallocator: { $0.deallocate() })
    }

    private static func single(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let data = UnsafeMutableRawPointer.allocate(byteCount: values.count * 4, alignment: 64)
        values.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return try MLMultiArray(dataPointer: data, shape: shape.map(NSNumber.init), dataType: .float32,
                                strides: contiguousStrides(shape), deallocator: { $0.deallocate() })
    }

    /// An output as contiguous 32-bit values, whatever its type and strides.
    private func floats(_ provider: MLFeatureProvider, _ name: String) throws -> [Float] {
        guard let array = provider.featureValue(for: name)?.multiArrayValue else { throw Failure.badOutput }
        switch array.dataType {
        case .float32:
            return MLShapedArray<Float>(array).scalars
        case .float16:
            let shape = array.shape.map(\.intValue)
            guard array.strides.map(\.intValue) == Self.contiguousStrides(shape).map(\.intValue) else { throw Failure.badOutput }
            let count = array.count
            var result = [Float](repeating: 0, count: count)
            result.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: array.dataPointer, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(kvImageNoFlags))
            }
            return result
        default:
            return (0..<array.count).map { array[$0].floatValue }
        }
    }
}

// MARK: - Scheduler

/// DPM-Solver++ (2M), as diffusers' DPMSolverMultistepScheduler with SD 1.5's training schedule: good
/// results in 20–25 steps.
nonisolated struct DPMSolverMultistepScheduler {
    let timesteps: [Int]
    private let alphasCumprod: [Double]
    private var previous: (x0: [Float], t: Int)?

    init(steps: Int, trainSteps: Int = 1000, betaStart: Double = 0.00085, betaEnd: Double = 0.012) {
        var product = 1.0
        alphasCumprod = (0..<trainSteps).map { i in
            let b = sqrt(betaStart) + (sqrt(betaEnd) - sqrt(betaStart)) * Double(i) / Double(trainSteps - 1)
            product *= 1 - b * b
            return product
        }
        // "linspace" spacing: linspace(0, 999, steps + 1).round(), reversed, without the final 0.
        timesteps = (0..<steps).map { i in Int((Double(trainSteps - 1) * Double(steps - i) / Double(steps)).rounded()) }
    }

    private func coefficients(_ t: Int) -> (alpha: Double, sigma: Double, lambda: Double) {
        let alpha = sqrt(alphasCumprod[t]), sigma = sqrt(1 - alphasCumprod[t])
        return (alpha, sigma, log(alpha) - log(sigma))
    }

    /// A clean sample noised to `timesteps[index]` (to start part-way, from a picture).
    func noised(_ x0: [Float], noise: [Float], index: Int) -> [Float] {
        let c = coefficients(timesteps[index])
        return (0..<x0.count).map { Float(c.alpha) * x0[$0] + Float(c.sigma) * noise[$0] }
    }

    /// One step from `timesteps[index]` to the next (or to the clean image after the last).
    mutating func step(noise: [Float], index: Int, sample: [Float]) -> [Float] {
        let t = timesteps[index]
        let s0 = coefficients(t)
        let x0 = zip(sample, noise).map { Float((Double($0) - s0.sigma * Double($1)) / s0.alpha) }
        defer { previous = (x0, t) }
        guard index + 1 < timesteps.count else { return x0 }   // final sigma is zero
        let target = coefficients(timesteps[index + 1])
        let h = target.lambda - s0.lambda
        let a = Float(target.sigma / s0.sigma), b = Float(target.alpha * (exp(-h) - 1))
        guard let previous else {
            return (0..<sample.count).map { a * sample[$0] - b * x0[$0] }
        }
        let s1 = coefficients(previous.t)
        let r0 = Float((s0.lambda - s1.lambda) / h)
        return (0..<sample.count).map { i in
            let d1 = (x0[i] - previous.x0[i]) / r0
            return a * sample[i] - b * x0[i] - 0.5 * b * d1
        }
    }
}

// MARK: - Noise

/// Reproducible standard normal noise (SplitMix64 + Box–Muller), so a saved seed gives the same fill again.
nonisolated struct GaussianNoise {
    private var state: UInt64
    private var spare: Float?

    init(seed: UInt64) { state = seed }

    private mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53)
    }

    mutating func next() -> Float {
        if let s = spare {
            spare = nil
            return s
        }
        let u1 = uniform(), u2 = uniform()
        let radius = sqrt(-2 * log(u1))
        spare = Float(radius * sin(2 * .pi * u2))
        return Float(radius * cos(2 * .pi * u2))
    }
}

// MARK: - Tokenizer

/// CLIP's byte-level BPE tokenizer (as in openai/CLIP and Hugging Face's CLIPTokenizer).
nonisolated final class CLIPTokenizer: @unchecked Sendable {
    static let length = 77
    let startToken = 49406
    let endToken = 49407

    private let vocabulary: [String: Int]
    private let ranks: [String: Int]          // "first second" → merge priority
    private let byteEncoder: [Character]
    private let pattern = try! NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
        options: [.caseInsensitive])
    private var cache: [String: [String]] = [:]
    private let lock = NSLock()

    init(vocabulary: URL, merges: URL) throws {
        self.vocabulary = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabulary))
        var ranks: [String: Int] = [:]
        let lines = try String(contentsOf: merges, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        for (i, line) in lines.enumerated() where !line.hasPrefix("#version") {
            ranks[String(line)] = i
        }
        self.ranks = ranks
        // GPT-2's reversible byte → printable character table.
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var chars = bytes
        var extra = 0
        for b in 0..<256 where !bytes.contains(b) {
            bytes.append(b)
            chars.append(256 + extra)
            extra += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bytes, chars) { table[b] = Character(UnicodeScalar(UInt32(c))!) }
        byteEncoder = table
    }

    /// Token ids: start, the text (truncated to fit), end, then padding with the end token, 77 in all.
    func encode(_ text: String) -> [Int] {
        let cleaned = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var ids: [Int] = []
        let ns = cleaned as NSString
        for match in pattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let word = String(ns.substring(with: match.range).utf8.map { byteEncoder[Int($0)] })
            for piece in bpe(word) {
                if let id = vocabulary[piece] { ids.append(id) }
            }
        }
        ids = [startToken] + ids.prefix(Self.length - 2) + [endToken]
        return ids + Array(repeating: endToken, count: Self.length - ids.count)
    }

    private func bpe(_ token: String) -> [String] {
        if let hit = lock.withLock({ cache[token] }) { return hit }
        var word = token.map(String.init)
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let rank = ranks[word[i] + " " + word[i + 1]], rank < (best?.rank ?? .max) { best = (rank, i) }
            }
            guard let best else { break }
            // Merge every occurrence of the best pair.
            let first = word[best.index], second = word[best.index + 1]
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        lock.withLock { cache[token] = word }
        return word
    }
}
