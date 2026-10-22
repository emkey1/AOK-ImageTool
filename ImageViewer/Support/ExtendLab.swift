#if DEBUG
import AppKit

/// `-extendTest <image> <out folder> <x> <y> <width> <height> [match|generate|both] [seed]` (Debug builds):
/// extends one image to that crop (normalized, past 0...1) through the app's own pipeline and writes the
/// fill and the final render, for judging fill quality. Uses temporary storage, like the self-test.
enum ExtendLab {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-extendTest") }

    static func run() async {
        let args = ProcessInfo.processInfo.arguments
        // `-extendTest -background <image> <out.png> "<scene>"`: a background painted around the subject.
        if let i = args.firstIndex(of: "-background"), i + 3 < args.count {
            let url = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            guard let d = try? ImageDecoder.decode(url: url, page: 0, allowHDR: false) else { exit(1) }
            let photo = await VisionServices.downscaled(d.cgImage, maxDimension: 1536)
            let t0 = Date()
            do {
                let mask = try await VisionServices.subjectMask(for: photo)
                let cutout = CIImage(cgImage: photo).applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: photo.width, height: photo.height)),
                    kCIInputMaskImageKey: mask.transformed(by: CGAffineTransform(scaleX: CGFloat(photo.width) / mask.extent.width,
                                                                                 y: CGFloat(photo.height) / mask.extent.height)),
                ])
                let cut = ImageDecoder.ciContext.createCGImage(cutout, from: CGRect(x: 0, y: 0, width: photo.width, height: photo.height))!
                let labels = ImageDescriber.support == .vision ? [] : await VisionServices.classify(cut)
                let subject = ProcessInfo.processInfo.environment["NO_SUBJECT"] != nil ? nil : await ImageDescriber.describeSubject(cut, labels: labels)
                print("subject:", subject ?? "(none)")
                print("prompt:", GenerativeImage.backgroundPrompt(scene: args[i + 3], subject: subject))
                let made = try await GenerativeImage.background(photo, subject: mask, scene: args[i + 3], subjectDescription: subject, seed: 7)
                try ImageWriter.write(made, to: out, format: .png, quality: 1, sourceProperties: [:], metadata: .removeAll)
                print(String(format: "%d×%d in %.1f s", made.width, made.height, Date().timeIntervalSince(t0)))
            } catch {
                print("failed:", error.localizedDescription)
            }
            exit(0)
        }
        // `-extendTest -colorize <image> <out.png>`: a black and white version of the photo, colorized (so the
        // result can be compared with the real colors).
        if let i = args.firstIndex(of: "-colorize"), i + 2 < args.count {
            let url = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            guard let d = try? ImageDecoder.decode(url: url, page: 0, allowHDR: false) else { exit(1) }
            let photo = d.cgImage
            var e = EditState()
            e.blackAndWhite = BlackAndWhite()
            guard let bw = EditRenderer.shared.renderSync(d, edits: e, maxDimension: nil)?.image else { exit(1) }
            let t0 = Date()
            do {
                let made = try await Colorizer.colorize(ProcessInfo.processInfo.environment["AS_IS"] != nil ? photo : bw)
                try ImageWriter.write(made, to: out, format: .png, quality: 1, sourceProperties: [:], metadata: .removeAll)
                print(String(format: "%d×%d in %.1f s", made.width, made.height, Date().timeIntervalSince(t0)))
            } catch {
                print("failed:", error.localizedDescription)
            }
            exit(0)
        }
        // `-extendTest -borders <folder>`: which images have a print border, and the picture inside it.
        if let i = args.firstIndex(of: "-borders"), i + 1 < args.count {
            let folder = URL(fileURLWithPath: args[i + 1])
            let items = (try? FolderScanner.scan(folder: folder, recursive: false, showHidden: false)) ?? []
            for item in items {
                guard let d = try? ImageDecoder.decode(url: item.url, page: 0, allowHDR: false) else { continue }
                let content = await ExtendRenderer.pictureContent(d, edits: EditState())
                if let dump = ProcessInfo.processInfo.environment["BORDER_DUMP"], item.url.lastPathComponent == ProcessInfo.processInfo.environment["BORDER_FILE"],
                   let small = await EditRenderer.shared.render(d, edits: EditState(), maxDimension: 600, stage: .geometry)?.image {
                    print("render", small.width, small.height, small.bitsPerComponent, small.colorSpace?.name as Any, small.alphaInfo.rawValue)
                    try? ImageWriter.write(small, to: URL(fileURLWithPath: dump), format: .png, quality: 1, sourceProperties: [:], metadata: .removeAll)
                }
                print(item.url.lastPathComponent, content.map { String(format: "border → picture %.3f %.3f %.3f %.3f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-")
            }
            exit(0)
        }
        guard let i = args.firstIndex(of: "-extendTest"), i + 6 < args.count,
              let x = Double(args[i + 3]), let y = Double(args[i + 4]), let w = Double(args[i + 5]), let h = Double(args[i + 6]) else {
            print("usage: -extendTest <image> <out folder> <x> <y> <width> <height> [match|generate|both] [seed]")
            exit(2)
        }
        let url = URL(fileURLWithPath: args[i + 1])
        let out = URL(fileURLWithPath: args[i + 2])
        let which = i + 7 < args.count ? args[i + 7] : "both"
        let seed = i + 8 < args.count ? UInt64(args[i + 8]) ?? 1 : 1
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Settings to compare, from the environment.
        let env = ProcessInfo.processInfo.environment
        if let v = env["GUIDANCE"].flatMap(Float.init) { GenerativeExtend.guidance = v }
        if let v = env["STRENGTH"].flatMap(Float.init) { GenerativeExtend.strength = v }
        if let v = env["REFINE_STRENGTH"].flatMap(Float.init) { GenerativeExtend.refineStrength = v }
        if let v = env["REFINE_STEPS"].flatMap(Int.init) { GenerativeExtend.refineSteps = v }
        if let v = env["BAND"].flatMap(Double.init) { GenerativeExtend.bandFraction = CGFloat(v) }
        if let v = env["NEGATIVE_EXTRA"] { GenerativeExtend.negativePrompt += ", " + v }
        if let v = env["ROUGH"].flatMap(GenerativeExtend.RoughStart.init(rawValue:)) { GenerativeExtend.roughStart = v }
        if let v = env["ROUGH_BLUR"].flatMap(Int.init) { GenerativeExtend.roughBlur = v }
        if env["NO_REFINE"] != nil { GenerativeExtend.refines = false }
        let tag = env["TAG"].map { "-" + $0 } ?? ""
        guard let decoded = try? ImageDecoder.decode(url: url, page: 0, allowHDR: false) else {
            print("can't decode \(url.path)")
            exit(1)
        }
        let methods: [ExtendMethod] = which == "both" ? [.match, .generate] : [ExtendMethod(rawValue: which) ?? .match]
        let name = url.deletingPathExtension().lastPathComponent
        if methods.contains(.generate) {
            var plain = EditState()
            plain.crop = CGRect(x: x, y: y, width: w, height: h)
            print("setting:", await ExtendRenderer.settingDescription(decoded, edits: plain) ?? "(none)")
        }
        for method in methods {
            var e = EditState()
            e.crop = CGRect(x: x, y: y, width: w, height: h)
            e.extendSeed = seed
            e.extendMethod = method == .generate ? .generate : nil
            let t0 = Date()
            do {
                let made = try await ExtendRenderer.makeFill(decoded, edits: e)
                e.extendFill = made.extendFill(try ExtendFillStore.save(made.fill))
                guard let full = EditRenderer.shared.renderSync(decoded, edits: e, maxDimension: nil)?.image else { throw ExtendError.failed }
                let file = out.appendingPathComponent("\(name)-\(method.rawValue)-\(seed)\(tag).png")
                try ImageWriter.write(full, to: file, format: .png, quality: 1, sourceProperties: [:], metadata: .removeAll)
                print(String(format: "%@: %d×%d in %.1f s → %@", method.rawValue, full.width, full.height, Date().timeIntervalSince(t0), file.path))
            } catch {
                print("\(method.rawValue): \(error.localizedDescription)")
            }
        }
        try? FileManager.default.removeItem(at: AppStorageLocation.support)
        exit(0)
    }
}
#endif
