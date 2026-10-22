#if DEBUG
import AppKit
import CoreImage
import ImageIO
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
                           PrefKey.includeSubfolders, PrefKey.gridThumbnailSize, PrefKey.showFilmstrip, PrefKey.stackCopies]
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

        // 7. Vision.
        print("\n[Vision]")
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
        do {
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
        }
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
