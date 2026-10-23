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
            guard let bw = EditRenderer.shared.blackAndWhite(photo, BlackAndWhite()) else { exit(1) }
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
        // `-extendTest -fixBlur <image> <out.png> [focus|shake|none] [faces]`: Fix Blur on the photo. With SHAKE=<pixels>
        // in the environment, the photo is first blurred that much by a simulated camera shake (written to
        // <out>-blurred.png), so the result can be compared with the sharp original.
        if let i = args.firstIndex(of: "-fixBlur"), i + 2 < args.count {
            let url = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            let mode = i + 3 < args.count ? args[i + 3] : "focus"
            let faces = i + 4 < args.count && args[i + 4] == "faces"
            guard let d = try? ImageDecoder.decode(url: url, page: 0, allowHDR: false) else { exit(1) }
            var photo = d.cgImage
            if let shake = ProcessInfo.processInfo.environment["SHAKE"].flatMap(Double.init) {
                let rect = CGRect(x: 0, y: 0, width: photo.width, height: photo.height)
                let blurred = CIImage(cgImage: photo).clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: shake, kCIInputAngleKey: 0.35]).cropped(to: rect)
                photo = ImageDecoder.ciContext.createCGImage(blurred, from: rect, format: .RGBA8, colorSpace: photo.colorSpace)!
                try? ImageWriter.write(photo, to: out.deletingPathExtension().appendingPathExtension("blurred.png"), format: .png, quality: 1,
                                       sourceProperties: [:], metadata: .removeAll)
            }
            var options = BlurFixer.Options()
            options.blur = BlurFixer.Blur(rawValue: mode) ?? .none
            options.faces = faces
            if let s = ProcessInfo.processInfo.environment["FACE_STRENGTH"].flatMap(Double.init) { options.faceStrength = s }
            let t0 = Date()
            do {
                let made = try await BlurFixer.fix(photo, options)
                try ImageWriter.write(made, to: out, format: .png, quality: 1, sourceProperties: [:], metadata: .removeAll)
                print(String(format: "%d×%d in %.1f s", made.width, made.height, Date().timeIntervalSince(t0)))
            } catch {
                print("failed:", error.localizedDescription)
            }
            exit(0)
        }
        // `-extendTest -download <generative-fill|colorize>`: downloads and installs a model (AOK_MODELS_URL and
        // AOK_MODELS_DIR point it at another server and folder).
        if let i = args.firstIndex(of: "-download"), i + 1 < args.count,
           let model = [DownloadableModel.generativeFill, .colorize].first(where: { $0.id == args[i + 1] }) {
            let downloads = ModelDownloads.shared
            let t0 = Date()
            downloads.start(model)
            var last = ""
            while let status = downloads.status[model.id] {
                let line = switch status {
                case .downloading(let f): "downloading \(Int(f * 10) * 10)%"
                case .installing: "installing"
                }
                if line != last { print(line); last = line }
                try? await Task.sleep(for: .milliseconds(200))
            }
            print(downloads.failure[model.id].map { "failed: \($0)" }
                  ?? String(format: "installed: %@ in %.1f s", model.isInstalled() ? "yes" : "NO", Date().timeIntervalSince(t0)))
            exit(model.isInstalled() ? 0 : 1)
        }
        // `-extendTest -upscaleAnimation <in> <out> <scale> [gif|png]`: an animation upscaled, every frame.
        if let i = args.firstIndex(of: "-upscaleAnimation"), i + 3 < args.count, let scale = Double(args[i + 3]),
           let animation = Animation(url: URL(fileURLWithPath: args[i + 1])) {
            let container = i + 4 < args.count ? Animation.Container(rawValue: args[i + 4]) ?? .gif : .gif
            let out = URL(fileURLWithPath: args[i + 2])
            print("\(animation.count) frames \(animation.width)×\(animation.height), loop \(animation.loopCount), delays \(Set(animation.delays).sorted())")
            let t0 = Date()
            do {
                let writer = try Animation.Writer(url: out, container: container, delays: animation.delays, loopCount: animation.loopCount)
                try await SuperResolution.upscaleFrames(count: animation.count, width: animation.width, height: animation.height, scale: scale,
                                                        frame: { animation.frame($0)! }, emit: { writer.add($0) }, progress: { _ in false })
                let t1 = Date()
                try writer.finish()
                let t2 = Date()
                let item = FolderScanner.item(for: out)
                let decoded = try? ImageDecoder.decode(url: out, page: 0, allowHDR: false)
                let thumb = ImageDecoder.thumbnail(url: out, maxPixelSize: 160)
                print(String(format: "timing: frames %.1f s, writing the file %.1f s, then scan + decode + thumbnail %.2f s (%@)",
                             t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), Date().timeIntervalSince(t2),
                             item != nil && decoded != nil && thumb != nil ? "ok" : "failed"))
                if let made = Animation(url: out) {
                    let a = made.frame(0)!, b = made.frame(made.count / 2)!
                    print(String(format: "made %d frames %d×%d, loop %d, delays %@ in %.1f s; frames differ: %@", made.count, made.width, made.height,
                                 made.loopCount, "\(Set(made.delays).sorted())", Date().timeIntervalSince(t0),
                                 a.dataProvider?.data as Data? != b.dataProvider?.data as Data? ? "yes" : "NO"))
                }
            } catch {
                print("failed:", error.localizedDescription)
            }
            exit(0)
        }
        // `-extendTest -seedTest <image>`: a thumbnail seeded from a picture is there to read straight away.
        if let i = args.firstIndex(of: "-seedTest"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            guard let d = try? ImageDecoder.decode(url: url, page: 0, allowHDR: false) else { exit(1) }
            let probe = FileManager.default.temporaryDirectory.appendingPathComponent("probe.gif")
            ThumbnailCache.shared.seed(d.cgImage, for: probe)
            let small = ThumbnailCache.shared.cached(probe, tier: .small), large = ThumbnailCache.shared.cached(probe, tier: .large)
            print("small \(small.map { "\($0.width)×\($0.height)" } ?? "none"), large \(large.map { "\($0.width)×\($0.height)" } ?? "none")")
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
        let tag = ProcessInfo.processInfo.environment["TAG"].map { "-" + $0 } ?? ""
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
