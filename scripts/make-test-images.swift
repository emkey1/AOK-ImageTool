// Makes the synthetic files in TestImages (formats, metadata and text the self-test checks), and the two
// copies of a demo photo the duplicate check needs.
//   swift scripts/make-test-images.swift TestImages
import AppKit
import ImageIO
import UniformTypeIdentifiers
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func ctx(_ w: Int, _ h: Int, alpha: Bool = true) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
}
func write(_ images: [CGImage], _ name: String, _ type: UTType, props: [CFString: Any] = [:], frameProps: [CFString: Any] = [:]) {
    let url = dir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)!
    CGImageDestinationSetProperties(dest, props as CFDictionary)
    for i in images { CGImageDestinationAddImage(dest, i, frameProps as CFDictionary) }
    print(name, CGImageDestinationFinalize(dest))
}
func drawText(_ c: CGContext, _ s: String, _ size: CGFloat, _ at: CGPoint, color: NSColor = .black) {
    let g = NSGraphicsContext(cgContext: c, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    (s as NSString).draw(at: at, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color])
    NSGraphicsContext.restoreGraphicsState()
}
// 1. Text image (OCR / Live Text)
do {
    let c = ctx(1600, 1000, alpha: false)
    c.setFillColor(CGColor(red: 0.98, green: 0.96, blue: 0.9, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
    drawText(c, "Grand Opening Sale", 110, CGPoint(x: 120, y: 700))
    drawText(c, "Everything 40% off — Saturday, Nov 7", 64, CGPoint(x: 120, y: 520), color: .systemRed)
    drawText(c, "Visit us at 12 Harbor Road or call (555) 555-0199", 48, CGPoint(x: 120, y: 360), color: .darkGray)
    write([c.makeImage()!], "sale-sign.jpg", .jpeg)
}
// 2. PNG with alpha
do {
    let c = ctx(800, 800)
    c.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.9)); c.fillEllipse(in: CGRect(x: 100, y: 100, width: 600, height: 600))
    c.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1)); c.fill(CGRect(x: 300, y: 300, width: 200, height: 200))
    write([c.makeImage()!], "transparent.png", .png)
}
// 3. Animated GIF
do {
    var frames: [CGImage] = []
    for i in 0..<12 {
        let c = ctx(300, 300)
        c.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        let a = Double(i) / 12 * 2 * .pi
        c.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.2, alpha: 1))
        c.fillEllipse(in: CGRect(x: 125 + 90 * cos(a), y: 125 + 90 * sin(a), width: 50, height: 50))
        frames.append(c.makeImage()!)
    }
    write(frames, "spinner.gif", .gif, props: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]], frameProps: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]])
}
// 4. Multi-page TIFF
do {
    var pages: [CGImage] = []
    for (i, col) in [NSColor.systemTeal, .systemOrange, .systemPurple].enumerated() {
        let c = ctx(900, 600, alpha: false)
        c.setFillColor(col.cgColor); c.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        drawText(c, "Page \(i + 1)", 120, CGPoint(x: 250, y: 230), color: .white)
        pages.append(c.makeImage()!)
    }
    write(pages, "pages.tiff", .tiff, frameProps: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]])   // LZW
}
// 5. Rotated JPEG (EXIF orientation 6) from a landscape drawing with an arrow pointing up when displayed correctly
do {
    // Displayed image should be portrait 600x900 with "UP ↑" text upright. Store as landscape rotated 90° CCW.
    let disp = ctx(600, 900, alpha: false)
    disp.setFillColor(NSColor.systemGreen.cgColor); disp.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
    drawText(disp, "UP ↑", 140, CGPoint(x: 140, y: 600), color: .white)
    drawText(disp, "orientation 6", 50, CGPoint(x: 140, y: 200), color: .white)
    let upright = disp.makeImage()!
    let stored = ctx(900, 600, alpha: false)
    stored.translateBy(x: 0, y: 600); stored.rotate(by: -.pi / 2)   // rotate content 90° CCW... stored = upright rotated CCW
    stored.draw(upright, in: CGRect(x: 0, y: 0, width: 600, height: 900))
    write([stored.makeImage()!], "rotated-exif6.jpg", .jpeg, frameProps: [kCGImagePropertyOrientation: 6,
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 122.0090, kCGImagePropertyGPSLongitudeRef: "W"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 1.78, kCGImagePropertyExifExposureTime: 1.0/120, kCGImagePropertyExifISOSpeedRatings: [80], kCGImagePropertyExifFocalLenIn35mmFilm: 24, kCGImagePropertyExifDateTimeOriginal: "2026:10:01 09:15:00"]])
}
// 6. PDF (2 pages)
do {
    let url = dir.appendingPathComponent("brochure.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pc = CGContext(url as CFURL, mediaBox: &box, nil)!
    for i in 1...2 {
        pc.beginPDFPage(nil)
        pc.setFillColor(NSColor.white.cgColor); pc.fill(box)
        pc.setFillColor(NSColor.systemIndigo.cgColor); pc.fill(CGRect(x: 40, y: 600, width: 532, height: 150))
        drawText(pc, "Brochure page \(i)", 40, CGPoint(x: 60, y: 650), color: .white)
        pc.endPDFPage()
    }
    pc.closePDF(); print("brochure.pdf ok")
}
// 7. SVG
try! """
<svg xmlns="http://www.w3.org/2000/svg" width="400" height="300" viewBox="0 0 400 300">
<defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="#ff7a59"/><stop offset="1" stop-color="#7a5cff"/></linearGradient></defs>
<rect width="400" height="300" rx="30" fill="url(#g)"/><circle cx="200" cy="150" r="80" fill="white" opacity="0.85"/>
<text x="200" y="165" font-size="42" text-anchor="middle" font-family="Helvetica" font-weight="bold" fill="#333">SVG</text></svg>
""".write(to: dir.appendingPathComponent("vector.svg"), atomically: true, encoding: .utf8)
// 8. A demo photo again, smaller and as JPEG (a near-duplicate), and as AVIF.
do {
    let src = CGImageSourceCreateWithURL(dir.appendingPathComponent("Sailboat.heic") as CFURL, nil)!
    let small = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary)!
    write([small], "Sailboat-dup.jpg", .jpeg, frameProps: [kCGImageDestinationLossyCompressionQuality: 0.7])
    let waterfall = CGImageSourceCreateWithURL(dir.appendingPathComponent("Waterfall.heic") as CFURL, nil)!
    let medium = CGImageSourceCreateThumbnailAtIndex(waterfall, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary)!
    write([medium], "Waterfall.avif", UTType("public.avif")!)
}
print("done")
