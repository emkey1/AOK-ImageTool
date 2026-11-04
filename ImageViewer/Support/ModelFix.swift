import CryptoKit
import Foundation

/// A correction to an installed model's program (`model.mil` in its .mlmodelc), made just before the model loads.
/// These models were converted at half precision, and some of their normalization arithmetic doesn't fit it: squares
/// over 256 overflow in the VAEs' group norms, and Restormer's attention sums 147,456 of them. What that does depends on
/// how Core ML runs the program. macOS 15's CPU really computes it, so the VAEs give flat gray and generated pictures
/// come out as a blur; on any Mac's CPU Restormer gets colors wrong. The fixed programs (made by
/// scripts/fix-model-programs.py) do that arithmetic at full precision. The weights don't change, so nothing has to be
/// downloaded again, and results on the GPU stay the same to within a rounding step or two.
nonisolated struct ModelFix: Sendable {
    /// In the app's resources, compressed.
    let resource: String
    /// The SHA-256 of the program it replaces, and of itself.
    let shipped: String
    let fixed: String

    static let vaeDecoder = ModelFix(resource: "VAEDecoder-fixed.mil",
                                     shipped: "6bdecc68887b268cc3e0ffecf0b4018a7fef2315c4a250d7b79822a1e9c16204",
                                     fixed: "de4c7dd67b77a3bec3b23e64f37cee6cb320212eec56cdf67d5d050158f770d4")
    static let vaeEncoder = ModelFix(resource: "VAEEncoder-fixed.mil",
                                     shipped: "7b4d4cfa145816ba218c366d323d1267f3d43e15506c86c6cd9059293e6d3c9a",
                                     fixed: "5303884950392e362d4741e8972ae55fcf43e92f54935279fad752137567555f")
    static let focus = ModelFix(resource: "Focus-fixed.mil",
                                shipped: "a3248e7363130ca8b82599649129334d375a7a241ce5af814e03f2b088c3db23",
                                fixed: "4fad03c389a4a2054326d7f13553ff1054f115ddbbfd9372c9b15f2791de46c2")
    static let shake = ModelFix(resource: "Shake-fixed.mil",
                                shipped: "e9f09bb2d5ceecb1969da8313b1a48b5b834f8fb31d7856bdc557a5c2a2d0a6c",
                                fixed: "f89e18fc192b3bacddc1b4493c94a170389d4eaa1456f414c7618f8b6e99c7d6")
    static let all = [vaeDecoder, vaeEncoder, focus, shake]

    /// The fixed program, if it's in the app as recorded.
    var program: Data? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "lzfse"),
              let packed = NSData(contentsOf: url),
              let program = try? packed.decompressed(using: .lzfse) as Data,
              SHA256.hash(data: program).map({ String(format: "%02x", $0) }).joined() == fixed else { return nil }
        return program
    }

    /// Replaces `model`'s program if it's the one we shipped. A model converted any other way is left alone, and
    /// a failure leaves the model as it was.
    func apply(to model: URL) {
        let file = model.appendingPathComponent("model.mil")
        guard (try? ModelDownloads.sha256(of: file)) == shipped, let program else { return }
        try? program.write(to: file, options: .atomic)
    }
}
