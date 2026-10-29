#if DEBUG
import AppKit
import Vision
import CoreImage
import ImageIO
import Photos
import Security
import UniformTypeIdentifiers

/// Headless pipeline checks: `AOK-ImageTool -selfTest <folder>`. Debug builds only.
enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-selfTest") }

    private static var failures = 0

    private static func check(_ ok: Bool, _ message: String) {
        print(ok ? "  ✓ \(message)" : "  ✗ \(message)")
        if !ok { failures += 1 }
    }

    /// For looking at a result afterwards (in the output folder).
    private static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Remove Objects: the boat taken off the lake by each fill; a patch changes only what it covers.
    /// (`AOK_SELFTEST_ONLY=remove` runs just these.)
    private static func removeObjectsChecks(_ boat: DecodedImage, out: URL) async {
        func rgbaPixels(_ image: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return px
        }
        let size = boat.pixelSize
        let frame = CGRect(origin: .zero, size: size)
        // The boat and its reflection (Core Image coordinates, y up).
        let marked = CGRect(x: size.width * 0.49, y: size.height * 0.25, width: size.width * 0.38, height: size.height * 0.19).integral
        let mask = CIImage(color: .white).cropped(to: marked).composited(over: CIImage(color: .black).cropped(to: frame))
        func render(_ e: EditState) -> CGImage? { EditRenderer.shared.renderSync(boat, edits: e, maxDimension: nil)?.image }
        /// Of the marked area: the share of blue pixels (the boat; the water around it is the sunset's orange).
        func whiteness(_ image: CGImage) -> Double {
            let area = CGRect(x: marked.minX, y: size.height - marked.maxY, width: marked.width, height: marked.height)
            guard let part = image.cropping(to: area) else { return 1 }
            let px = rgbaPixels(part)
            let n = px.count / 4
            let white = (0..<n).filter { i in
                let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
                _ = g
                return b > r + 30
            }.count
            return Double(white) / Double(max(n, 1))
        }
        func corner(_ image: CGImage) -> [UInt8] { image.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 96)).map(rgbaPixels) ?? [] }
        func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
        if let plain = render(.identity) {
            let before = whiteness(plain)
            check(before > 0.04, "the marked area holds the boat (\(percent(before)) of it blue)")
            var methods: [RemovalMethod] = [.match]
            if RemovalModel.isInstalled { methods.insert(.erase, at: 0) } else { print("  • removal model not installed; skipping Erase") }
            for method in methods {
                let started = Date()
                do {
                    let removal = try await ObjectRemover.remove(boat, after: [], mask: mask, grow: 6, method: method, seed: 7)
                    let seconds = Date().timeIntervalSince(started)
                    var e = EditState()
                    e.removals = [removal]
                    guard let removed = render(e) else { throw RemovalError.failed }
                    let after = whiteness(removed)
                    writeJPEG(removed, to: out.appendingPathComponent("removed-\(method.rawValue).jpg"))
                    let patch = EditRenderer.pixelRect(removal.rect, in: frame)
                    check(after < 0.01 && corner(removed) == corner(plain) && patch.contains(marked) && e.referencedFilesExist,
                          "\(method.title) removes the boat (blue \(percent(before)) → \(percent(after))) in \(String(format: "%.1f", seconds)) s; the rest is untouched")
                    if method == .match {
                        // A second removal builds on the first; undoing (dropping it) leaves the first.
                        let top = CGRect(x: size.width * 0.1, y: size.height * 0.8, width: size.width * 0.1, height: size.height * 0.08).integral
                        let second = try await ObjectRemover.remove(boat, after: [removal], mask: CIImage(color: .white).cropped(to: top)
                            .composited(over: CIImage(color: .black).cropped(to: frame)), grow: 4, method: .match, seed: 2)
                        var both = e
                        both.removals = [removal, second]
                        let data = try JSONEncoder().encode(both)
                        check(try JSONDecoder().decode(EditState.self, from: data) == both && render(both).map(whiteness) ?? 1 < 0.01,
                              "removals stack up, and are kept with the edits")
                        var gone = both
                        gone.removals?[1].path = out.appendingPathComponent("missing.png").path
                        check(!gone.referencedFilesExist, "edits whose patch is gone are noticed (a photo edited on another Mac)")
                    }
                } catch {
                    check(false, "\(method.title) removes the boat: \(error.localizedDescription)")
                }
            }
            // Generate replaces: it needs to be told with what.
            do {
                _ = try await ObjectRemover.remove(boat, after: [], mask: mask, grow: 6, method: .generate, seed: 7, prompt: " ")
                check(false, "Generate without a description is refused")
            } catch RemovalError.noDescription {
                check(true, "Generate without a description is refused")
            } catch {
                check(false, "Generate without a description is refused (\(error.localizedDescription))")
            }
            if GenerativeModel.isInstalled {
                let started = Date()
                do {
                    let removal = try await ObjectRemover.remove(boat, after: [], mask: mask, grow: 6, method: .generate, seed: 7,
                                                                 prompt: "a small red wooden rowing boat")
                    var e = EditState()
                    e.removals = [removal]
                    guard let made = render(e) else { throw RemovalError.failed }
                    writeJPEG(made, to: out.appendingPathComponent("removed-generate.jpg"))
                    /// Mean difference from the original over the marked area.
                    func change(_ a: CGImage, _ b: CGImage) -> Double {
                        let area = CGRect(x: marked.minX, y: size.height - marked.maxY, width: marked.width, height: marked.height)
                        guard let pa = a.cropping(to: area).map(rgbaPixels), let pb = b.cropping(to: area).map(rgbaPixels) else { return 0 }
                        return Double(zip(pa, pb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(max(pa.count, 1))
                    }
                    let changed = change(made, plain)
                    check(changed > 8 && corner(made) == corner(plain),
                          String(format: "Generate paints something new there (changed by %.0f) in %.0f s; the rest is untouched", changed, Date().timeIntervalSince(started)))
                } catch {
                    check(false, "Generate paints a description: \(error.localizedDescription)")
                }
            } else {
                print("  • generative model not installed; skipping Generate")
            }
        }
        // A mark drawn over the image turned and flipped lands where it was drawn on the image itself.
        if let maskImage = ImageDecoder.ciContext.createCGImage(mask, from: frame) {
            let maskDecoded = DecodedImage(url: out.appendingPathComponent("mask.png"), cgImage: maskImage, isHDR: false, isAnimated: false,
                                           pageCount: 1, pageIndex: 0, typeIdentifier: nil, properties: [:], sourceOrientation: .up, isVector: false)
            var ok = true
            for (turns, flip) in [(1, true), (2, false), (3, false), (0, true)] {
                var turned = EditState()
                turned.quarterTurns = turns
                turned.flipHorizontal = flip
                let shown = EditRenderer.shared.makeImage(maskDecoded, edits: turned, maxDimension: 1024, stage: .full)
                let back = ObjectRemover.sourceMask(shown, shownWith: turned, size: size)
                guard let b = VisionServices.maskBounds(back, imageSize: size) else { ok = false; continue }
                let tolerance = size.width * 0.012
                if abs(b.minX - marked.minX) > tolerance || abs(b.maxX - marked.maxX) > tolerance
                    || abs(b.minY - marked.minY) > tolerance || abs(b.maxY - marked.maxY) > tolerance { ok = false }
            }
            check(ok, "marks made on a turned or flipped image map back onto it")
        }
        // Done: a copy stacked on the original, or (copies off) an edit.
        let fm = FileManager.default
        let folder = out.appendingPathComponent("retouch")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Boat.heic")
        try? fm.copyItem(at: boat.url, to: file)
        let model = ViewerModel()
        model.stacksEnabled = true
        model.openFolder(folder, selecting: file)
        for _ in 0..<100 where model.decoded?.url != file.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
        if let d = model.decoded, let removal = try? await ObjectRemover.remove(d, after: [], mask: mask, grow: 6, method: .match, seed: 7) {
            model.finishRemovingObjects([removal], url: file.standardizedFileURL, decoded: d)
            let copy = folder.appendingPathComponent("Boat (Retouched).heic")
            for _ in 0..<300 where !fm.fileExists(atPath: copy.path) || model.items.count < 1 { try? await Task.sleep(for: .milliseconds(100)) }
            check(fm.fileExists(atPath: copy.path) && ImageStacks.source(of: copy) == "Boat.heic" && model.edits[file.standardizedFileURL] == nil,
                  "Done saves “Boat (Retouched)”, stacked on the original, which stays as it was")
            Prefs.setBool(false, CopyOperation.removeObjects.key)
            model.select(file.standardizedFileURL)
            for _ in 0..<100 where model.decoded?.url != file.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
            model.finishRemovingObjects([removal], url: file.standardizedFileURL, decoded: d)
            check(model.edits[file.standardizedFileURL]?.removals == [removal], "with copies off, the removal is an edit of the image")
        } else {
            check(false, "a removal for Done")
        }
    }

    /// Change Objects: instructions read as a color or a description; a click selects what's that color; a color
    /// is changed keeping its shading, partly with less strength; Done saves “(Changed)”.
    /// (`AOK_SELFTEST_ONLY=change` runs just these.)
    private static func changeObjectsChecks(_ boat: DecodedImage, out: URL) async {
        func rgbaPixels(_ image: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return px
        }
        // Reading instructions (without Apple Intelligence).
        let blue = ChangeRequest.colors["blue"]!, green = ChangeRequest.colors["green"]!
        func brightness(_ c: ChangeRequest.Color?) -> Int { c.map { Int($0.red) + Int($0.green) + Int($0.blue) } ?? -1 }
        let colorCases: [(String, ChangeRequest.Color?)] = [
            ("Change his shirt to be blue", blue), ("Make her dress red.", ChangeRequest.colors["red"]), ("navy blue", ChangeRequest.colors["navy blue"]),
            ("change the car to light blue please", ChangeRequest.colors["light blue"]), ("Make her leather jacket black", ChangeRequest.colors["black"]),
        ]
        let colorsRead = colorCases.filter { ChangeRequest.parse($0.0).color != $0.1 }.map(\.0)
        check(colorsRead.isEmpty, "instructions that end on a color are read as that color\(colorsRead.isEmpty ? "" : ": not \(colorsRead)")")
        let describedCases = ["Change his shirt to a red plaid shirt", "make it a blue jacket", "Change it to plaid red", "make her dress red with white dots"]
        let described = describedCases.filter { ChangeRequest.parse($0).color != nil }
        check(described.isEmpty && ChangeRequest.parse(describedCases[0]).description == "a red plaid shirt",
              "anything more than a color is a description for the generative model\(described.isEmpty ? "" : ": not \(described)")")
        let dark = ChangeRequest.parse("make it dark green").color, light = ChangeRequest.parse("pale green").color
        check(brightness(dark) < brightness(green) && brightness(light) > brightness(green), "dark and pale shades")
        let plaid = ChangeRequest.parse("make it a red plaid flannel shirt")
        check(plaid.color == nil && plaid.tint == ChangeRequest.colors["red"] && ChangeRequest.parse("a navy blue blazer").tint == ChangeRequest.colors["navy blue"],
              "a description that names a color starts from it (“\(plaid.description)”)")

        // Selecting by color: of what's marked, what's the color clicked, its shading too.
        let pickSize = CGSize(width: 400, height: 200)
        let left = CGRect(x: 0, y: 0, width: 200, height: 200), all = CGRect(origin: .zero, size: pickSize)
        let shadedRed = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 200),
            "inputColor0": CIColor(red: 0.45, green: 0.06, blue: 0.06), "inputColor1": CIColor(red: 0.9, green: 0.22, blue: 0.2),
        ])!.outputImage!.cropped(to: left)
        // (With a gray band across the red, as a strand of hair over a shirt.)
        let band = CGRect(x: 120, y: 0, width: 30, height: 200)
        let picture = CIImage(color: CIColor(red: 0.55, green: 0.53, blue: 0.5)).cropped(to: band)
            .composited(over: shadedRed).composited(over: CIImage(color: CIColor(red: 0.15, green: 0.55, blue: 0.2)).cropped(to: all))
        let everything = CIImage(color: .white).cropped(to: all)
        func coverage(_ mask: CIImage, in rect: CGRect) -> Double {
            let px = ImageDecoder.ciContext.renderGray(mask, bounds: rect)
            return Double(px.filter { $0 > 127 }.count) / Double(max(px.count, 1))
        }
        do {
            let red = try ObjectRemover.selectByColor(in: picture, mask: everything, seed: CGPoint(x: 0.25, y: 0.5))
            let greenPart = try ObjectRemover.selectByColor(in: picture, mask: everything, seed: CGPoint(x: 0.75, y: 0.5))
            // A stroke mostly over the red: its color.
            let stroke = try ObjectRemover.selectByColor(in: picture, mask: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 260, height: 200)), seed: nil)
            let right = CGRect(x: 200, y: 0, width: 200, height: 200)
            let redPart = CGRect(x: 0, y: 0, width: 110, height: 200), inBand = band.insetBy(dx: 4, dy: 0)
            let r = (coverage(red, in: redPart), coverage(red, in: right)), g = (coverage(greenPart, in: left), coverage(greenPart, in: right))
            check(r.0 > 0.95 && r.1 < 0.02 && coverage(red, in: inBand) < 0.05 && g.0 < 0.02 && g.1 > 0.95
                  && coverage(stroke, in: redPart) > 0.95 && coverage(stroke, in: right) < 0.02,
                  String(format: "a click selects what's the color clicked, light and shadow (%.0f%%), not a gray strand across it (%.0f%%) or the rest (%.0f%%); a stroke, the color it mostly covers",
                         r.0 * 100, coverage(red, in: inBand) * 100, r.1 * 100))
        } catch {
            check(false, "selecting by color: \(error.localizedDescription)")
        }

        // Recoloring the (blue) sky red: red, with its gradient kept; nothing else changed; less with less strength.
        let size = boat.pixelSize
        let frame = CGRect(origin: .zero, size: size)
        let sky = CGRect(x: size.width * 0.05, y: size.height * 0.62, width: size.width * 0.3, height: size.height * 0.25).integral
        let mask = CIImage(color: .white).cropped(to: sky).composited(over: CIImage(color: .black).cropped(to: frame))
        func render(_ e: EditState) -> CGImage? { EditRenderer.shared.renderSync(boat, edits: e, maxDimension: nil)?.image }
        let area = CGRect(x: sky.minX + 8, y: size.height - sky.maxY + 8, width: sky.width - 16, height: sky.height - 16)
        func stats(_ image: CGImage) -> (red: Double, spread: Double, pixels: [UInt8]) {
            let px = image.cropping(to: area).map(rgbaPixels) ?? []
            let n = max(px.count / 4, 1)
            var reds = 0
            var lum = [Double]()
            for i in 0..<n {
                let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
                if r > b + 30 { reds += 1 }
                lum.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
            let mean = lum.reduce(0, +) / Double(n)
            return (Double(reds) / Double(n), (lum.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(n)).squareRoot(), px)
        }
        func corner(_ image: CGImage) -> [UInt8] { image.cropping(to: CGRect(x: image.width - 96, y: image.height - 96, width: 96, height: 96)).map(rgbaPixels) ?? [] }
        if let plain = render(.identity) {
            do {
                let before = stats(plain)
                let change = try await ObjectRemover.recolor(boat, after: [], mask: mask, color: ChangeRequest.colors["red"]!)
                var e = EditState()
                e.removals = [change]
                guard let changed = render(e) else { throw RemovalError.failed }
                writeJPEG(changed, to: out.appendingPathComponent("changed-sky-red.jpg"))
                let after = stats(changed)
                check(before.red < 0.2 && after.red > 0.9 && after.spread > 0.4 * before.spread && corner(changed) == corner(plain),
                      String(format: "a color change turns the sky red (%.0f%% → %.0f%% red), its gradient kept (spread %.0f → %.0f); the rest untouched",
                             before.red * 100, after.red * 100, before.spread, after.spread))
                e.removals?[0].opacity = 0.5
                guard let half = render(e) else { throw RemovalError.failed }
                func difference(_ a: [UInt8], _ b: [UInt8]) -> Double { Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(max(a.count, 1)) }
                let full = difference(after.pixels, before.pixels), partly = difference(stats(half).pixels, before.pixels)
                check(partly > 0.25 * full && partly < 0.8 * full,
                      String(format: "at half strength, it changes about half as much (%.0f of %.0f)", partly, full))
                if GenerativeModel.isInstalled {
                    let started = Date()
                    let painted = try await ObjectRemover.remove(boat, after: [], mask: mask, grow: 4, method: .generate, seed: 7,
                                                                 prompt: "a stormy sky with dark grey clouds", keepShape: true,
                                                                 tint: ChangeRequest.colors["dark gray"])
                    var g = EditState()
                    g.removals = [painted]
                    guard let made = render(g) else { throw RemovalError.failed }
                    writeJPEG(made, to: out.appendingPathComponent("changed-sky-generated.jpg"))
                    let moved = difference(stats(made).pixels, before.pixels)
                    check(moved > 8 && corner(made) == corner(plain),
                          String(format: "a description is painted over what's there (changed by %.0f) in %.0f s; the rest untouched", moved, Date().timeIntervalSince(started)))
                } else {
                    print("  • generative model not installed; skipping a described change")
                }
            } catch {
                check(false, "changing the sky's color: \(error.localizedDescription)")
            }
        }

        // Around a recolored thing: skin beside a brown jacket stays skin; a strand-like mix of the jacket and gray changes.
        do {
            let w = 120, h = 60
            var px = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let c: (UInt8, UInt8, UInt8) = x < 60 ? (110, 70, 45) : x < 64 ? (150, 130, 120) : (225, 180, 150)   // jacket, a mix, skin
                    px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2
                }
            }
            guard let provider = CGDataProvider(data: Data(px) as CFData),
                  let made = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RemovalError.failed }
            let scene = DecodedImage(url: out.appendingPathComponent("jacket.png"), cgImage: made, isHDR: false, isAnimated: false, pageCount: 1,
                                     pageIndex: 0, typeIdentifier: nil, properties: [:], sourceOrientation: .up, isVector: false)
            let all = CGRect(x: 0, y: 0, width: w, height: h)
            let jacket = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 60, height: h)).composited(over: CIImage(color: .black).cropped(to: all))
            let person = CIImage(color: .white).cropped(to: all)
            let change = try await ObjectRemover.recolor(scene, after: [], mask: jacket, reach: person, color: blue)
            var e = EditState()
            e.removals = [change]
            guard let after = EditRenderer.shared.renderSync(scene, edits: e, maxDimension: nil)?.image else { throw RemovalError.failed }
            var out = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(after, in: all)
            func at(_ x: Int) -> [Int] { let i = (30 * w + x) * 4; return [Int(out[i]), Int(out[i + 1]), Int(out[i + 2])] }
            let skin = at(100), mix = at(62), coat = at(20)
            check(abs(skin[0] - 225) + abs(skin[1] - 180) + abs(skin[2] - 150) <= 6 && mix[2] > mix[0] && coat[2] > coat[0] + 40,
                  "recoloring a jacket blue leaves skin beside it alone (\(skin)) and changes a mix of it and gray (\(mix))")
        } catch {
            check(false, "recoloring beside skin: \(error.localizedDescription)")
        }

        // Done: “(Changed)”, stacked on the original, or (copies off) an edit.
        let fm = FileManager.default
        let folder = out.appendingPathComponent("change")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Boat.heic")
        try? fm.copyItem(at: boat.url, to: file)
        let model = ViewerModel()
        model.stacksEnabled = true
        model.openFolder(folder, selecting: file)
        for _ in 0..<100 where model.decoded?.url != file.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
        if let d = model.decoded, let change = try? await ObjectRemover.recolor(d, after: [], mask: mask, color: blue) {
            model.finishRemovingObjects([change], url: file.standardizedFileURL, decoded: d, operation: .changeObjects)
            let copy = folder.appendingPathComponent("Boat (Changed).heic")
            for _ in 0..<300 where !fm.fileExists(atPath: copy.path) { try? await Task.sleep(for: .milliseconds(100)) }
            check(fm.fileExists(atPath: copy.path) && ImageStacks.source(of: copy) == "Boat.heic" && model.edits[file.standardizedFileURL] == nil,
                  "Done saves “Boat (Changed)”, stacked on the original, which stays as it was")
            Prefs.setBool(true, CopyOperation.removeObjects.key)
            Prefs.setBool(false, CopyOperation.changeObjects.key)
            model.select(file.standardizedFileURL)
            for _ in 0..<100 where model.decoded?.url != file.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
            model.finishRemovingObjects([change], url: file.standardizedFileURL, decoded: d, operation: .changeObjects)
            check(model.edits[file.standardizedFileURL]?.removals == [change] && Prefs.makesCopy(.removeObjects),
                  "with Change Objects' copies off, the change is an edit of the image (Remove Objects' setting is its own)")
        } else {
            check(false, "a change for Done")
        }
    }

    /// Clone & Heal: a point marked on the image as shown lands where masks do; Copy copies; Heal keeps what's
    /// copied's detail in the color around where it goes. (`AOK_SELFTEST_ONLY=clone` runs just these.)
    private static func cloneHealChecks(out: URL) async {
        // Points map as masks do, however the image is turned and flipped.
        let size = CGSize(width: 400, height: 300)
        var mapped = true
        for turns in 0..<4 {
            for (flipH, flipV) in [(false, false), (true, false), (false, true)] {
                var e = EditState()
                e.quarterTurns = turns
                e.flipHorizontal = flipH
                e.flipVertical = flipV
                let shown = turns % 2 == 1 ? CGSize(width: 300, height: 400) : size
                let p = CGPoint(x: shown.width * 0.3, y: shown.height * 0.8)
                let spot = CIImage(color: .white).cropped(to: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                    .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: shown)))
                let q = ObjectRemover.sourcePoint(p, shownWith: e, shown: shown, size: size)
                guard let b = VisionServices.maskBounds(ObjectRemover.sourceMask(spot, shownWith: e, size: size), imageSize: size),
                      hypot(b.midX - q.x, b.midY - q.y) < 3 else { mapped = false; continue }
            }
        }
        check(mapped, "where to copy from maps onto the image however it's turned and flipped")

        // A picture: textured orange on the left, smooth blue on the right.
        let w = 400, h = 300
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt32 = 12345
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if x < 200 {
                    seed = seed &* 1664525 &+ 1013904223
                    let n = Int(seed >> 24) / 4 - 32   // ±32
                    px[i] = UInt8(clamping: 230 + n); px[i + 1] = UInt8(clamping: 130 + n); px[i + 2] = UInt8(clamping: 40 + n / 2)
                } else {
                    px[i] = 30; px[i + 1] = UInt8(60 + y / 10); px[i + 2] = 140
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let made = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            return check(false, "a picture for Clone & Heal")
        }
        let picture = DecodedImage(url: out.appendingPathComponent("clone.png"), cgImage: made, isHDR: false, isAnimated: false,
                                   pageCount: 1, pageIndex: 0, typeIdentifier: nil, properties: [:], sourceOrientation: .up, isVector: false)
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        // A dab on the blue (Core Image coordinates), copied from the orange 200 px to its left.
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 270, y: 120, width: 60, height: 60)).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])
            .composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame)
        func stats(_ image: CGImage, _ r: CGRect) -> (mean: [Double], spread: Double) {
            var p = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &p, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var sums = [0.0, 0.0, 0.0], greens = [Double]()
            for y in Int(r.minY)..<Int(r.maxY) {
                for x in Int(r.minX)..<Int(r.maxX) {
                    let i = ((image.height - 1 - y) * image.width + x) * 4   // (rows top-down; `r` is y-up)
                    for c in 0..<3 { sums[c] += Double(p[i + c]) }
                    greens.append(Double(p[i]))
                }
            }
            let n = Double(greens.count), m = greens.reduce(0, +) / n
            return (sums.map { $0 / n }, (greens.map { ($0 - m) * ($0 - m) }.reduce(0, +) / n).squareRoot())
        }
        func render(_ removal: Removal) -> CGImage? {
            var e = EditState()
            e.removals = [removal]
            return EditRenderer.shared.renderSync(picture, edits: e, maxDimension: nil)?.image
        }
        let inside = CGRect(x: 285, y: 135, width: 30, height: 30), around = CGRect(x: 250, y: 100, width: 100, height: 12)
        do {
            guard let copied = try await render(ObjectRemover.clone(picture, after: [], mask: mask, offset: CGVector(dx: -200, dy: 0), heal: false)),
                  let healed = try await render(ObjectRemover.clone(picture, after: [], mask: mask, offset: CGVector(dx: -200, dy: 0), heal: true)),
                  let plain = EditRenderer.shared.renderSync(picture, edits: EditState(), maxDimension: nil)?.image else { throw RemovalError.failed }
            writeJPEG(healed, to: out.appendingPathComponent("healed.jpg"))
            let c = stats(copied, inside), hl = stats(healed, inside), ring = stats(plain, around), orange = stats(plain, CGRect(x: 85, y: 135, width: 30, height: 30))
            func distance(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
            check(distance(c.mean, orange.mean) < 6 && c.spread > 10,
                  String(format: "Copy copies what's there (%.0f from the orange it copied, texture %.0f)", distance(c.mean, orange.mean), c.spread))
            check(distance(hl.mean, ring.mean) < 16 && hl.spread > 8 && stats(healed, CGRect(x: 0, y: 0, width: 40, height: 40)).mean == stats(plain, CGRect(x: 0, y: 0, width: 40, height: 40)).mean,
                  String(format: "Heal keeps its texture (%.0f) in the color around it (%.0f from the blue around; copied, %.0f); the rest untouched",
                         hl.spread, distance(hl.mean, ring.mean), distance(c.mean, ring.mean)))
        } catch {
            check(false, "Clone & Heal: \(error.localizedDescription)")
        }
    }

    /// White balance: the eyedropper makes what's clicked neutral (on a cropped photo too); Auto takes a cast out
    /// of a photo with something neutral in it, and leaves one with nothing neutral alone; presets go the right
    /// way. (`AOK_SELFTEST_ONLY=wb` runs just these.)
    private static func whiteBalanceChecks(out: URL) async {
        /// A picture whose top-down rows are filled by `color(x, y)` (sRGB bytes).
        func picture(_ name: String, width w: Int = 300, height h: Int = 200, _ color: (Int, Int) -> (Int, Int, Int)) -> DecodedImage? {
            var px = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let c = color(x, y), i = (y * w + x) * 4
                    px[i] = UInt8(clamping: c.0); px[i + 1] = UInt8(clamping: c.1); px[i + 2] = UInt8(clamping: c.2)
                }
            }
            guard let provider = CGDataProvider(data: Data(px) as CFData),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            return DecodedImage(url: out.appendingPathComponent(name), cgImage: image, isHDR: false, isAnimated: false, pageCount: 1, pageIndex: 0,
                                typeIdentifier: nil, properties: [:], sourceOrientation: .up, isVector: false)
        }
        /// The rendered color (sRGB) at `p` (normalized, top-left origin) of `d` with `e`.
        func color(_ d: DecodedImage, _ e: EditState, at p: CGPoint) -> [Int] {
            guard let image = EditRenderer.shared.renderSync(d, edits: e, maxDimension: nil)?.image else { return [] }
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: -p.x * CGFloat(image.width) + 0.5, y: -(1 - p.y) * CGFloat(image.height) + 0.5,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
            return px.prefix(3).map(Int.init)
        }
        func spread(_ c: [Int]) -> Int { (c.max() ?? 0) - (c.min() ?? 0) }
        func balanced(_ e: EditState, _ b: (temperature: Double, tint: Double)?) -> EditState {
            var e = e
            e.temperature = b?.temperature ?? 0
            e.tint = b?.tint ?? 0
            return e
        }
        // The eyedropper: warm gray on the left, red on the right.
        if let d = picture("wb-pick.png", { x, _ in x < 150 ? (205, 180, 140) : (200, 30, 30) }) {
            let pick = await WhiteBalance.neutral(d, edits: EditState(), at: CGPoint(x: 0.25, y: 0.5))
            let after = color(d, balanced(EditState(), pick.map { ($0.temperature, $0.tint) }), at: CGPoint(x: 0.25, y: 0.5))
            check(spread(after) <= 4, "the eyedropper makes what's clicked neutral: warm gray \(color(d, EditState(), at: CGPoint(x: 0.25, y: 0.5))) → \(after)")
        }
        // On a cropped photo, where it's clicked: warm gray on top, cool gray below, cropped to the bottom half.
        if let d = picture("wb-crop.png", { _, y in y < 100 ? (205, 180, 140) : (160, 172, 196) }) {
            var e = EditState()
            e.crop = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
            let pick = await WhiteBalance.neutral(d, edits: e, at: CGPoint(x: 0.5, y: 0.5))
            let after = color(d, balanced(e, pick.map { ($0.temperature, $0.tint) }), at: CGPoint(x: 0.5, y: 0.5))
            check(spread(after) <= 4 && (pick?.temperature ?? 0) > 0, "on a cropped photo, the eyedropper goes by what's clicked (cool gray → \(after))")
        }
        // Auto: a scene with a warm cast (a gray wall, a red chair, a green plant, texture) and one with nothing neutral.
        var seed: UInt32 = 7
        func noise() -> Int {
            seed = seed &* 1664525 &+ 1013904223
            return Int(seed >> 27) - 16
        }
        if let d = picture("wb-auto.png", { x, y in
            let n = noise()
            if x < 90 && y > 120 { return (190 + n, 40 + n, 30 + n) }   // the chair
            if x > 220 && y < 80 { return (60 + n, 150 + n, 40 + n) }   // the plant
            return (210 + n, 185 + n, 145 + n)                        // the wall, warm
        }) {
            let b = await WhiteBalance.auto(d, edits: EditState())
            let wall = color(d, balanced(EditState(), b), at: CGPoint(x: 0.5, y: 0.5))
            check(spread(wall) <= 12 && (b?.temperature ?? 0) < 0,
                  "Auto takes a warm cast out (\(b.map { String(format: "Warmth %+.2f, Tint %+.2f", $0.temperature, $0.tint) } ?? "nothing")): the wall \(wall)")
        }
        if let d = picture("wb-colorful.png", { x, _ in x < 100 ? (220, 40, 30) : x < 200 ? (30, 180, 40) : (30, 60, 220) }) {
            let b = await WhiteBalance.auto(d, edits: EditState())
            check(b == nil, "Auto leaves a photo with nothing neutral in it alone")
        }
        // Skin: natural skin is left alone; skin with a cast is brought back.
        func skin(_ r: Int, _ g: Int, _ b: Int) -> CIImage {
            CIImage(color: CIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1,
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        func hue(_ img: CIImage) -> Double {
            var px = [Float](repeating: 0, count: 4)
            EditRenderer.shared.context.render(img, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return Double(atan2(log(px[2] / px[1]), log(px[0] / px[1]))) * 180 / .pi
        }
        let natural = WhiteBalance.solve(skin(194, 150, 130), target: .skin)   // the ColorChecker's light skin
        let ghostly = skin(170, 165, 160)
        if let fixed = WhiteBalance.solve(ghostly, target: .skin) {
            let after = hue(WhiteBalance.apply(ghostly, temperature: fixed.temperature, tint: fixed.tint))
            check(natural.map { $0.temperature == 0 && $0.tint == 0 } == true && fixed.temperature > 0.2 && (-40 ... -12).contains(after),
                  String(format: "on a face, natural skin is left alone, and grayish skin is warmed to a natural hue (%.0f° → %.0f°)", hue(ghostly), after))
        } else {
            check(false, "on a face, skin is balanced")
        }

        let lamps = WhiteBalance.Light.lamps.setting, shade = WhiteBalance.Light.shade.setting, fluorescent = WhiteBalance.Light.fluorescent.setting
        check(lamps.temperature < 0 && shade.temperature > 0 && fluorescent.tint > 0,
              "presets: Indoor Lamps cools, Shade warms, Fluorescent takes green out")
    }

    /// New Image from Description: titles and prompts; a preview in each shape's proportions, and the one kept
    /// finished at 2048 px (when the model is installed); saved into the folder under its title.
    /// (`AOK_SELFTEST_ONLY=newimage` runs just these.)
    private static func newImageChecks(out: URL) async {
        check(GenerativeImage.title(for: "a lighthouse on a rocky coast at sunset.") == "Lighthouse on a rocky coast at sunset"
              && GenerativeImage.title(for: "  ") == "New Image" && GenerativeImage.title(for: "cats/dogs: a story") == "Cats dogs a story",
              "a new image is named after its description")
        check(GenerativeImage.picturePrompt("a red fox").hasPrefix("a high quality photo of a red fox")
              && !GenerativeImage.picturePrompt("a watercolor of a sailboat").contains("photo of"),
              "a description is painted as a photo, unless it says it's another kind of picture")
        check(GenerativeImage.Shape.allCases.allSatisfy { s in
            let (w, h) = s.workingSize
            return min(w, h) == GenerativeExtend.window && w % 8 == 0 && h % 8 == 0
        } && GenerativeImage.Shape.wide.workingSize.width == 904, "each shape is painted with 512 on its short side")
        var made: CGImage?
        if GenerativeModel.isInstalled {
            do {
                let started = Date()
                let preview = try await GenerativeImage.picture("a red fox sitting in fresh snow", shape: .landscape, seed: 5)
                let previewTime = Date().timeIntervalSince(started)
                let finished = try await GenerativeImage.finished(preview, description: "a red fox sitting in fresh snow", seed: 5)
                writeJPEG(finished, to: out.appendingPathComponent("new-image.jpg"))
                /// How much the picture varies (0 for a blank one).
                func spread(_ image: CGImage) -> Double {
                    let stats = CIImage(cgImage: image).applyingFilter("CIAreaMinMaxRed", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: 0, y: 0, width: image.width, height: image.height))])
                    var px = [UInt8](repeating: 0, count: 4)
                    ImageDecoder.ciContext.render(stats, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
                    return Double(px[1]) - Double(px[0])
                }
                check(preview.width == 768 && preview.height == 512 && max(finished.width, finished.height) == 2048
                      && abs(Double(finished.width) / Double(finished.height) - 1.5) < 0.01 && spread(finished) > 100,
                      String(format: "a preview is painted (768×512 in %.0f s) and finished at %d×%d, in %.0f s in all", previewTime,
                             finished.width, finished.height, Date().timeIntervalSince(started)))
                made = finished
            } catch {
                check(false, "painting a new image: \(error.localizedDescription)")
            }
        } else {
            print("  • generative model not installed; skipping painting a new image")
        }
        // Kept: saved into the folder under its title, and shown.
        let fm = FileManager.default
        let folder = out.appendingPathComponent("new-image")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = ViewerModel()
        model.openFolder(folder, selecting: nil)
        for _ in 0..<40 where model.folderURL == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let picture = made ?? CIContext().createCGImage(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)),
                                                       from: CGRect(x: 0, y: 0, width: 64, height: 64))
        if let picture {
            model.saveNewImage(picture, description: "a red fox sitting in fresh snow")
            let saved = folder.appendingPathComponent("Red fox sitting in fresh snow.heic")
            for _ in 0..<40 where model.currentURL != saved.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
            check(fm.fileExists(atPath: saved.path) && model.currentURL == saved.standardizedFileURL,
                  "Keep saves “Red fox sitting in fresh snow.heic” into the folder and shows it")
        }
    }

    /// Shot Quality and Best Shots in a folder with stacks: a picture is scored on its own before the folder is
    /// analyzed, every shown picture (stacks' top copies too) after, and a copy made later is scored by itself.
    /// (`AOK_SELFTEST_ONLY=quality` runs just these.)
    private static func shotQualityChecks(folder: URL, out: URL) async {
        let fm = FileManager.default
        let qfolder = out.appendingPathComponent("quality")
        try? fm.createDirectory(at: qfolder, withIntermediateDirectories: true)
        for name in ["Mountain Lake.heic", "Red Fox.heic", "Sailboat.heic", "Sunflowers.heic", "sale-sign.jpg"] {
            try? fm.copyItem(at: folder.appendingPathComponent(name), to: qfolder.appendingPathComponent(name))
        }
        for name in ["Mountain Lake", "Red Fox"] {
            let copy = qfolder.appendingPathComponent("\(name) (2×).heic")
            try? fm.copyItem(at: folder.appendingPathComponent("\(name).heic"), to: copy)
            ImageStacks.markDerived(copy, from: qfolder.appendingPathComponent("\(name).heic"))
        }
        let model = ViewerModel()
        model.stacksEnabled = true
        model.openFolder(qfolder, selecting: qfolder.appendingPathComponent("Sailboat.heic"))
        for _ in 0..<100 where model.items.count < 5 || model.decoded == nil { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(300))
        let ai = model.intelligence
        // Not analyzed yet: Shot Quality scores the picture shown, and only it.
        ai.scoreCurrentIfNeeded()
        for _ in 0..<100 where !ai.scoring.isEmpty || ai.index.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        check(model.currentURL.flatMap { ai.index[$0]?.score } != nil && ai.qualityScores.count == 1,
              "Shot Quality scores the shown picture on its own (\(ai.qualityScores.count) scored)")
        ai.analyzeFolder()
        for _ in 0..<600 where ai.isIndexing || ai.indexedCount < model.allItems.count { try? await Task.sleep(for: .milliseconds(100)) }
        var scores = ai.qualityScores
        check(model.items.allSatisfy { scores[$0.url] != nil }, "every shown picture, stacks' top copies too, has a score")
        model.sortKey = .quality
        try? await Task.sleep(for: .milliseconds(300))
        var ranked = model.items.map { scores[$0.url] ?? -2 }
        check(zip(ranked, ranked.dropFirst()).allSatisfy { $0 >= $1 }, "Best Shots lists them best first: \(model.items.map(\.name))")
        // A copy made afterwards tops its stack, and is scored without analyzing again.
        let later = qfolder.appendingPathComponent("Sunflowers (Retouched).heic")
        try? fm.copyItem(at: folder.appendingPathComponent("Sunflowers.heic"), to: later)
        ImageStacks.markDerived(later, from: qfolder.appendingPathComponent("Sunflowers.heic"))
        if let item = FolderScanner.item(for: later) { model.insertItem(item, select: false) }
        for _ in 0..<100 where ai.qualityScores[later.standardizedFileURL] == nil { try? await Task.sleep(for: .milliseconds(100)) }
        scores = ai.qualityScores
        ranked = model.items.map { scores[$0.url] ?? -2 }
        check(scores[later.standardizedFileURL] != nil && model.items.contains { $0.url == later.standardizedFileURL }
              && zip(ranked, ranked.dropFirst()).allSatisfy { $0 >= $1 },
              "a copy made later is scored by itself and keeps its stack in place")
        model.sortKey = .name
    }

    /// Fix Blur: a softened and a shaken detail come back closer to the original; faces are aligned to the
    /// template right; a copy is saved and stacked. (`AOK_SELFTEST_ONLY=blur` runs just these.)
    private static func fixBlurChecks(_ photo: DecodedImage, out: URL) async {
        let ctx = EditRenderer.shared.context
        let space = photo.cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // The face template's points, turned, scaled and moved, are found again.
        let turn = CGAffineTransform(rotationAngle: 0.2).scaledBy(x: 2.5, y: 2.5).translatedBy(x: 40, y: -12)
        let moved = BlurFixer.template.map { $0.applying(turn) }
        if let found = BlurFixer.similarity(from: BlurFixer.template, to: moved) {
            let error = zip(BlurFixer.template.map { $0.applying(found) }, moved).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 99
            check(error < 0.01, String(format: "faces are aligned to the template exactly (off by %.4f px)", error))
        } else {
            check(false, "faces are aligned to the template")
        }
        guard let sharp = photo.cgImage.cropping(to: CGRect(x: 600, y: 600, width: 640, height: 640)) else { return check(false, "a detail") }
        let rect = CGRect(x: 0, y: 0, width: sharp.width, height: sharp.height)
        func degraded(_ filter: String, _ params: [String: Any]) -> CGImage? {
            ctx.createCGImage(CIImage(cgImage: sharp).clampedToExtent().applyingFilter(filter, parameters: params).cropped(to: rect),
                              from: rect, format: .RGBA8, colorSpace: space)
        }
        func distance(_ a: CGImage, _ b: CGImage) -> Double {
            func px(_ image: CGImage) -> [UInt8] {
                var p = [UInt8](repeating: 0, count: image.width * image.height * 4)
                let c = CGContext(data: &p, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return p
            }
            let pa = px(a), pb = px(b)
            var total = 0
            for i in stride(from: 0, to: pa.count, by: 4) { for c in 0..<3 { total += abs(Int(pa[i + c]) - Int(pb[i + c])) } }
            return Double(total) / Double(pa.count / 4 * 3)
        }
        let cases: [(BlurFixer.Blur, String, CGImage?)] = [
            (.focus, "soft focus", degraded("CIGaussianBlur", [kCIInputRadiusKey: 1.6])),
            (.shake, "camera shake", degraded("CIMotionBlur", [kCIInputRadiusKey: 3, kCIInputAngleKey: 0.35])),
        ]
        for (blur, title, input) in cases {
            guard let input else { check(false, title); continue }
            guard blur.model?.isInstalled == true else { print("  • the \(blur.title) model isn't installed; skipping"); continue }
            var options = BlurFixer.Options()
            options.blur = blur
            options.faces = false
            let started = Date()
            do {
                let fixed = try await BlurFixer.fix(input, options)
                writeJPEG(fixed, to: out.appendingPathComponent("fixblur-\(blur.rawValue).jpg"))
                let before = distance(input, sharp), after = distance(fixed, sharp)
                check(after < before * 0.85, String(format: "%@ fixes %@: %.1f → %.1f from the sharp original, in %.1f s",
                                                    blur.title, title, before, after, Date().timeIntervalSince(started)))
            } catch {
                check(false, "\(blur.title) fixes \(title): \(error.localizedDescription)")
            }
        }
        if BlurFixer.faceModel.isInstalled {
            var options = BlurFixer.Options()
            options.blur = .none
            if let same = try? await BlurFixer.fix(sharp, options) {
                check(distance(same, sharp) < 0.5, "Restore Faces leaves a picture without faces as it was")
            } else {
                check(false, "Restore Faces on a picture without faces")
            }
        }
        // Done: a stacked copy.
        guard BlurFixer.focusModel.isInstalled else { return }
        let fm = FileManager.default
        let folder = out.appendingPathComponent("sharpen")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Harbor.png")
        try? ImageWriter.write(sharp, to: file, format: .png, quality: 1, sourceProperties: [:], metadata: .removeAll)
        let model = ViewerModel()
        model.stacksEnabled = true
        model.openFolder(folder, selecting: file)
        for _ in 0..<100 where model.decoded?.url != file.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
        var options = BlurFixer.Options()
        options.faces = false
        model.fixBlurCurrent(options)
        let copy = folder.appendingPathComponent("Harbor (Sharpened).png")
        for _ in 0..<300 where !fm.fileExists(atPath: copy.path) { try? await Task.sleep(for: .milliseconds(100)) }
        for _ in 0..<50 where model.items.contains(where: { $0.url == file.standardizedFileURL }) && model.stackOf.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        check(fm.fileExists(atPath: copy.path) && ImageStacks.source(of: copy) == "Harbor.png",
              "Fix Blur saves “Harbor (Sharpened)”, stacked on the original\(model.alert.map { " (\($0.title): \($0.message))" } ?? "")")
    }

    /// Ratings, captions and keywords written to files: in the file for JPEG, PNG, TIFF and HEIC (the picture,
    /// Finder label and other attributes unchanged), in a sidecar for RAW and GIF (Lightroom's settings in it
    /// kept); the rating keys, filter and sort; unsaved edits surviving the rewrite; Copy and Paste Edits.
    /// (`AOK_SELFTEST_ONLY=tags` runs just these.)
    private static func tagsChecks(out: URL) async {
        let fm = FileManager.default
        let folder = out.appendingPathComponent("tags")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: 301, height: 199, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return check(false, "test picture") }
        for y in 0..<199 {
            ctx.setFillColor(CGColor(srgbRed: Double(y) / 199, green: 0.4, blue: 1 - Double(y) / 199, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: 301, height: 1))
        }
        guard let picture = ctx.makeImage() else { return check(false, "test picture") }
        func pixels(_ url: URL) -> Data? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return image.dataProvider?.data as Data?
        }
        func xattr(_ url: URL) -> String? {
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = url.withUnsafeFileSystemRepresentation { getxattr($0, "com.oneopa.selftest", &buffer, 64, 0, 0) }
            return n > 0 ? String(decoding: buffer.prefix(n), as: UTF8.self) : nil
        }

        let update = FileTags.Update(rating: 3.5, title: "Gradient", caption: "A gradient from blue to red", keywords: ["gradient", "test"])
        for format in [ExportFormat.jpeg, .png, .tiff, .heic] {
            let file = folder.appendingPathComponent("Gradient.\(format.rawValue)")
            try? ImageWriter.write(picture, to: file, format: format, quality: 0.9, sourceProperties: [:], metadata: .removeAll)
            var labelled = file
            var values = URLResourceValues()
            values.labelNumber = Flag.pick.rawValue
            try? labelled.setResourceValues(values)
            _ = file.withUnsafeFileSystemRepresentation { setxattr($0, "com.oneopa.selftest", "kept", 4, 0, 0) }
            let before = pixels(file)
            do {
                _ = try FileTags.writeNow(update, to: file)
                let read = FileTags.read(file)
                let label = try? file.resourceValues(forKeys: [.labelNumberKey]).labelNumber
                check(FileTags.sidecar(for: file) == nil && read.rating == 3.5 && read.title == "Gradient"
                      && read.caption == "A gradient from blue to red" && read.keywords == ["gradient", "test"],
                      "\(format.rawValue): the rating, title, caption and keywords are written in the file (\(read))")
                check(before != nil && pixels(file) == before, "\(format.rawValue): the picture is unchanged")
                check(label == Flag.pick.rawValue && xattr(file) == "kept", "\(format.rawValue): its Finder label and other attributes are kept")
                _ = try FileTags.writeNow(FileTags.Update(rating: 0), to: file)
                let cleared = FileTags.read(file)
                check(cleared.rating == 0 && cleared.title == "Gradient", "\(format.rawValue): a rating is taken off, the rest kept")
            } catch {
                check(false, "\(format.rawValue): \(error.localizedDescription)")
            }
        }

        // RAW: a sidecar, keeping what Lightroom keeps in it.
        let raw = folder.appendingPathComponent("IMG_0001.CR2")
        fm.createFile(atPath: raw.path, contents: Data())
        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        try? Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
         xmp:Rating="2" crs:Exposure2012="+0.45"/></rdf:RDF></x:xmpmeta>
        """.utf8).write(to: sidecar)
        check(FileTags.read(raw).rating == 2, "RAW: the rating in Lightroom's sidecar is read")
        do {
            _ = try FileTags.writeNow(FileTags.Update(rating: 4, keywords: ["fox"]), to: raw)
            let text = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
            check(FileTags.sidecar(for: raw) == sidecar && FileTags.read(raw).rating == 4 && FileTags.read(raw).keywords == ["fox"]
                  && text.contains("Exposure2012") && (try? Data(contentsOf: raw))?.isEmpty == true,
                  "RAW: the rating and keywords go in its sidecar, Lightroom's settings kept, the RAW untouched")
        } catch {
            check(false, "RAW sidecar: \(error.localizedDescription)")
        }
        let gif = folder.appendingPathComponent("Gradient.gif")
        try? ImageWriter.write(picture, to: gif, format: .gif, quality: 1, sourceProperties: [:], metadata: .removeAll)
        _ = try? FileTags.writeNow(FileTags.Update(rating: 5), to: gif)
        check(FileTags.read(gif).rating == 5 && fm.fileExists(atPath: folder.appendingPathComponent("Gradient.xmp").path),
              "GIF: a sidecar holds the rating")

        // The model: keys, half stars, filter and sort, and edits surviving the rewrite. (Not with the RAW, which
        // is no picture.)
        try? fm.removeItem(at: raw)
        try? fm.removeItem(at: sidecar)
        let jpeg = folder.appendingPathComponent("Gradient.jpeg").standardizedFileURL
        let png = folder.appendingPathComponent("Gradient.png").standardizedFileURL
        let model = ViewerModel()
        model.openFolder(folder, selecting: jpeg)
        for _ in 0..<100 where model.isScanning || model.allItems.contains(where: { $0.rating == nil }) { try? await Task.sleep(for: .milliseconds(50)) }
        check(model.allItems.first { $0.url == gif.standardizedFileURL }?.rating == 5, "a folder's ratings are read when it opens")
        model.updateEdits("Exposure") { $0.exposure = 0.4 }
        model.rateKey(3)
        check(model.currentItem?.rating == 3, "3 rates three stars")
        model.rateKey(3)
        check(model.currentItem?.rating == 3.5, "3 again makes it three and a half")
        for _ in 0..<60 where FileTags.read(jpeg).rating != 3.5 { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(200))
        // (A fresh URL: the one above has cached the date from before.)
        let fileDate = try? URL(fileURLWithPath: jpeg.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        check(FileTags.read(jpeg).rating == 3.5 && model.currentItem?.modificationDate == fileDate,
              "the rating is written to the file, and the window knows its new date (\(FileTags.read(jpeg).rating), "
              + "\(String(describing: model.currentItem?.modificationDate)) vs \(String(describing: fileDate)))")
        model.flagFilter = .threeStars
        check(Set(model.items.map(\.url)) == [jpeg, gif.standardizedFileURL], "★★★ or More shows the rated images")
        model.flagFilter = .all
        model.sortKey = .rating
        check(model.items.first?.url == gif.standardizedFileURL && model.items.dropFirst().first?.url == jpeg, "sorting by rating puts the best first")
        model.sortKey = .name
        let reopened = ViewerModel()
        reopened.openFolder(folder, selecting: jpeg)
        check(reopened.edits[jpeg]?.exposure == 0.4, "unsaved edits still come back after the rating rewrote the file")
        model.select(jpeg)
        model.rateKey(0)
        for _ in 0..<60 where FileTags.read(jpeg).rating != 0 { try? await Task.sleep(for: .milliseconds(50)) }
        check(model.currentItem?.rating == 0 && FileTags.read(jpeg).rating == 0, "0 takes the rating off")

        // Copy and Paste Edits: the adjustments, not the other picture's crop or turn.
        model.updateEdits("Crop") { $0.crop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5); $0.quarterTurns = 1; $0.contrast = 0.2 }
        model.copyEdits()
        model.select(png)
        model.updateEdits("Straighten") { $0.straighten = 2 }
        model.pasteEdits(to: [png])
        let pasted = model.edits[png]
        check(pasted?.exposure == 0.4 && pasted?.contrast == 0.2 && pasted?.crop == nil && pasted?.quarterTurns == 0 && pasted?.straighten == 2,
              "Paste Edits brings the light and color, and the picture keeps its own crop and straightening")
        model.edits.keys.forEach { model.setEditsDictionary($0, nil) }
        reopened.edits.keys.forEach { reopened.setEditsDictionary($0, nil) }
    }

    /// Combine Pictures: the subject placed, sized and flipped where the layout says, lit and shadowed; a
    /// transparent picture's subject from its transparency, a photo's from Vision; the first placement where
    /// it was; the copy saved beside the background and stacked with it. (`AOK_SELFTEST_ONLY=combine` runs
    /// just these.)
    private static func combineChecks(folder: URL, out: URL) async {
        let fm = FileManager.default
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func solid(_ w: Int, _ h: Int, _ r: Double, _ g: Double, _ b: Double, alpha: Bool = false) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            if alpha {
                // A disc with its right half lighter, on transparency.
                ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0.4, alpha: 1))
                ctx.fill(CGRect(x: w / 2 + w / 8, y: h / 3, width: w / 8, height: h / 3))
            } else {
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            return ctx.makeImage()
        }
        func pixel(_ image: CGImage, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: -x * Double(image.width), y: -(1 - y) * Double(image.height) + 1, width: Double(image.width), height: Double(image.height)))
            return (Int(px[0]), Int(px[1]), Int(px[2]))
        }
        guard let blue = solid(800, 500, 0.1, 0.2, 0.9), let disc = solid(200, 200, 0.9, 0.1, 0.1, alpha: true) else {
            return check(false, "test pictures")
        }
        do {
            let subject = try await Combine.subject(of: disc, transparent: true)
            check(abs(subject.rect.width - 1) < 0.02 && abs(subject.rect.height - 1) < 0.02, "a transparent picture's subject is what isn't transparent")
            let layout = Combine.Layout(center: CGPoint(x: 0.3, y: 0.6), height: 0.4)
            guard let made = Combine.compose(background: blue, subject: subject, layout: layout, matchLighting: 0, shadow: 0) else {
                return check(false, "compose")
            }
            let center = pixel(made, 0.3, 0.6), corner = pixel(made, 0.95, 0.05)
            let w = 0.4 * 500 / 800   // its width, as a fraction of the background's
            check(made.width == 800 && made.height == 500 && center.r > 180 && center.b < 80 && corner.b > 180,
                  "the subject sits where the layout puts it, on the background, at the background's size (\(center), \(corner))")
            check(pixel(made, 0.3 + w * 0.6, 0.6).b > 150 && pixel(made, 0.3 + w * 0.45, 0.6).r > 180,
                  "and at the size it says (its edge where it should be)")
            let rightLight = pixel(made, 0.3 + w * 0.19, 0.6)
            var flipped = layout
            flipped.flipped = true
            let mirrored = Combine.compose(background: blue, subject: subject, layout: flipped, matchLighting: 0, shadow: 0).map { pixel($0, 0.3 - w * 0.19, 0.6) }
            check(rightLight.g > 200 && mirrored.map { $0.g > 200 } == true, "Flip mirrors it (its light patch moves to the other side)")
            let lit = Combine.compose(background: blue, subject: subject, layout: layout, matchLighting: 1, shadow: 0).map { pixel($0, 0.3, 0.6) }
            // (Light multiplies: a red subject in dark blue light gets darker, and bluer for its red.)
            check(lit.map { $0.r < center.r - 20 && Double($0.b) / Double($0.r) > Double(center.b) / Double(center.r) } == true,
                  "Match Lighting moves its light toward the background's (\(String(describing: lit)) from \(center))")
            let below = (x: 0.3, y: 0.6 + 0.2 + 0.006)
            let shaded = Combine.compose(background: blue, subject: subject, layout: layout, matchLighting: 0, shadow: 1).map { pixel($0, below.x, below.y) }
            let plain = pixel(made, below.x, below.y)
            check(shaded.map { $0.b < plain.b - 10 } == true, "Shadow darkens the background just outside it")
            // Erase: a stroke across its middle takes it away there (the background shows), ⌥ puts back part of it.
            let across = Combine.Stroke(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)], radius: 0.06, restore: false)
            let back = Combine.Stroke(points: [CGPoint(x: 0.25, y: 0.5)], radius: 0.05, restore: true)
            let erased = Combine.erased(subject, by: [across]), restored = Combine.erased(subject, by: [across, back])
            let gone = Combine.compose(background: blue, subject: erased, layout: layout, matchLighting: 0, shadow: 0).map { pixel($0, 0.3, 0.6) }
            let kept = Combine.compose(background: blue, subject: erased, layout: layout, matchLighting: 0, shadow: 0).map { pixel($0, 0.3, 0.6 - 0.1) }
            let putBack = Combine.compose(background: blue, subject: restored, layout: layout, matchLighting: 0, shadow: 0).map { pixel($0, 0.3 - w / 4, 0.6) }
            check(gone.map { $0.b > 180 } == true && kept.map { $0.r > 180 } == true && putBack.map { $0.r > 180 } == true,
                  "Erase takes away what's painted over (the rest kept), and ⌥ puts it back")
            let initial = Combine.Layout.initial(for: Combine.Subject(image: subject.image, rect: CGRect(x: 0.5, y: 0.4, width: 0.3, height: 0.5)),
                                                 on: CGSize(width: 800, height: 500))
            check(abs(initial.height - 0.5) < 0.001 && abs(initial.center.y + initial.height / 2 - 0.9) < 0.001 && abs(initial.center.x - 0.65) < 0.001,
                  "it starts where it was in its own picture, at the same height, its bottom where it was")
        } catch {
            check(false, "Combine: \(error.localizedDescription)")
        }

        // A photo's subject comes from Vision; Save makes a stacked copy of the background.
        let fox = folder.appendingPathComponent("Red Fox.heic"), lake = folder.appendingPathComponent("Mountain Lake.heic")
        guard fm.fileExists(atPath: fox.path), fm.fileExists(atPath: lake.path) else { return check(false, "Red Fox and Mountain Lake test images") }
        let dir = out.appendingPathComponent("combine")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let background = dir.appendingPathComponent("Mountain Lake.heic")
        try? fm.copyItem(at: lake, to: background)
        let model = ViewerModel()
        model.stacksEnabled = true
        model.openFolder(dir, selecting: background)
        for _ in 0..<100 where model.decoded?.url != background.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
        do {
            let fg = try await model.combinePicture(fox)
            let subject = try await Combine.subject(of: fg.picture, transparent: fg.transparent)
            check(subject.rect.width > 0.1 && subject.rect.width < 0.95 && subject.rect.height > 0.2, "Vision lifts the fox from its photo (\(subject.rect))")
            let bg = try await model.combinePicture(background)
            let layout = Combine.Layout.initial(for: subject, on: CGSize(width: bg.picture.width, height: bg.picture.height))
            if let made = Combine.compose(background: bg.picture, subject: subject, layout: layout, matchLighting: 0.6, shadow: 1) {
                let edges = [(0.002, 0.5), (0.5, 0.002), (0.002, 0.998), (0.3, 0.998)]
                check(edges.allSatisfy { pixel(made, $0.0, $0.1) == pixel(bg.picture, $0.0, $0.1) },
                      "the background far from the subject is left as it was (shadow and lighting only near it)")
            }
            model.saveCombined(background: background, decoded: bg.decoded, subject: subject, layout: layout, matchLighting: 0.6, shadow: 0.3)
            let copy = dir.appendingPathComponent("Mountain Lake (Combined).heic")
            for _ in 0..<200 where !fm.fileExists(atPath: copy.path) { try? await Task.sleep(for: .milliseconds(100)) }
            let size = (CGImageSourceCreateWithURL(copy as CFURL, nil)).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
            let width = size?[kCGImagePropertyPixelWidth as String] as? Int
            check(fm.fileExists(atPath: copy.path) && ImageStacks.source(of: copy) == "Mountain Lake.heic" && width == bg.picture.width,
                  "Save makes “Mountain Lake (Combined)” at the background's size, stacked with it\(model.alert.map { " (\($0.title): \($0.message))" } ?? "")")
        } catch {
            check(false, "Combine with photos: \(error.localizedDescription)")
        }
    }

    /// Auto Straighten: a horizon's tilt measured; no false horizon in a photo without lines; a room's receding
    /// lines don't tilt it; uprights leaning apart in perspective still show the camera's tilt; lines converging
    /// in perspective aren't a horizon.
    /// (`AOK_SELFTEST_ONLY=straighten` runs just these.)
    private static func straightenChecks(decodedByName: [String: DecodedImage]) async {
        let w = 900, h = 600
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.55, green: 0.72, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 260, width: w, height: h - 260))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.25, blue: 0.4, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: 260))
        var rng = GaussianNoise(seed: 5)
        for _ in 0..<1500 {   // waves
            let x = CGFloat(abs(rng.next()) * 300).truncatingRemainder(dividingBy: CGFloat(w)), y = CGFloat(abs(rng.next()) * 80).truncatingRemainder(dividingBy: 250)
            ctx.setFillColor(CGColor(red: 0.3, green: 0.45, blue: 0.6, alpha: 0.6)); ctx.fill(CGRect(x: x, y: y, width: 18, height: 2))
        }
        let sea = ctx.makeImage()!
        func turned(_ degrees: Double) -> CGImage {
            let ci = CIImage(cgImage: sea).transformed(by: CGAffineTransform(rotationAngle: degrees * .pi / 180))
            let e = ci.extent
            let r = CGRect(x: (e.midX - 0.36 * CGFloat(w)).rounded(), y: (e.midY - 0.36 * CGFloat(h)).rounded(),
                           width: (0.72 * CGFloat(w)).rounded(), height: (0.72 * CGFloat(h)).rounded())
            return ImageDecoder.ciContext.createCGImage(ci, from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        }
        var results: [String] = []
        var ok = true
        for tilt in [0.0, 0.8, 3.0, -7.0] {
            // Turned counterclockwise by `tilt`, it needs turning clockwise by `tilt` to be level.
            let m = await VisionServices.straightenAngle(turned(tilt))
            results.append(m.map { String(format: "%.1f°→%.1f°", tilt, $0) } ?? String(format: "%.1f°→none", tilt))
            if m == nil || abs(m! - tilt) > 0.5 { ok = false }
        }
        check(ok, "straighten measures a horizon's tilt: " + results.joined(separator: ", "))
        if let bird = decodedByName["Hummingbird.heic"] {
            check(VisionServices.tiltFromLines(bird.cgImage) == nil, "no straight lines in a photo of a bird and flowers, so no false horizon")
        }
        // A room: plumb door frames, and a long counter receding at 7° (perspective, not a tilted camera).
        func room(roll: Double, keystone: Double, counter: Double?) -> CGImage {
            let w = 900, h = 700
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.85, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            ctx.rotate(by: roll * .pi / 180)   // the picture turned counterclockwise by `roll` (y up here)
            ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
            ctx.setLineWidth(6)
            for x in stride(from: -360.0, through: 360, by: 180) {
                // (Uprights lean apart, more the further from the middle: looking up.)
                let lean = keystone * x / 360 * .pi / 180
                ctx.move(to: CGPoint(x: x - 300 * tan(lean), y: -300)); ctx.addLine(to: CGPoint(x: x + 300 * tan(lean), y: 300))
            }
            ctx.strokePath()
            if let counter {
                ctx.setLineWidth(10)
                ctx.move(to: CGPoint(x: -420, y: -120 - 420 * tan(counter * .pi / 180)))
                ctx.addLine(to: CGPoint(x: 420, y: -120 + 420 * tan(counter * .pi / 180)))
                ctx.strokePath()
            }
            return ctx.makeImage()!
        }
        let level = await VisionServices.straightenAngle(room(roll: 0, keystone: 0, counter: 7))
        check(level.map { abs($0) < 0.6 } ?? true, "a room's receding counter doesn't tilt it: its plumb door frames say level (\(String(describing: level)))")
        let rolled = await VisionServices.straightenAngle(room(roll: 2, keystone: 6, counter: nil))
        check(rolled.map { abs($0 - 2) < 0.6 } == true, "uprights leaning apart in perspective still show a 2° tilt (\(String(describing: rolled)))")
        // A quay and a breakwater's waterline converging on a ship (one rising 4°, one falling 4°), a faint
        // level horizon above them, and no uprights: perspective, not a tilted camera.
        let harbor: CGImage = {
            let w = 900, h = 700
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: 0, y: 400)); ctx.addLine(to: CGPoint(x: 500, y: 400)); ctx.strokePath()
            ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
            ctx.setLineWidth(10)
            ctx.move(to: CGPoint(x: 0, y: 330)); ctx.addLine(to: CGPoint(x: 900, y: 330 + 900 * tan(4 * Double.pi / 180))); ctx.strokePath()
            ctx.move(to: CGPoint(x: 0, y: 250)); ctx.addLine(to: CGPoint(x: 900, y: 250 - 900 * tan(4 * Double.pi / 180))); ctx.strokePath()
            return ctx.makeImage()!
        }()
        let converging = await VisionServices.straightenAngle(harbor)
        check(converging.map { abs($0) < 0.6 } ?? true, "lines converging in perspective (a quay, a breakwater) don't pass for a tilted horizon (\(String(describing: converging)))")
    }

    static func run() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-selfTest"), i + 1 < args.count else {
            print("usage: -selfTest <folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
        // The test drives real models, which save preferences shared with the user's copy of the app;
        // put them back afterwards.
        let touchedKeys = [PrefKey.sortKey, PrefKey.sortAscending, PrefKey.recentFolders, PrefKey.lastViewedFiles,
                           PrefKey.includeSubfolders, PrefKey.gridThumbnailSize, PrefKey.showFilmstrip, PrefKey.stackCopies,
                           CopyOperation.blackAndWhite.key, CopyOperation.removeObjects.key, CopyOperation.changeObjects.key, CopyOperation.cloneHeal.key, PrefKey.cloneHeals, PrefKey.confirmOverwrite,
                           PrefKey.trashOriginalOnSave, PrefKey.blackAndWhite, PrefKey.extendMethod, PrefKey.removalMethod,
                           PrefKey.removalBrush, PrefKey.fixBlur, CopyOperation.fixBlur.key, PrefKey.stackFronts]
        let savedPrefs = touchedKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ImageViewerSelfTest-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("Self-test on \(folder.path)\nOutput: \(out.path)")

        // 1. Scan & decode everything.
        print("\n[Scan & decode]")
        let items = FolderScanner.sort((try? FolderScanner.scan(folder: folder, recursive: false, showHidden: false)) ?? [], by: .name, ascending: true)
        check(!items.isEmpty, "scanned \(items.count) images")
        var decodedByName: [String: DecodedImage] = [:]
        for item in items {
            let t0 = Date()
            do {
                let d = try ImageDecoder.decode(url: item.url, page: 0, allowHDR: true)
                decodedByName[item.name] = d
                let thumb = ImageDecoder.thumbnail(url: item.url, maxPixelSize: 160)
                print(String(format: "  ✓ %-22@ %5.0f×%-5.0f %@%@%@ thumb:%@ %.0f ms", item.name as NSString, d.pixelSize.width, d.pixelSize.height,
                             d.isAnimated ? "anim " : "", d.pageCount > 1 ? "\(d.pageCount)pp " : "", d.hasAlpha ? "alpha " : "",
                             thumb == nil ? "NO" : "ok", Date().timeIntervalSince(t0) * 1000))
            } catch {
                check(false, "\(item.name): \(error.localizedDescription)")
            }
        }
        // `AOK_SELFTEST_ONLY=download` (with AOK_MODELS_URL and a scratch AOK_MODELS_DIR): the object removal and
        // Fix Blur models' archives download, match their checksums and install.
        if ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"] == "download" {
            print("\n[Model download]")
            for model in [DownloadableModel.removal, .fixBlur, .restoreFaces] {
                let started = Date()
                ModelDownloads.shared.start(model)
                for _ in 0..<3000 where ModelDownloads.shared.status[model.id] != nil { try? await Task.sleep(for: .milliseconds(100)) }
                check(model.isInstalled() && ModelDownloads.shared.failure[model.id] == nil,
                      "\(model.archives[0].file) downloads, matches its checksum and installs in \(Int(Date().timeIntervalSince(started))) s"
                      + (ModelDownloads.shared.failure[model.id].map { " (\($0))" } ?? ""))
            }
            print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
            try? FileManager.default.removeItem(at: AppStorageLocation.support)
            exit(failures == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"] == "quality" {
            print("\n[Shot quality with stacks]")
            await shotQualityChecks(folder: folder, out: out)
            for (key, value) in savedPrefs {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
            try? FileManager.default.removeItem(at: AppStorageLocation.support)
            exit(failures == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"] == "blur", let harbor = decodedByName["Harbor Village.heic"] {
            print("\n[Fix Blur]")
            await fixBlurChecks(harbor, out: out)
            for (key, value) in savedPrefs {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
            try? FileManager.default.removeItem(at: AppStorageLocation.support)
            exit(failures == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"] == "straighten" {
            print("\n[Straighten]")
            await straightenChecks(decodedByName: decodedByName)
            print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
            try? FileManager.default.removeItem(at: AppStorageLocation.support)
            exit(failures == 0 ? 0 : 1)
        }
        if ["clone", "wb", "newimage", "tags", "combine"].contains(ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"]) {
            if ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"] == "combine" {
                print("\n[Combine Pictures]")
                await combineChecks(folder: folder, out: out)
            } else if ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"] == "tags" {
                print("\n[Ratings, captions, Copy Edits]")
                await tagsChecks(out: out)
            } else if ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"] == "clone" {
                print("\n[Clone & Heal]")
                await cloneHealChecks(out: out)
            } else if ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"] == "newimage" {
                print("\n[New Image]")
                await newImageChecks(out: out)
            } else {
                print("\n[White Balance]")
                await whiteBalanceChecks(out: out)
            }
            for (key, value) in savedPrefs {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
            try? FileManager.default.removeItem(at: AppStorageLocation.support)
            exit(failures == 0 ? 0 : 1)
        }
        if ["remove", "change"].contains(ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"]), let boat = decodedByName["Sailboat.heic"] {
            if ProcessInfo.processInfo.environment["AOK_SELFTEST_ONLY"] == "remove" {
                print("\n[Remove Objects]")
                await removeObjectsChecks(boat, out: out)
            }
            print("\n[Change Objects]")
            await changeObjectsChecks(boat, out: out)
            for (key, value) in savedPrefs {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
            try? FileManager.default.removeItem(at: AppStorageLocation.support)
            exit(failures == 0 ? 0 : 1)
        }
        // Edits that can't show don't count as edits (an image isn't "edited" with nothing to see or undo).
        do {
            var faint = EditState()
            faint.temperature = 0.003
            faint.straighten = 0.02
            faint.removals = []
            faint.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
            faint.extendPrompt = "a beach"
            var real = faint
            real.exposure = 0.2
            check(faint.isIdentity && !real.isIdentity, "edits that don't show (a slider a hair off zero, an empty list, a whole-picture crop) aren't edits")
        }
        if let rot = decodedByName["rotated-exif6.jpg"] {
            check(rot.pixelSize == CGSize(width: 600, height: 900), "EXIF orientation 6 displays as 600×900 portrait")
        }

        // 2. Edit rendering geometry.
        print("\n[Edit rendering]")
        if let d = decodedByName["sale-sign.jpg"] {
            var e = EditState()
            e.rotate(clockwise: true)
            check(EditRenderer.shared.outputSize(d, edits: e) == CGSize(width: 1000, height: 1600), "rotate right swaps dimensions")
            e = EditState()
            e.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            check(EditRenderer.shared.outputSize(d, edits: e) == CGSize(width: 800, height: 500), "crop to center half → 800×500")
            e = EditState()
            e.straighten = 10
            let s = EditRenderer.shared.outputSize(d, edits: e)
            check(s.width < 1600 && abs(s.width / s.height - 1.6) < 0.02, String(format: "straighten 10° keeps aspect, inscribed %.0f×%.0f", s.width, s.height))
            e = EditState()
            e.exposure = 1
            e.filter = .noir
            e.vignette = 0.5
            e.autoEnhance = true
            let proxy = EditRenderer.shared.renderSync(d, edits: e, maxDimension: 800)
            check(proxy?.image.width == 800 && proxy?.fullSize == CGSize(width: 1600, height: 1000), "proxy render 800 px wide, logical size 1600×1000")
        }

        // 3. Export with metadata stripping.
        print("\n[Export]")
        if let d = decodedByName["rotated-exif6.jpg"], let rendered = EditRenderer.shared.renderSync(d, edits: EditState(), maxDimension: 300) {
            for format in [ExportFormat.jpeg, .heic, .avif, .png, .tiff] where ExportFormat.writable.contains(format) {
                let url = out.appendingPathComponent("export.\(format.fileExtension)")
                do {
                    try ImageWriter.write(rendered.image, to: url, format: format, quality: 0.8, sourceProperties: d.properties, metadata: .removeLocation)
                    let src = CGImageSourceCreateWithURL(url as CFURL, nil)
                    let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
                    let gps = props[kCGImagePropertyGPSDictionary as String] != nil
                    let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                    let orient = props[kCGImagePropertyOrientation as String] as? Int ?? 1
                    check(!gps && w == 200 && orient == 1, "\(format.displayName): \(w) px wide, orientation \(orient), GPS \(gps ? "present" : "removed")")
                } catch {
                    check(false, "\(format.displayName): \(error.localizedDescription)")
                }
            }
            let keep = out.appendingPathComponent("keep.jpg")
            try? ImageWriter.write(rendered.image, to: keep, format: .jpeg, quality: 0.8, sourceProperties: d.properties, metadata: .keepAll)
            let kp = CGImageSourceCreateWithURL(keep as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
            check(MetadataFormatting.gpsCoordinate(kp) != nil && MetadataFormatting.cameraName(kp) == "Apple iPhone 17 Pro", "keep-all preserves GPS and camera")
        }

        // 3b. What a written file keeps: XMP and places (or not), HDR as a gain map, whole-number 16-bit TIFFs.
        print("\n[Writing]")
        do {
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            let plain = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            plain.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
            plain.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let image = plain.makeImage()!
            // A source with XMP (a label, a panorama tag, a city), IPTC places and GPS.
            let source = out.appendingPathComponent("xmp-source.jpg")
            let xmp = CGImageMetadataCreateMutable()
            _ = CGImageMetadataRegisterNamespaceForPrefix(xmp, "http://ns.google.com/photos/1.0/panorama/" as CFString, "GPano" as CFString, nil)
            CGImageMetadataSetValueWithPath(xmp, nil, "GPano:ProjectionType" as CFString, "equirectangular" as CFString)
            CGImageMetadataSetValueWithPath(xmp, nil, "xmp:Label" as CFString, "Red" as CFString)
            CGImageMetadataSetValueWithPath(xmp, nil, "photoshop:City" as CFString, "Springfield" as CFString)
            if let d = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImageAndMetadata(d, image, xmp, [
                    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLatitudeRef: "N"],
                    kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Springfield", kCGImagePropertyIPTCCountryPrimaryLocationName: "Freedonia"],
                ] as CFDictionary)
                _ = CGImageDestinationFinalize(d)
            }
            let props = (CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }) ?? [:]
            func read(_ url: URL) -> (props: [String: Any], xmp: (String) -> String?) {
                let src = CGImageSourceCreateWithURL(url as CFURL, nil)
                let p = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
                let m = src.flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
                return (p, { path in m.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, path as CFString) as String? } })
            }
            for policy in [MetadataPolicy.keepAll, .removeLocation] {
                let url = out.appendingPathComponent("xmp-\(policy.rawValue).jpg")
                try? ImageWriter.write(image, to: url, format: .jpeg, quality: 0.9, sourceProperties: props, metadata: policy, source: source)
                let r = read(url)
                let city = (r.props[kCGImagePropertyIPTCDictionary as String] as? [String: Any])?[kCGImagePropertyIPTCCity as String] as? String
                let gps = r.props[kCGImagePropertyGPSDictionary as String] != nil
                let kept = r.xmp("xmp:Label") == "Red" && r.xmp("GPano:ProjectionType") == "equirectangular"
                if policy == .keepAll {
                    check(kept && gps && city == "Springfield" && r.xmp("photoshop:City") == "Springfield", "Keep All carries XMP (label, panorama), places and GPS")
                } else {
                    check(kept && !gps && city == nil && r.xmp("photoshop:City") == nil, "Remove Location also removes IPTC and XMP places, keeping the rest")
                }
            }
            // HDR (PQ) → a gain map in HEIC, SDR in PNG.
            let bright = CIImage(color: CIColor(red: 3, green: 3, blue: 3, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
            if let hdr = ImageDecoder.ciContext.createCGImage(bright, from: bright.extent, format: .RGBAh,
                                                             colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!) {
                let heic = out.appendingPathComponent("hdr.heic"), png = out.appendingPathComponent("hdr.png")
                try? ImageWriter.write(hdr, to: heic, format: .heic, quality: 0.9, sourceProperties: [:], metadata: .removeAll)
                try? ImageWriter.write(hdr, to: png, format: .png, quality: 1, sourceProperties: [:], metadata: .removeAll)
                let gainMap = CGImageSourceCreateWithURL(heic as CFURL, nil).flatMap { CGImageSourceCopyAuxiliaryDataInfoAtIndex($0, 0, kCGImageAuxiliaryDataTypeISOGainMap) } != nil
                let pngImage = CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                check(gainMap && pngImage.map { !ImageDecoder.isHDR($0) } == true, "HDR is written as a gain map (HEIC), tone mapped to SDR (PNG)")
            }
            // A deep image → a 16-bit whole-number TIFF without an alpha channel.
            let deep = ImageDecoder.ciContext.createCGImage(CIImage(cgImage: image), from: CGRect(x: 0, y: 0, width: 64, height: 48),
                                                            format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
            if let deep {
                let tiff = out.appendingPathComponent("deep.tiff")
                try? ImageWriter.write(deep, to: tiff, format: .tiff, quality: 1, sourceProperties: [:], metadata: .removeAll)
                let r = read(tiff).props
                check(r[kCGImagePropertyDepth as String] as? Int == 16 && r[kCGImagePropertyIsFloat as String] as? Bool != true
                      && r[kCGImagePropertyHasAlpha as String] as? Bool != true, "a 16-bit TIFF stays whole-number 16-bit, without an alpha channel")
            }
            let scaled = VisionServices.downscaledSync(CGContext(data: nil, width: 1001, height: 667, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!, maxDimension: 300)
            check(!ImageDecoder.containsTransparency(scaled), "a reduced copy has no see-through edges (\(scaled.width)×\(scaled.height))")
        }

        // 4. Safe in-place save.
        print("\n[Save in place]")
        if let src = items.first(where: { $0.name == "sale-sign.jpg" })?.url {
            let copy = out.appendingPathComponent("save-test.jpg")
            try? FileManager.default.copyItem(at: src, to: copy)
            do {
                let d = try ImageDecoder.decode(url: copy, page: 0, allowHDR: false)
                var e = EditState()
                e.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
                let r = EditRenderer.shared.renderSync(d, edits: e, maxDimension: nil)!
                try ImageWriter.replace(original: copy, with: r.image, format: .jpeg, quality: 0.93, sourceProperties: d.properties, trashOriginal: false)
                let w = ImageDecoder.header(url: copy)?.pixelSize.width
                check(w == 800, "saved file is now 800 px wide")
            } catch {
                check(false, "save: \(error.localizedDescription)")
            }
        }

        // 4b. Stacks: copies stack on their original, newest on top, by attribute or by the names copies get.
        print("\n[Stacks]")
        if let src = items.first(where: { $0.name == "sale-sign.jpg" })?.url {
            check(ImageStacks.sourceStem(fromName: "Beach (Colorized)") == "Beach"
                  && ImageStacks.sourceStem(fromName: "Beach (2×) 3") == "Beach"
                  && ImageStacks.sourceStem(fromName: "Beach (Black & White)") == "Beach"
                  && ImageStacks.sourceStem(fromName: "Unknown (1)") == nil, "copy names are recognized, and only those")
            let fm = FileManager.default
            let folder = out.appendingPathComponent("stacks")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let beach = folder.appendingPathComponent("Beach.jpg")
            let colorized = folder.appendingPathComponent("Beach (Colorized).jpg")
            let upscaled = folder.appendingPathComponent("Beach (Colorized) (2×).jpg")
            let holiday = folder.appendingPathComponent("Holiday.jpg")
            let other = folder.appendingPathComponent("Other.jpg")
            for (i, url) in [beach, colorized, upscaled, holiday, other].enumerated() {
                try? fm.copyItem(at: src, to: url)
                try? fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: Double(i * 60 - 3600))], ofItemAtPath: url.path)
            }
            ImageStacks.markDerived(colorized, from: beach)
            ImageStacks.markDerived(holiday, from: beach)    // e.g. exported beside it under another name
            check(ImageStacks.source(of: holiday) == "Beach.jpg", "a copy records what it was made from")
            let scanned = (try? FolderScanner.scan(folder: folder, recursive: false, showHidden: false)) ?? []
            let stacks = ImageStacks.stacks(scanned)
            let order = stacks.values.first?.map(\.name) ?? []
            check(stacks.count == 1 && order == ["Holiday.jpg", "Beach (Colorized) (2×).jpg", "Beach (Colorized).jpg", "Beach.jpg"],
                  "one stack, newest copy on top, original at the bottom (\(order.joined(separator: ", ")))")

            let model = ViewerModel()
            model.stacksEnabled = true
            model.openFolder(folder, selecting: other)
            for _ in 0..<100 where model.items.count != 2 || model.currentURL != other.standardizedFileURL {
                try? await Task.sleep(for: .milliseconds(50))
            }
            check(model.items.map(\.name).sorted() == ["Holiday.jpg", "Other.jpg"], "the list shows the stack once, by its newest copy")
            model.select(holiday.standardizedFileURL)
            model.stepInStack(1)
            model.stepInStack(1)
            check(model.currentItem?.name == "Beach (Colorized).jpg" && model.items.count == 2, "⌥→ steps down the stack in place")
            model.toggleStack(model.currentURL!)
            check(model.items.count == 5 && model.currentItem?.name == "Beach (Colorized).jpg", "a stack spreads out, staying on the same copy")
            model.toggleStack(model.currentURL!)
            check(model.items.count == 2 && model.currentItem?.name == "Beach (Colorized).jpg", "and closes again, showing that copy")
            // The copy last viewed is still the one shown when the folder is opened again.
            let again = ViewerModel()
            again.stacksEnabled = true
            again.openFolder(folder, selecting: other)
            for _ in 0..<100 where again.items.count != 2 { try? await Task.sleep(for: .milliseconds(50)) }
            check(again.items.map(\.name).sorted() == ["Beach (Colorized).jpg", "Other.jpg"],
                  "a stack still shows the copy last viewed when its folder is opened again (\(again.items.map(\.name)))")
            // A copy made while another picture is shown goes on top of its stack.
            model.select(other.standardizedFileURL)
            let made = folder.appendingPathComponent("Beach (Sharpened).jpg")
            try? FileManager.default.copyItem(at: beach, to: made)
            ImageStacks.markDerived(made, from: beach)
            model.copySaved(made, from: beach.standardizedFileURL)
            check(model.items.map(\.name).sorted() == ["Beach (Sharpened).jpg", "Other.jpg"] && model.currentURL == other.standardizedFileURL,
                  "a copy made while another picture is shown goes on top of its stack (\(model.items.map(\.name)))")
            try? FileManager.default.removeItem(at: made)
            model.rescan()
            for _ in 0..<50 where model.allItems.contains(where: { $0.name == "Beach (Sharpened).jpg" }) { try? await Task.sleep(for: .milliseconds(50)) }
            if let original = model.allItems.first(where: { $0.name == "Beach.jpg" }) {
                model.rename(original, to: "Shore")
                check(ImageStacks.source(of: holiday) == "Shore.jpg" && ImageStacks.source(of: colorized) == "Shore.jpg"
                      && model.stacks.count == 1 && model.stacks.values.first?.count == 4, "renaming an original keeps its copies stacked on it")
            }
            model.stacksEnabled = false
            check(model.items.count == 5, "stacking can be turned off")
            model.select(model.items[4].url)   // the last of five…
            model.stacksEnabled = true          // …then down to two
            model.gridClick(model.items[0].url, modifiers: .shift)
            check(model.selection.count <= 2, "a shift-click after the list got shorter stays within it")
            if let elsewhere = FolderScanner.item(for: src) {
                model.insertItem(elsewhere, select: true)
                check(!model.items.contains { $0.url == elsewhere.url }, "a copy saved in another folder isn't added to this one")
            }
            let copyName = ImageStacks.source(of: holiday)
            try? ImageWriter.replace(original: holiday, with: EditRenderer.shared.renderSync(try! ImageDecoder.decode(url: holiday, page: 0, allowHDR: false),
                                                                                          edits: .identity, maxDimension: 200)!.image,
                                     format: .jpeg, quality: 0.9, sourceProperties: [:], trashOriginal: false)
            // (Saving moves the original to the Trash and the new file into its place, without the attribute;
            // Save records it again. Here the original is replaced in place, not trashed.)
            if let copyName { ImageStacks.setSource(copyName, of: holiday) }
            check(copyName == "Shore.jpg" && ImageStacks.source(of: holiday) == copyName, "a saved copy still records its source")
        }

        // 4c. Updates: which GitHub release is an update, and who may replace the app.
        print("\n[Updates]")
        do {
            func release(_ tag: String, prerelease: Bool = false, assets: [String]) -> Data {
                let list = assets.map { #"{"name": "\#($0)", "browser_download_url": "https://example.com/\#($0)"}"# }.joined(separator: ",")
                return Data(#"{"tag_name": "\#(tag)", "draft": false, "prerelease": \#(prerelease), "html_url": "https://example.com/r", "body": "Notes", "assets": [\#(list)]}"#.utf8)
            }
            let parsed = ReleaseInfo.parse(release("v1.2.0", assets: ["AOK-ImageTool.dmg", "AOK-ImageTool-1.2.0.dmg"]))
            check(parsed?.version == "1.2.0" && parsed?.dmg.lastPathComponent == "AOK-ImageTool-1.2.0.dmg", "a release's version and numbered DMG are read")
            check(ReleaseInfo.parse(release("models-1", prerelease: true, assets: ["AOK-DDColor.zip"])) == nil
                  && ReleaseInfo.parse(release("v1.3.0", assets: ["notes.txt"])) == nil, "the models release, and a release without a DMG, aren't updates")
            check(Versions.isNewer("1.10.0", than: "1.9.2") && !Versions.isNewer("1.0", than: "1.0.0") && Versions.isNewer("1.0.1", than: "1.0"),
                  "versions compare by number")
            var requirement: SecRequirement?
            check(SecRequirementCreateWithString(Updater.requirement as CFString, [], &requirement) == errSecSuccess,
                  "the update signature requirement is valid")
            check(!Updater.shared.isUpdatable, "test runs never update themselves")
        }

        // 4d. Photos' Edit With, simulated with a file inside a ".photoslibrary" folder (never the user's library).
        print("\n[Photos round trip]")
        if let src = items.first(where: { $0.name == "sale-sign.jpg" })?.url {
            final class Added { var names: [String] = [] }
            let added = Added()
            let fm = FileManager.default
            let session = out.appendingPathComponent("Test.photoslibrary/private/com.apple.Photos/ExternalEditSessions/A1B2")
            try? fm.createDirectory(at: session, withIntermediateDirectories: true)
            let photo = session.appendingPathComponent("IMG_0001.jpg")
            try? fm.copyItem(at: src, to: photo)
            PhotosRoundTrip.addForTesting = { file in
                added.names.append(file.lastPathComponent)
                try? FileManager.default.removeItem(at: file)
            }
            defer { PhotosRoundTrip.addForTesting = nil }
            func sessionFiles() -> [String] { ((try? fm.contentsOfDirectory(atPath: session.path)) ?? []).sorted() }
            let model = ViewerModel()
            model.open([photo])
            for _ in 0..<100 where model.decoded?.url != photo.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
            check(model.items.count == 1 && model.windowSubtitle.contains("From Photos") && !RecentFolders.all.contains(where: { $0.path.contains(".photoslibrary") }),
                  "a photo from Photos opens by itself, marked From Photos, and stays out of Recent Folders")
            model.updateEdits("Crop") { $0.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1) }
            model.save()   // (no question: Photos keeps the original)
            for _ in 0..<100 where model.edits[photo.standardizedFileURL] != nil { try? await Task.sleep(for: .milliseconds(50)) }
            check(ImageDecoder.header(url: photo)?.pixelSize.width == 800 && sessionFiles() == ["IMG_0001.jpg"],
                  "Save writes the edit into Photos' file where it is, and leaves nothing else there")
            for _ in 0..<40 where model.decoded?.pixelSize.width != 800 { try? await Task.sleep(for: .milliseconds(50)) }
            model.saveBlackAndWhite(BlackAndWhite())
            for _ in 0..<100 where added.names.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            check(added.names == ["IMG_0001 (Black & White).jpg"] && sessionFiles() == ["IMG_0001.jpg"],
                  "a copy is added to Photos, not written into its library (\(added.names))")
            model.moveToTrash([photo.standardizedFileURL])
            check(fm.fileExists(atPath: photo.path) && model.alert != nil, "Photos' file can't be moved to the Trash from here")
        }

        // 4e. Photos library (Open from Photos): what can be checked without the user's library.
        print("\n[Photos library]")
        if let fox = decodedByName["Red Fox.heic"] {
            // A Live Photo's frame through the frame renderer looks like the still through the full one.
            var e = EditState()
            e.crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
            e.exposure = 0.6
            e.quarterTurns = 1
            e.filter = .warm
            let still = EditRenderer.shared.renderSync(fox, edits: e, maxDimension: nil)?.image
            let framed = EditRenderer.shared.applyToFrame(CIImage(cgImage: fox.cgImage), edits: e, still: fox, renderScale: 1)
            let frame = ImageDecoder.ciContext.createCGImage(framed, from: framed.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            if let still, let frame {
                let a = rgbaPixels(VisionServices.downscaledSync(still, maxDimension: 64)), b = rgbaPixels(VisionServices.downscaledSync(frame, maxDimension: 64))
                let diff = a.count == b.count ? zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / max(a.count, 1) : 999
                check(still.width == frame.width && still.height == frame.height && diff < 4,
                      "a Live Photo frame gets the same edit as the still (\(frame.width)×\(frame.height), difference \(diff))")
            } else {
                check(false, "frame rendering")
            }
            // Frames come in the camera's orientation: upright for editing, then back.
            let tile = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
                .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 3, height: 2)))
            func corner(_ image: CIImage) -> [UInt8] {
                var px = [UInt8](repeating: 0, count: 4)
                ImageDecoder.ciContext.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: image.extent.minX, y: image.extent.minY, width: 1, height: 1),
                                              format: .RGBA8, colorSpace: nil)
                return px
            }
            let orientations: [CGImagePropertyOrientation] = [.up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left]
            check(orientations.allSatisfy { o in
                let back = tile.oriented(o).oriented(PhotosLibrary.inverse(o))
                return back.extent.size == tile.extent.size && corner(back) == corner(tile)
            }, "each of the 8 orientations is undone after editing")
        }
        do {
            var e = EditState()
            e.exposure = 0.4
            e.crop = CGRect(x: 0, y: 0, width: 0.8, height: 1)
            let data = PHAdjustmentData(formatIdentifier: PhotosLibrary.formatIdentifier, formatVersion: PhotosLibrary.formatVersion,
                                        data: (try? JSONEncoder().encode(e)) ?? Data())
            let other = PHAdjustmentData(formatIdentifier: "com.apple.photo", formatVersion: "1", data: Data([1, 2, 3]))
            check(PhotosLibrary.edits(from: data) == e && PhotosLibrary.edits(from: other) == nil,
                  "an edit's settings come back from Photos; other apps' edits aren't taken for ours")
            // Saved or not, for a photo from the library (registered as if opened from Photos).
            if let src = items.first(where: { $0.name == "sale-sign.jpg" })?.url {
                let folder = PhotosLibrary.folder.appendingPathComponent("selftest-\(UUID().uuidString.prefix(6))")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let file = folder.appendingPathComponent("IMG_0002.jpg")
                try? FileManager.default.copyItem(at: src, to: file)
                PhotosLibrary.shared.registerForTesting(file, isLive: true, savedEdits: e)
                let model = ViewerModel()
                model.setEditsDictionary(file.standardizedFileURL, e)
                model.openFolder(folder, selecting: file, restrictedTo: [file.standardizedFileURL])
                for _ in 0..<100 where model.decoded?.url != file.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
                let reopened = !model.hasUnsavedEdits
                model.updateEdits("Exposure") { $0.exposure = 0.9 }
                let changed = model.hasUnsavedEdits
                model.updateEdits("Revert") { $0 = .identity }
                let reverted = model.hasUnsavedEdits && model.unsavedURLs == [file.standardizedFileURL]
                check(reopened && changed && reverted && model.windowSubtitle.contains("Live Photo from Photos"),
                      "a reopened photo's saved edit isn't unsaved; changing it, or taking it off (a revert in Photos), is")
                check(PhotosLibrary.stillOnly({ var c = EditState(); c.cutout = .subject; return c }()) && !PhotosLibrary.stillOnly(e),
                      "a cutout makes a Live Photo save as a still; light and crop don't")
            }
        }

        // 4f. Paste: a picture on the clipboard becomes a new image in the folder (a private pasteboard, never the user's).
        print("\n[Paste]")
        if let src = items.first(where: { $0.name == "transparent.png" })?.url, let jpeg = items.first(where: { $0.name == "sale-sign.jpg" })?.url {
            let folder = out.appendingPathComponent("paste")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let seed = folder.appendingPathComponent("seed.png")
            try? FileManager.default.copyItem(at: src, to: seed)
            let model = ViewerModel()
            model.openFolder(folder, selecting: seed)
            for _ in 0..<100 where model.decoded?.url != seed.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
            let pb = NSPasteboard(name: NSPasteboard.Name("AOK-ImageTool self-test"))
            defer { pb.releaseGlobally() }
            // A picture (here TIFF data, as many apps copy): a PNG with its transparency.
            pb.clearContents()
            pb.writeObjects([NSImage(contentsOf: src)!])
            model.pasteImage(from: pb)
            let pasted = model.items.first { $0.name.hasPrefix("Pasted Image") }
            let png = pasted.flatMap { try? ImageDecoder.decode(url: $0.url, page: 0, allowHDR: false) }
            check(pasted?.url.pathExtension == "png" && png?.hasTransparentPixels == true && model.currentURL == pasted?.url,
                  "a copied picture is pasted as a new PNG in the folder, transparency kept, and shown (\(pasted?.name ?? "none"))")
            // A JPEG as copied: kept byte for byte.
            pb.clearContents()
            pb.setData(try? Data(contentsOf: jpeg), forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            model.pasteImage(from: pb)
            let asJPEG = model.items.first { $0.name.hasPrefix("Pasted Image") && $0.url.pathExtension == "jpg" }
            check(asJPEG.flatMap { try? Data(contentsOf: $0.url) } == (try? Data(contentsOf: jpeg)), "a copied JPEG is pasted as it was, not re-encoded")
            // Image files copied in Finder: copied in, under their names.
            pb.clearContents()
            pb.writeObjects([jpeg as NSURL])
            model.pasteImage(from: pb)
            check(model.items.contains { $0.name == "sale-sign.jpg" }, "image files copied in Finder are pasted in under their own names")
            pb.clearContents()
            pb.setString("just text", forType: .string)
            check(!ViewerModel.clipboardHasImage(pb), "text on the clipboard isn't taken for a picture")
        }

        // 4g. Copies or not (Settings ▸ Editing ▸ Copies): Extend makes a copy; Black & White switched off replaces the image.
        print("\n[Copies or in place]")
        if let src = items.first(where: { $0.name == "Mountain Lake.heic" })?.url {
            let fm = FileManager.default
            let folder = out.appendingPathComponent("copies")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let lake = folder.appendingPathComponent("Lake.heic")
            try? fm.copyItem(at: src, to: lake)
            let before = try? Data(contentsOf: lake)
            let model = ViewerModel()
            model.stacksEnabled = true
            model.openFolder(folder, selecting: lake)
            for _ in 0..<100 where model.decoded?.url != lake.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
            if let d = model.decoded {
                var e = EditState()
                e.crop = CGRect(x: -0.15, y: 0, width: 1.3, height: 1)
                e.extendSeed = 5
                model.saveExtendedCopy(url: lake.standardizedFileURL, decoded: d, edits: e)
                let extended = folder.appendingPathComponent("Lake (Extended).heic")
                for _ in 0..<600 where !fm.fileExists(atPath: extended.path) || model.items.count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
                let width = ImageDecoder.header(url: extended)?.pixelSize.width ?? 0
                check(abs(width - d.pixelSize.width * 1.3) < 3 && (try? Data(contentsOf: lake)) == before && model.edits[lake.standardizedFileURL] == nil
                      && ImageStacks.source(of: extended) == "Lake.heic",
                      "Extend makes a copy (\(Int(width)) px wide), stacked; the original stays as it was")
            }
            // Extend after a crop starts from the crop: the cropped picture is saved first, and Extend opens on it.
            model.select(lake.standardizedFileURL)
            for _ in 0..<100 where model.decoded?.url != lake.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
            if let d = model.decoded {
                model.updateEdits("Crop") { $0.crop = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5) }
                model.beginExtend(.match)
                let cropped = folder.appendingPathComponent("Lake (Cropped).heic").standardizedFileURL
                for _ in 0..<300 where model.activeTool != .crop || model.currentURL != cropped { try? await Task.sleep(for: .milliseconds(100)) }
                let size = ImageDecoder.header(url: cropped)?.pixelSize ?? .zero
                check(abs(size.width - d.pixelSize.width * 0.6) < 3 && abs(size.height - d.pixelSize.height * 0.5) < 3
                      && model.currentURL == cropped && model.activeTool == .crop && ImageStacks.source(of: cropped) == "Lake.heic"
                      && model.edits[lake.standardizedFileURL]?.crop != nil,
                      "Extend after a crop saves “Lake (Cropped)” (\(Int(size.width))×\(Int(size.height))) and extends that")
                model.activeTool = nil
                model.select(lake.standardizedFileURL)
                model.updateEdits("Uncrop") { $0.crop = nil }
            }
            // Black & White in place.
            Prefs.setBool(false, CopyOperation.blackAndWhite.key)
            Prefs.setBool(false, PrefKey.confirmOverwrite)
            Prefs.setBool(false, PrefKey.trashOriginalOnSave)   // (never the user's Trash)
            model.select(lake.standardizedFileURL)   // (the original, under its extended copy in a closed stack)
            for _ in 0..<100 where model.decoded?.url != lake.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
            check(model.currentURL == lake.standardizedFileURL && model.items.count == 1, "a picture in a closed stack can be gone to")
            model.saveBlackAndWhite(BlackAndWhite())
            for _ in 0..<200 where (try? Data(contentsOf: lake)) == before { try? await Task.sleep(for: .milliseconds(100)) }
            for _ in 0..<50 where model.savingURLs.contains(lake.standardizedFileURL) { try? await Task.sleep(for: .milliseconds(100)) }
            let gray: Bool = {
                guard let image = try? ImageDecoder.decode(url: lake, page: 0, allowHDR: false) else { return false }
                let px = rgbaPixels(VisionServices.downscaledSync(image.cgImage, maxDimension: 64))
                return stride(from: 0, to: px.count, by: 4).allSatisfy { abs(Int(px[$0]) - Int(px[$0 + 2])) < 6 }
            }()
            check(gray && !fm.fileExists(atPath: folder.appendingPathComponent("Lake (Black & White).heic").path),
                  "with copies off, Black & White makes the image itself black and white\(model.alert.map { " (alert: \($0.title): \($0.message))" } ?? "")")
        }

        // 5. Pending edits survive a relaunch, but not a change to the file.
        print("\n[Pending edits]")
        if let src = items.first(where: { $0.name == "sale-sign.jpg" })?.url {
            let fm = FileManager.default
            let edited = out.appendingPathComponent("pending.jpg").standardizedFileURL
            let selected = out.appendingPathComponent("pending-object.jpg").standardizedFileURL
            try? fm.copyItem(at: src, to: edited)
            try? fm.copyItem(at: src, to: selected)
            func modDate(_ url: URL) -> Date? {
                try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            var e = EditState()
            e.exposure = 0.5
            e.cutout = .subject
            e.background = .blur(amount: 0.3)
            var objectOnly = EditState()
            objectOnly.cutout = .object(UUID())
            let storeURL = out.appendingPathComponent("PendingEdits.json")
            let store = PendingEdits(fileURL: storeURL)
            store.set(e, for: edited, modificationDate: modDate(edited))
            store.set(objectOnly, for: selected, modificationDate: modDate(selected))
            store.flush()
            let restored = PendingEdits(fileURL: storeURL).restore(in: out, recursive: false, restrictedTo: nil)
            check(restored == [edited: e], "edits restored from disk; object-only cutout dropped")
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: edited.path)
            let reloaded = PendingEdits(fileURL: storeURL)
            check(reloaded.restore(in: out, recursive: false, restrictedTo: nil).isEmpty, "edits dropped once the file changes")
            reloaded.flush()
            check(!fm.fileExists(atPath: storeURL.path), "empty store removes its file")
        }
        if let fox = decodedByName["Red Fox.heic"] {
            var e = EditState()
            e.cutout = .subject
            MaskStore.shared.forget(fox.url)
            try? await MaskStore.shared.prepare(e, for: fox)
            check(MaskStore.shared.subjectMask(for: fox.url) != nil, "restored background removal recomputes its subject mask")
        }

        // 6. Backgrounds behind a cutout.
        print("\n[Backgrounds]")
        if let fox = decodedByName["Red Fox.heic"] {
            /// RGBA (sRGB) of the pixel at (x, y), counted from the top left.
            func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
                var px = [UInt8](repeating: 0, count: 4)
                let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
                return px
            }
            func corner(_ background: Backdrop?) -> [UInt8] {
                var e = EditState()
                e.cutout = .subject
                e.background = background
                guard let out = EditRenderer.shared.renderSync(fox, edits: e, maxDimension: nil) else { return [] }
                return pixel(out.image, 2, 2)
            }
            try? await MaskStore.shared.prepare({ var e = EditState(); e.cutout = .subject; return e }(), for: fox)
            check(corner(nil).last == 0, "cutout alone leaves the corner transparent")
            let red = corner(.color(red: 1, green: 0, blue: 0, alpha: 1))
            check(red.count == 4 && red[0] > 235 && red[1] < 25 && red[2] < 25 && red[3] == 255, "color background shows red, opaque \(red)")
            check(corner(.blur(amount: 0.5)).last == 255, "blurred background is opaque")
            let picture = out.appendingPathComponent("backdrop.png")
            let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            try? ImageWriter.write(ctx.makeImage()!, to: picture, format: .png, quality: 1, sourceProperties: [:], metadata: .keepAll)
            let blue = corner(.image(path: picture.path))
            check(blue.count == 4 && blue[2] > 235 && blue[0] < 25 && blue[3] == 255, "picture background fills the frame \(blue)")
            var opaque = EditState()
            opaque.cutout = .subject
            opaque.background = .color(red: 1, green: 1, blue: 1, alpha: 1)
            check(!opaque.hasTransparency, "opaque background means no transparency (JPEG can save in place)")

            // Transparency baked into a file (a saved cutout or an upscaled copy of one): backgrounds use its alpha.
            if let baked = EditRenderer.shared.renderSync(fox, edits: { var e = EditState(); e.cutout = .subject; return e }(), maxDimension: nil)?.image {
                let file = out.appendingPathComponent("baked-cutout.png")
                try? ImageWriter.write(baked, to: file, format: .png, quality: 1, sourceProperties: [:], metadata: .keepAll)
                if let reopened = try? ImageDecoder.decode(url: file, page: 0, allowHDR: false) {
                    check(reopened.hasTransparentPixels, "a saved cutout reopens with transparent pixels")
                    var e = EditState()
                    e.background = .color(red: 1, green: 0, blue: 0, alpha: 1)
                    if let filled = EditRenderer.shared.renderSync(reopened, edits: e, maxDimension: nil)?.image {
                        let c = pixel(filled, 2, 2)
                        check(c.count == 4 && c[0] > 235 && c[1] < 25 && c[3] == 255, "background fills a file's own transparency, no cutout needed \(c)")
                        let (cx, cy) = (Int(0.72 * Double(baked.width)), Int(0.42 * Double(baked.height)))   // the fox's chest
                        let face = (pixel(filled, cx, cy), pixel(baked, cx, cy))
                        check(zip(face.0, face.1).allSatisfy { abs(Int($0) - Int($1)) <= 3 }, "the subject itself is unchanged \(face.0) vs \(face.1)")
                    } else {
                        check(false, "render a background behind baked transparency")
                    }
                }
            }
            if let sign = decodedByName["sale-sign.jpg"], let png = decodedByName["transparent.png"] {
                check(!sign.hasTransparentPixels && png.hasTransparentPixels, "transparency detection: JPEG opaque, transparent PNG see-through")
            }

            // Matching the subject's light to a dark, stormy picture pulls its brightness toward the picture's.
            if let storm = decodedByName["Rainy Street.heic"] {
                func brightness(_ image: CGImage, _ rect: CGRect) -> Double {
                    let w = Int(rect.width), h = Int(rect.height)
                    var px = [UInt8](repeating: 0, count: w * h * 4)
                    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    ctx.draw(image, in: CGRect(x: -rect.minX, y: rect.maxY - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
                    var sum = 0
                    for i in stride(from: 0, to: px.count, by: 4) { sum += Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) }
                    return Double(sum) / Double(w * h * 3)
                }
                var e = EditState()
                e.cutout = .subject
                e.background = .image(path: storm.url.path)
                let plain = EditRenderer.shared.renderSync(fox, edits: e, maxDimension: nil)?.image
                e.matchLighting = 1
                let matched = EditRenderer.shared.renderSync(fox, edits: e, maxDimension: nil)?.image
                if let plain, let matched {
                    let w = CGFloat(plain.width), h = CGFloat(plain.height)
                    let center = CGRect(x: 0.62 * w, y: 0.32 * h, width: 0.18 * w, height: 0.16 * h)   // the fox's chest
                    let (before, after, sky) = (brightness(plain, center), brightness(matched, center), brightness(plain, CGRect(x: 0, y: 0, width: 40, height: 40)))
                    check(abs(after - sky) < abs(before - sky),
                          String(format: "matched lighting moves the subject toward the background (%.0f → %.0f, background %.0f)", before, after, sky))
                    try? ImageWriter.write(plain, to: out.appendingPathComponent("lighting-off.png"), format: .png, quality: 1, sourceProperties: [:], metadata: .keepAll)
                    try? ImageWriter.write(matched, to: out.appendingPathComponent("lighting-on.png"), format: .png, quality: 1, sourceProperties: [:], metadata: .keepAll)
                } else {
                    check(false, "render with matched lighting")
                }
            }
        }

        // 6b. Extend: content-aware fill beyond the image's edges.
        print("\n[Extend]")
        func rgbaPixels(_ image: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return px
        }
        /// Mean absolute RGB difference between columns x and x+1.
        func columnStep(_ px: [UInt8], width: Int, height: Int, at x: Int) -> Double {
            var sum = 0
            for y in 0..<height {
                let a = (y * width + x) * 4, b = a + 4
                for c in 0..<3 { sum += abs(Int(px[a + c]) - Int(px[b + c])) }
            }
            return Double(sum) / Double(height * 3)
        }
        for name in ["Mountain Lake.heic", "Desert Canyon.heic", "Sunflowers.heic"] {
            guard let d = decodedByName[name] else { continue }
            let src: CGImage = {
                // At 768 px, opaque.
                let w = 768, h = 768 * d.cgImage.height / d.cgImage.width
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.interpolationQuality = .high
                ctx.draw(d.cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
                return ctx.makeImage()!
            }()
            let pad = src.width * 3 / 10
            let t0 = Date()
            guard let out = try? ContentAwareFill.extend(src, width: src.width + 2 * pad, height: src.height,
                                                         origin: CGPoint(x: pad, y: 0), avoid: nil, seed: 7) else {
                check(false, "\(name): extend failed")
                continue
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            try? ImageWriter.write(out, to: out_(name), format: .png, quality: 1, sourceProperties: [:], metadata: .keepAll)
            let a = rgbaPixels(out), o = rgbaPixels(src)
            var unchanged = true
            for y in stride(from: 0, to: src.height, by: 7) {
                for x in stride(from: 0, to: src.width, by: 7) {
                    let i = (y * src.width + x) * 4, j = (y * out.width + x + pad) * 4
                    if abs(Int(a[j]) - Int(o[i])) > 1 || abs(Int(a[j + 1]) - Int(o[i + 1])) > 1 { unchanged = false }
                }
            }
            let opaque = stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] == 255 }
            // The join with the original should look like any other pair of neighboring columns.
            let interior = (columnStep(a, width: out.width, height: out.height, at: pad + 10)
                          + columnStep(a, width: out.width, height: out.height, at: pad + src.width / 2)) / 2
            let seam = (columnStep(a, width: out.width, height: out.height, at: pad - 1)
                      + columnStep(a, width: out.width, height: out.height, at: pad + src.width - 1)) / 2
            check(unchanged && opaque && seam < max(interior * 2.2, 4),
                  String(format: "%@ widened 60%% in %.0f ms: original untouched %@, seam step %.1f vs interior %.1f",
                         name, ms, unchanged ? "yes" : "NO", seam, interior))
        }
        func out_(_ name: String) -> URL { out.appendingPathComponent("extend-" + name.replacingOccurrences(of: ".heic", with: ".png")) }

        if let fox = decodedByName["Red Fox.heic"] {
            var e = EditState()
            e.crop = CGRect(x: -0.2, y: 0, width: 1.4, height: 1)
            e.extendSeed = 42
            check(e.cropExtendsBeyondImage && e.needsExtendFill, "a crop past the edges needs a fill")
            let extendedSize = EditRenderer.shared.outputSize(fox, edits: e)
            check(abs(extendedSize.width - fox.pixelSize.width * 1.4) <= 2 && extendedSize.height == fox.pixelSize.height,
                  "extended output is 1.4× wide (\(Int(extendedSize.width))×\(Int(extendedSize.height)))")
            if let unfilled = EditRenderer.shared.renderSync(fox, edits: e, maxDimension: nil)?.image {
                check(rgbaPixels(unfilled)[3] == 0, "until it's filled, the new area is transparent")
            }
            do {
                let made = try await ExtendRenderer.makeFill(fox, edits: e)
                e.extendFill = made.extendFill(try ExtendFillStore.save(made.fill))
                check(!e.needsExtendFill, "the fill covers the crop")
                if let filled = EditRenderer.shared.renderSync(fox, edits: e, maxDimension: nil)?.image,
                   let plain = EditRenderer.shared.renderSync(fox, edits: EditState(), maxDimension: nil)?.image {
                    let f = rgbaPixels(filled), p = rgbaPixels(plain)
                    let (cx, cy) = (plain.width / 2, plain.height / 2)
                    let i = (cy * filled.width + (filled.width - plain.width) / 2 + cx) * 4, j = (cy * plain.width + cx) * 4
                    check(f[3] == 255 && f[f.count - 1] == 255, "filled corners are opaque")
                    check(abs(Int(f[i]) - Int(p[j])) <= 2 && abs(Int(f[i + 1]) - Int(p[j + 1])) <= 2, "the original sits unchanged in the middle")
                    try? ImageWriter.write(filled, to: out.appendingPathComponent("extend-fox.png"), format: .png, quality: 1, sourceProperties: [:], metadata: .keepAll)
                }
                var brighter = e
                brighter.exposure = 0.7
                check(!brighter.needsExtendFill, "adjustments after Extend reuse the fill (applied to the fill too)")
                var rotated = e
                rotated.rotate(clockwise: true)
                var tilted = e
                tilted.straighten = 3
                check(rotated.extendFill == nil && tilted.extendFill == nil && rotated.needsExtendFill && tilted.needsExtendFill,
                      "rotating or straightening asks for a new fill")
                var smaller = e
                smaller.crop = CGRect(x: -0.1, y: 0.1, width: 1.1, height: 0.8)
                check(!smaller.needsExtendFill, "a smaller frame inside the filled canvas reuses the fill")
                let roundTrip = try? JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(e))
                check(roundTrip == e, "Extend edits survive encoding (pending edits)")
            } catch {
                check(false, "extend fox: \(error.localizedDescription)")
            }

            // Through the model: applying an extended crop makes the fill in the background.
            let model = ViewerModel()
            model.openFolder(folder, selecting: fox.url)
            for _ in 0..<100 where model.decoded?.url != fox.url { try? await Task.sleep(for: .milliseconds(50)) }
            var extended = EditState()
            extended.crop = CGRect(x: 0, y: -0.25, width: 1, height: 1.5)
            extended.extendSeed = 9
            model.applyEdits(extended, to: fox.url, undoName: nil, previous: .identity)
            for _ in 0..<200 where model.edits[fox.url]?.needsExtendFill == true { try? await Task.sleep(for: .milliseconds(50)) }
            check(model.edits[fox.url]?.extendFill != nil && model.extendProgress == nil, "the model fills an Extend edit by itself")
            model.applyEdits(.identity, to: fox.url, undoName: nil, previous: extended)
        }

        // 6a2. Black and white: gray, filters that change which colors are light, and toning.
        do {
            // Red, green and blue thirds.
            let stripes = CGContext(data: nil, width: 240, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (i, c) in [(0.85, 0.1, 0.1), (0.1, 0.7, 0.15), (0.1, 0.2, 0.85)].enumerated() {
                stripes.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
                stripes.fill(CGRect(x: i * 80, y: 0, width: 80, height: 120))
            }
            let color = stripes.makeImage()
            func mean(_ bw: BlackAndWhite) -> (r: Double, g: Double, b: Double)? {
                guard let color, let image = EditRenderer.shared.blackAndWhite(color, bw) else { return nil }
                let px = rgbaPixels(image)
                var sum = (r: 0.0, g: 0.0, b: 0.0)
                // The red third.
                for y in (image.height / 3)..<(image.height * 2 / 3) {
                    for x in 0..<(image.width / 3) {
                        let i = (y * image.width + x) * 4
                        sum.r += Double(px[i]); sum.g += Double(px[i + 1]); sum.b += Double(px[i + 2])
                    }
                }
                let n = Double((image.height / 3) * (image.width / 3))
                return (sum.r / n, sum.g / n, sum.b / n)
            }
            let neutral = mean(BlackAndWhite())
            let red = mean(BlackAndWhite(filter: .red))
            let green = mean(BlackAndWhite(filter: .green))
            let sepia = mean(BlackAndWhite(filter: .neutral, toning: .sepia, toningAmount: 1))
            if let neutral, let red, let green, let sepia {
                check(abs(neutral.r - neutral.b) < 1.5 && abs(neutral.g - neutral.b) < 1.5, "black & white is gray")
                check(red.r > green.r + 20, String(format: "a red filter lightens reds (%.0f vs %.0f with green)", red.r, green.r))
                check(sepia.r > sepia.b + 10, "sepia toning warms the grays")
            } else {
                check(false, "black & white renders")
            }
        }

        // 6a3. Colorize (when its model is installed): color from the model, light and detail kept.
        if Colorizer.isInstalled, let fruit = decodedByName["Fruit Bowl.heic"] {
            if let color = EditRenderer.shared.renderSync(fruit, edits: .identity, maxDimension: 512)?.image,
               let bw = EditRenderer.shared.blackAndWhite(color, BlackAndWhite()) {
                do {
                    let t0 = Date()
                    let colored = try await Colorizer.colorize(bw)
                    let a = rgbaPixels(colored), g = rgbaPixels(bw)
                    var chroma = 0.0, lightError = 0.0
                    for i in stride(from: 0, to: a.count, by: 4) {
                        let r = Double(a[i]), gg = Double(a[i + 1]), b = Double(a[i + 2])
                        chroma += max(r, gg, b) - min(r, gg, b)
                        let y = 0.2126 * r + 0.7152 * gg + 0.0722 * b
                        lightError += abs(y - Double(g[i]))
                    }
                    let n = Double(a.count / 4)
                    try? ImageWriter.write(colored, to: out.appendingPathComponent("colorized-fruit.png"), format: .png, quality: 1,
                                           sourceProperties: [:], metadata: .keepAll)
                    check(colored.width == bw.width && chroma / n > 25 && lightError / n < 12,
                          String(format: "colorized a black and white photo in %.1f s: color %.0f, lightness kept within %.1f levels",
                                 Date().timeIntervalSince(t0), chroma / n, lightError / n))
                } catch {
                    check(false, "colorize: \(error.localizedDescription)")
                }
            }
        }

        // 6b2. A scanned print's border: Extend continues the picture inside it; a document's margin is left alone.
        if let lighthouse = decodedByName["Lighthouse.heic"] {
            let w = 600, h = 760
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.93, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(lighthouse.cgImage, in: CGRect(x: 30, y: 60, width: 540, height: 670))   // a wider margin at the bottom, like a print
            let print = ctx.makeImage()!
            let found = PhotoBorder.content(of: print)
            check(found.map { abs($0.minX - 0.05) < 0.02 && abs($0.minY - 30.0 / 760) < 0.02 && abs($0.maxY - 700.0 / 760) < 0.02 } == true,
                  "a print's border is found: picture \(found.map { String(format: "%.3f %.3f %.3f %.3f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none")")
            if let sign = decodedByName["sale-sign.jpg"] {
                check(PhotoBorder.content(of: sign.cgImage) == nil, "a document's margin isn't taken for a print border")
            }
        }

        // 6c. Generative fill: the scheduler and tokenizer always; a real generation when the model is installed.
        print("\n[Generative fill]")
        do {
            var scheduler = DPMSolverMultistepScheduler(steps: 20)
            check(scheduler.timesteps.count == 20 && scheduler.timesteps.first == 999 && scheduler.timesteps.last == 50,
                  "DPM-Solver++ timesteps \(scheduler.timesteps.first ?? -1)…\(scheduler.timesteps.last ?? -1)")
            // With a perfect noise prediction every step, the solver lands exactly on the clean sample.
            var rng = GaussianNoise(seed: 3)
            let clean = (0..<256).map { _ in rng.next() * 0.5 }
            let noise = (0..<256).map { _ in rng.next() }
            var x = scheduler.noised(clean, noise: noise, index: 0)
            for i in scheduler.timesteps.indices {
                let t = scheduler.timesteps[i]
                var product = 1.0
                for k in 0...t {
                    let b = sqrt(0.00085) + (sqrt(0.012) - sqrt(0.00085)) * Double(k) / 999
                    product *= 1 - b * b
                }
                let a = Float(sqrt(product)), s = Float(sqrt(1 - product))
                let eps = (0..<x.count).map { (x[$0] - a * clean[$0]) / s }
                x = scheduler.step(noise: eps, index: i, sample: x)
            }
            let error = zip(x, clean).map { abs($0 - $1) }.max() ?? 1
            check(error < 1e-3, String(format: "solver recovers the clean sample (max error %.1e)", error))
            var gauss = GaussianNoise(seed: 11)
            let samples = (0..<20000).map { _ in Double(gauss.next()) }
            let mean = samples.reduce(0, +) / Double(samples.count)
            let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count)
            var again = GaussianNoise(seed: 11)
            check(abs(mean) < 0.03 && abs(variance - 1) < 0.05 && again.next() == Float(samples[0]),
                  String(format: "seeded noise: mean %.3f, variance %.3f, reproducible", mean, variance))
            var e = EditState()
            e.crop = CGRect(x: -0.2, y: 0, width: 1.4, height: 1)
            e.extendFill = ExtendFill(path: "/tmp/x.heic", canvas: e.crop!)
            var generated = e
            generated.extendMethod = .generate
            var prompted = generated
            prompted.extendPrompt = "a beach"
            check(generated.extendFill == nil && prompted.extendSourceKey != generated.extendSourceKey && e.extendSourceKey != generated.extendSourceKey,
                  "changing the fill method or prompt asks for a new fill")
            var brighter = prompted
            brighter.exposure = 1
            check(brighter.extendSourceKey == prompted.extendSourceKey, "adjustments don't change what a generated fill is made from")
        }
        if GenerativeModel.isInstalled, let lighthouse = decodedByName["Lighthouse.heic"] {
            do {
                let dir = GenerativeModel.directory
                let tokenizer = try CLIPTokenizer(vocabulary: dir.appendingPathComponent("vocab.json"), merges: dir.appendingPathComponent("merges.txt"))
                let ids = tokenizer.encode("a photo of a sunny beach, palm trees")
                check(Array(ids.prefix(11)) == [49406, 320, 1125, 539, 320, 5438, 2117, 267, 8612, 4682, 49407] && ids.count == 77,
                      "CLIP tokenizer matches the reference ids")

                var e = EditState()
                e.crop = CGRect(x: -0.25, y: 0, width: 1.5, height: 1)
                e.extendSeed = 42
                e.extendMethod = .generate
                let t0 = Date()
                let made = try await ExtendRenderer.makeFill(lighthouse, edits: e)
                let seconds = Date().timeIntervalSince(t0)
                let fill = made.fill
                try? ImageWriter.write(fill, to: out.appendingPathComponent("generate-" + lighthouse.url.deletingPathExtension().lastPathComponent + ".png"),
                                       format: .png, quality: 1, sourceProperties: [:], metadata: .keepAll)
                let px = rgbaPixels(fill)
                let pad = Int((0.25 * CGFloat(fill.width) / 1.5).rounded())
                let opaque = stride(from: 3, to: px.count, by: 4).allSatisfy { px[$0] == 255 }
                let interior = (columnStep(px, width: fill.width, height: fill.height, at: pad / 2)
                              + columnStep(px, width: fill.width, height: fill.height, at: fill.width / 2)) / 2
                let seam = (columnStep(px, width: fill.width, height: fill.height, at: pad - 1)
                          + columnStep(px, width: fill.width, height: fill.height, at: fill.width - pad - 1)) / 2
                check(opaque && made.canvas == e.crop && seam < max(interior * 2.5, 5),
                      String(format: "generated a %d×%d fill in %.1f s: seam step %.1f vs interior %.1f", fill.width, fill.height, seconds, seam, interior))
                let t1 = Date()
                _ = try await ExtendRenderer.makeFill(lighthouse, edits: e)
                check(Date().timeIntervalSince(t1) < 3, String(format: "the same edits reuse the generation (%.2f s)", Date().timeIntervalSince(t1)))
                check(made.feather != nil, "the photo cross-fades into a generated fill")

                // Through the model: a draft shows first, then the final fill replaces it.
                let model = ViewerModel()
                model.openFolder(folder, selecting: lighthouse.url)
                for _ in 0..<100 where model.decoded?.url != lighthouse.url { try? await Task.sleep(for: .milliseconds(50)) }
                var other = e
                other.extendSeed = 77
                model.applyEdits(other, to: lighthouse.url, undoName: nil, previous: .identity)
                var sawDraft = false
                for _ in 0..<1800 where model.edits[lighthouse.url]?.needsExtendFill == true {
                    if model.edits[lighthouse.url]?.extendFill?.isDraft == true { sawDraft = true }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let final = model.edits[lighthouse.url]?.extendFill
                check(sawDraft && final != nil && final?.isDraft == nil && final?.feather != nil,
                      "a draft shows while the final generated fill is made, then the final replaces it")
                model.applyEdits(.identity, to: lighthouse.url, undoName: nil, previous: other)

                // A background painted around a cut-out subject, at the photo's proportions.
                if let fox = decodedByName["Red Fox.heic"], let mask = try? await VisionServices.subjectMask(for: fox.cgImage) {
                    let t2 = Date()
                    let scene = try await GenerativeImage.background(fox.cgImage, subject: mask, scene: "a forest at dusk",
                                                                     subjectDescription: "a red fox", seed: 3)
                    try? ImageWriter.write(scene, to: out.appendingPathComponent("generated-background-fox.png"), format: .png, quality: 1,
                                           sourceProperties: [:], metadata: .keepAll)
                    let ratio = Double(scene.width) / Double(scene.height), expected = Double(fox.cgImage.width) / Double(fox.cgImage.height)
                    check(abs(ratio - expected) < 0.01, String(format: "generated a background around the subject: %d×%d in %.1f s",
                                                               scene.width, scene.height, Date().timeIntervalSince(t2)))
                    check(GenerativeImage.backgroundPrompt(scene: "a beach", subject: "an fox") == "a high quality photo of an fox, a beach in the background",
                          "the background prompt names the subject and the scene")
                }
            } catch {
                check(false, "generative fill: \(error.localizedDescription)")
            }
        } else {
            print("  • generative model not installed; skipping generation")
        }

        // 6d. Remove Objects.
        print("\n[Remove Objects]")
        if let boat = decodedByName["Sailboat.heic"] { await removeObjectsChecks(boat, out: out) }
        print("\n[Change Objects]")
        if let boat = decodedByName["Sailboat.heic"] { await changeObjectsChecks(boat, out: out) }
        print("\n[Clone & Heal]")
        await cloneHealChecks(out: out)
        print("\n[White Balance]")
        await whiteBalanceChecks(out: out)
        print("\n[New Image]")
        await newImageChecks(out: out)
        print("\n[Ratings, captions, Copy Edits]")
        await tagsChecks(out: out)
        print("\n[Combine Pictures]")
        await combineChecks(folder: folder, out: out)

        // 6e. Fix Blur.
        print("\n[Fix Blur]")
        if let harbor = decodedByName["Harbor Village.heic"] { await fixBlurChecks(harbor, out: out) }

        // 7. Vision.
        print("\n[Vision]")
        if let lake = decodedByName["Mountain Lake.heic"] {
            // What the system's analyzers get: a plain 8-bit copy of their own, even of a floating-point picture.
            let rect = CGRect(x: 0, y: 0, width: lake.cgImage.width, height: lake.cgImage.height)
            if let float = ImageDecoder.ciContext.createCGImage(CIImage(cgImage: lake.cgImage), from: rect, format: .RGBAf,
                                                                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)) {
                let copy = VisionServices.plainCopySync(float, maxDimension: 1024)
                let same = VisionServices.plainCopySync(lake.cgImage)
                check(copy.bitsPerComponent == 8 && max(copy.width, copy.height) == 1024 && copy.colorSpace?.name == CGColorSpace.sRGB
                      && same.width == lake.cgImage.width && same !== lake.cgImage,
                      "Live Text and Vision get a plain 8-bit copy of their own (\(float.bitsPerComponent)-bit float → \(copy.bitsPerComponent)-bit)")
            }
        }
        if let fox = decodedByName["Red Fox.heic"] {
            do {
                let mask = try await VisionServices.subjectMask(for: fox.cgImage)
                let bounds = VisionServices.maskBounds(mask, imageSize: fox.pixelSize)
                check(bounds != nil, "subject mask \(Int(mask.extent.width))×\(Int(mask.extent.height)), bounds \(bounds.map { "\($0.integral)" } ?? "none")")
                let png = try await IntelligenceModel().cutoutPNG(of: fox, mask: mask)
                check(png.count > 1000, "cutout PNG \(png.count / 1024) KB")
            } catch {
                check(false, "subject mask: \(error.localizedDescription)")
            }
            let small = VisionServices.downscaledSync(fox.cgImage, maxDimension: 512)
            if #available(macOS 27, *), let obj = try? await VisionServices.objectMask(for: small, included: [CGPoint(x: 0.75, y: 0.5)], excluded: []) {
                check(true, "click-to-select (iterative segmentation) mask \(Int(obj.extent.width))×\(Int(obj.extent.height))")
            } else {
                print("  • iterative segmentation unavailable; trying the instance fallback")
            }
            // The macOS 15/26 path: pick the foreground instance under the click.
            let inst = try? await VisionServices.instanceMask(for: small, at: CGPoint(x: 0.75, y: 0.5))
            check(inst != nil, "click-to-select fallback (foreground instance under the click)")
        }
        var prints: [(URL, Data)] = []
        for name in ["sale-sign.jpg", "Sailboat.heic", "Sailboat-dup.jpg", "Red Fox.heic", "Hummingbird.heic"] {
            guard let item = items.first(where: { $0.name == name }), let thumb = ImageDecoder.thumbnail(url: item.url, maxPixelSize: 768) else { continue }
            let r = await VisionServices.analyzeForIndex(thumb)
            if let fp = r.featurePrint { prints.append((item.url, fp)) }
            print("  • \(name): labels [\(r.labels.prefix(5).joined(separator: ", "))] score \(r.score.map { String(format: "%.2f", $0) } ?? "-") utility \(r.isUtility.map { "\($0)" } ?? "-") text “\(r.text.prefix(40).replacingOccurrences(of: "\n", with: " / "))”")
            if name == "sale-sign.jpg" { check(r.text.localizedCaseInsensitiveContains("Grand Opening"), "OCR reads the sign") }
            if name == "Red Fox.heic" { check(r.labels.contains { $0.contains("fox") || $0.contains("canine") }, "classifier recognizes the fox") }
        }
        if let boat = prints.first(where: { $0.0.lastPathComponent == "Sailboat.heic" }) {
            let d = VisionServices.distances(from: boat.1, to: prints)
            for (url, dist) in d.sorted(by: { $0.value < $1.value }) { print(String(format: "  • distance Sailboat → %@: %.3f", url.lastPathComponent, dist)) }
            let groups = VisionServices.clusterDuplicates(prints, threshold: 0.3)
            check(groups.contains { Set($0.map(\.lastPathComponent)) == ["Sailboat.heic", "Sailboat-dup.jpg"] }, "duplicate detection groups the sailboat copies only")
        }
        if let bird = decodedByName["Hummingbird.heic"], let salient = await VisionServices.salientRegion(bird.cgImage) {
            let crop = IntelligenceModel.cropRect(around: salient, imageSize: bird.pixelSize)
            print("  • hummingbird salient \(salient), smart crop \(crop.map { "\($0)" } ?? "none (well framed)")")
        }
        // Straightening: a sea horizon turned by known angles should be measured back, and a picture with
        // no straight lines (lightning) should get no answer rather than a wrong one.
        await straightenChecks(decodedByName: decodedByName)
        print("  • query expansion puppy → \(QueryExpander.shared.variants(of: "puppy"))")

        // 8. Folder index → content search, best-shot ranking, duplicates (through the real model).
        print("\n[Search & ranking]")
        let model = ViewerModel()
        model.stacksEnabled = false    // every match by itself, copies too
        model.openFolder(folder, selecting: nil)
        for _ in 0..<100 where model.isScanning || model.allItems.count < items.count {
            try? await Task.sleep(for: .milliseconds(100))
        }
        model.intelligence.ensureIndexed(reason: .search)
        let t0 = Date()
        for _ in 0..<600 where model.intelligence.isIndexing {
            try? await Task.sleep(for: .milliseconds(200))
        }
        print(String(format: "  • indexed %d images in %.1f s", model.intelligence.indexedCount, Date().timeIntervalSince(t0)))
        func search(_ q: String) -> Set<String> {
            model.searchText = q
            return Set(model.items.map(\.name))
        }
        let foxes = search("fox")
        check(foxes == ["Red Fox.heic"], "“fox” → \(foxes.sorted())")
        let sign = search("grand opening")
        check(sign == ["sale-sign.jpg"], "“grand opening” (text in image) → \(sign.sorted())")
        let birds = search("bird")
        check(birds.contains("Hummingbird.heic"), "“bird” → \(birds.sorted())")
        let kitten = search("kitten")
        check(kitten.contains("Sleeping Cat.heic"), "“kitten” (expanded to cat) → \(kitten.sorted())")
        model.searchText = ""
        model.sortKey = .quality
        print("  • best shots: \(model.items.prefix(4).map(\.name))")
        check(model.items.last.map { $0.name == "sale-sign.jpg" || $0.name == "brochure.pdf" || $0.name == "pages.tiff" } ?? false,
              "utility images rank last (\(model.items.suffix(2).map(\.name)))")
        model.sortKey = .name
        await shotQualityChecks(folder: folder, out: out)
        model.intelligence.computeDuplicates()
        for _ in 0..<50 where model.intelligence.isFindingDuplicates { try? await Task.sleep(for: .milliseconds(100)) }
        print("  • duplicate groups: \(model.intelligence.duplicateGroups.map { $0.urls.map(\.lastPathComponent) })")

        // 9. Apple Intelligence.
        print("\n[Apple Intelligence]")
        print("  • support: \(ImageDescriber.support)")
        check(SuperResolution.fits(width: 1920, height: 1920) && !SuperResolution.fits(width: 1921, height: 10)
              && SuperResolution.canUpscale(width: 4000, height: 3000, scale: 4) && !SuperResolution.canUpscale(width: 5000, height: 10, scale: 4),
              "AI upscaling: one pass up to 1920 px, tiles beyond, results up to 16384 px")
        let upscaling = SuperResolution.modelState
        print("  • AI upscaling model: \(upscaling)")
        if upscaling == .ready, let d = decodedByName["rotated-exif6.jpg"], let png = decodedByName["transparent.png"] {
            let small = VisionServices.downscaledSync(d.cgImage, maxDimension: 300)
            do {
                let t0 = Date()
                let big = try await SuperResolution.upscale(small)
                check(big.width == small.width * 4 && big.height == small.height * 4,
                      String(format: "upscaled %d×%d → %d×%d in %.0f ms", small.width, small.height, big.width, big.height, Date().timeIntervalSince(t0) * 1000))
                for scale in [2, 3] {
                    let out = try await SuperResolution.upscale(small, scale: CGFloat(scale))
                    check(out.width == small.width * scale && out.height == small.height * scale, "\(scale)× upscale → \(out.width)×\(out.height)")
                }
                let clear = try await SuperResolution.upscale(VisionServices.downscaledSync(png.cgImage, maxDimension: 200))
                check(!(clear.alphaInfo == .none || clear.alphaInfo == .noneSkipLast || clear.alphaInfo == .noneSkipFirst), "transparent image keeps its alpha when upscaled")
                // An animation, every frame, keeping its timing and looping (GIF and animated PNG).
                if let spinner = items.first(where: { $0.name == "spinner.gif" }), let animation = Animation(url: spinner.url) {
                    for container in Animation.Container.allCases {
                        let url = out.appendingPathComponent("spinner-2x.\(container.fileExtension)")
                        let t2 = Date()
                        let writer = try Animation.Writer(url: url, container: container, delays: animation.delays, loopCount: animation.loopCount)
                        try await SuperResolution.upscaleFrames(count: animation.count, width: animation.width, height: animation.height, scale: 2,
                                                                frame: { i in
                            guard let frame = animation.frame(i) else { throw SuperResolution.Failure.failed }
                            return frame
                        }, emit: { writer.add($0) }, progress: { _ in false })
                        try writer.finish()
                        let made = Animation(url: url)
                        let firstFrames = made.flatMap { m in m.frame(0).flatMap { a in m.frame(6).map { (a, $0) } } }
                        let moved = firstFrames.map { rgbaPixels($0.0) != rgbaPixels($0.1) } ?? false
                        check(made?.count == animation.count && made?.width == animation.width * 2 && made?.height == animation.height * 2
                              && made?.loopCount == animation.loopCount
                              && zip(made?.delays ?? [], animation.delays).allSatisfy { abs($0 - $1) < 0.005 } && moved,
                              String(format: "%@: %d frames upscaled to %d×%d in %.1f s, timing and looping kept", container.title,
                                     made?.count ?? 0, made?.width ?? 0, made?.height ?? 0, Date().timeIntervalSince(t2)))
                    }
                    // Through the app: a cropped animation, upscaled, saved beside it and stacked on it.
                    let folder = out.appendingPathComponent("animation")
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let copy = folder.appendingPathComponent("spinner.gif")
                    try? FileManager.default.copyItem(at: spinner.url, to: copy)
                    let model = ViewerModel()
                    model.stacksEnabled = true
                    model.openFolder(folder, selecting: copy)
                    for _ in 0..<100 where model.decoded?.url != copy.standardizedFileURL { try? await Task.sleep(for: .milliseconds(50)) }
                    model.updateEdits("Crop") { $0.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1) }
                    model.upscaleCurrent(by: 2)
                    let made = folder.appendingPathComponent("spinner (2×).gif")
                    for _ in 0..<600 where !FileManager.default.fileExists(atPath: made.path) || model.items.count < 2 {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    let result = Animation(url: made)
                    check(result?.count == animation.count && result?.width == animation.width && result?.height == animation.height * 2
                          && ImageStacks.source(of: made) == "spinner.gif" && model.stacks.count == 1,
                          "Upscale with AI on a cropped animation: \(result?.count ?? 0) frames, \(result?.width ?? 0)×\(result?.height ?? 0), stacked on the original")
                    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".") }
                    check(leftovers.isEmpty, "the file appears whole (no temporary left)")
                    // A copy's thumbnail is made from the picture just made (the cache may let it go later, under memory pressure).
                    if let frame = Animation(url: made)?.frame(0) {
                        let probe = folder.appendingPathComponent("probe.gif")
                        ThumbnailCache.shared.seed(frame, for: probe)
                        check(ThumbnailCache.shared.cached(probe, tier: .small).map { max($0.width, $0.height) } == 160
                              && ThumbnailCache.shared.cached(probe, tier: .large) != nil, "a copy's thumbnails are ready without reading it back")
                    }
                    // Limits: a 57-frame 480 × 480 animation, like a typical GIF from the web.
                    let gif2 = Animation.upscaleEstimate(frames: 57, width: 480, height: 480, scale: 2, as: .gif)
                    let gif3 = Animation.upscaleEstimate(frames: 57, width: 480, height: 480, scale: 3, as: .gif)
                    let png2 = Animation.upscaleEstimate(frames: 57, width: 480, height: 480, scale: 2, as: .png)
                    let small = Animation.upscaleEstimate(frames: animation.count, width: CGFloat(animation.width), height: CGFloat(animation.height),
                                                          scale: 4, as: .png)
                    check(gif2.allowed && !gif3.allowed && !png2.allowed && small.allowed,
                          "animated upscales are limited: 57 frames of 480 × 480 can go 2× as GIF (about \(gif2.bytes / 1_000_000) MB), not 3×, nor as animated PNG")
                }
                // Bigger than one pass: tiles, joined where both had context.
                if let large = decodedByName.values.first(where: { $0.cgImage.width > SuperResolution.maxSide })?.cgImage {
                    let t1 = Date()
                    let tiled = try await SuperResolution.upscale(large, scale: 2)
                    let px = rgbaPixels(tiled)
                    // Joins sit midway through each overlap of 1024-px tiles that overlap by 64.
                    let count = Int((Double(large.width - 1024) / 960).rounded(.up)) + 1
                    let starts = (0..<count).map { min($0 * 960, large.width - 1024) }
                    let joins = (1..<count).map { 2 * ((starts[$0] + starts[$0 - 1] + 1024) / 2) - 1 }
                    let joinStep = joins.map { columnStep(px, width: tiled.width, height: tiled.height, at: $0) }.max() ?? 0
                    let interior = columnStep(px, width: tiled.width, height: tiled.height, at: 501)
                    check(tiled.width == large.width * 2 && tiled.height == large.height * 2 && joinStep < max(interior * 2.5, 4),
                          String(format: "tiled 2× upscale %d×%d → %d×%d in %.1f s: join step %.1f vs interior %.1f",
                                 large.width, large.height, tiled.width, tiled.height, Date().timeIntervalSince(t1), joinStep, interior))
                }
            } catch {
                check(false, "AI upscale: \(error.localizedDescription)")
            }
        }
        if ImageDescriber.support.isAvailable, let lighthouse = decodedByName["Lighthouse.heic"] {
            let small = VisionServices.downscaledSync(lighthouse.cgImage, maxDimension: 1024)
            let labels = ImageDescriber.support == .vision ? [] : await VisionServices.classify(small)
            let setting = await ImageDescriber.describeSetting(small, labels: labels)
            check(!(setting ?? "").isEmpty, "Extend's setting description: \(setting ?? "none")")
        }
        if ImageDescriber.support.isAvailable, let animal = decodedByName["Red Fox.heic"] {
            do {
                let small = VisionServices.downscaledSync(animal.cgImage, maxDimension: 1024)
                let labels = await VisionServices.classify(small)
                let t0 = Date()
                let desc = try await ImageDescriber.describe(small, labels: labels, text: "")
                print(String(format: "  • %.1f s", Date().timeIntervalSince(t0)))
                print("  • title: \(desc.title)\n  • caption: \(desc.caption)\n  • keywords: \(desc.keywords)\n  • file name: \(desc.fileName)")
                check(desc.caption.localizedCaseInsensitiveContains("fox") || desc.title.localizedCaseInsensitiveContains("fox"), "description mentions the fox")
            } catch {
                check(false, "describe: \(ImageDescriber.friendlyError(error))")
            }
        }

        for (key, value) in savedPrefs {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }

        print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
        try? FileManager.default.removeItem(at: AppStorageLocation.support)   // this run's isolated storage
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
