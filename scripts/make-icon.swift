// Draws AOK-ImageTool's app icon in Foray's style: a bold navy picture frame on a teal tile, a pale
// glass print showing a golden landscape, and a sparkle for the on-device intelligence. Writes:
//   ImageViewer/AppIcon.icon     the layered icon for macOS 26/27 (Icon Composer format: a fill and
//                                glass layers; macOS adds the glass, dark, clear and tinted looks)
//   swift scripts/make-icon.swift [preview.png]   (optionally also a flat 1024 px preview)
import AppKit

let cs = CGColorSpaceCreateDeviceRGB()
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a).cgColor
}
func grad(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient { CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)! }

// Palette (Foray's).
let teal = (top: UInt32(0x0E7C86), bottom: UInt32(0x18C2AE))
let navy = UInt32(0x2D2F7A)
let sky = (UInt32(0xE8FBFF), UInt32(0xB5ECF2))
let goldBack = (UInt32(0xF3C766), UInt32(0xE6A93A)), goldFront = (UInt32(0xFFE29A), UInt32(0xF8C65A))
let sun = UInt32(0xF7A93B)

// Geometry, on a 1024 canvas where the icon square fills the canvas (Icon Composer's layout).
let frameRect = CGRect(x: 105, y: 190, width: 730, height: 570)   // the front frame's outer edge
let rim: CGFloat = 54, corner: CGFloat = 78
let tilt: CGFloat = -0.07                                          // radians; the frame leans right
var pictureRect: CGRect { frameRect.insetBy(dx: rim, dy: rim) }

func render(_ size: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Rotates drawing about the frame's center.
func tilted(_ cg: CGContext, _ angle: CGFloat, _ draw: () -> Void) {
    cg.saveGState()
    cg.translateBy(x: frameRect.midX, y: frameRect.midY)
    cg.rotate(by: angle)
    cg.translateBy(x: -frameRect.midX, y: -frameRect.midY)
    draw()
    cg.restoreGState()
}

func framePath(_ rect: CGRect) -> CGPath {
    let ring = CGMutablePath()
    ring.addRoundedRect(in: rect, cornerWidth: corner, cornerHeight: corner)
    let inner = corner - rim * 0.6
    ring.addRoundedRect(in: rect.insetBy(dx: rim, dy: rim), cornerWidth: inner, cornerHeight: inner)
    return ring
}

func picturePath() -> CGPath {
    let r = corner - rim * 0.6
    return CGPath(roundedRect: pictureRect, cornerWidth: r, cornerHeight: r, transform: nil)
}

// MARK: Layers (each on its own transparent canvas)

/// The glass print: pale sky, like Foray's lens.
func drawPicture(_ cg: CGContext) {
    tilted(cg, tilt) {
        cg.addPath(picturePath()); cg.clip()
        cg.drawLinearGradient(grad([c(sky.0), c(sky.1)]), start: CGPoint(x: 0, y: pictureRect.maxY), end: CGPoint(x: 0, y: pictureRect.minY), options: [])
    }
}

/// The landscape on the print: sun and two golden hills, like Foray's folder.
func drawLandscape(_ cg: CGContext) {
    tilted(cg, tilt) {
        let p = pictureRect
        cg.addPath(picturePath()); cg.clip()
        cg.setFillColor(c(sun))
        cg.fillEllipse(in: CGRect(x: p.minX + 70, y: p.maxY - 175, width: 110, height: 110))
        func mountain(_ peak: CGPoint, _ halfWidth: CGFloat, _ colors: (UInt32, UInt32)) {
            let path = CGMutablePath(), tip: CGFloat = 0.12
            let left = CGPoint(x: peak.x - halfWidth, y: p.minY - 10), right = CGPoint(x: peak.x + halfWidth, y: p.minY - 10)
            func toward(_ a: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: peak.x + (a.x - peak.x) * t, y: peak.y + (a.y - peak.y) * t) }
            path.move(to: left)
            path.addLine(to: toward(left, tip))
            path.addQuadCurve(to: toward(right, tip), control: peak)
            path.addLine(to: right)
            path.closeSubpath()
            cg.saveGState(); cg.addPath(path); cg.clip()
            cg.drawLinearGradient(grad([c(colors.0), c(colors.1)]), start: CGPoint(x: 0, y: peak.y), end: CGPoint(x: 0, y: p.minY), options: [])
            cg.restoreGState()
        }
        mountain(CGPoint(x: p.minX + 405, y: p.minY + 300), 300, goldBack)
        mountain(CGPoint(x: p.minX + 175, y: p.minY + 200), 260, goldFront)
    }
}

/// The frame (Foray's rim).
func drawFrame(_ cg: CGContext) {
    tilted(cg, tilt) {
        cg.addPath(framePath(frameRect))
        cg.setFillColor(c(navy))
        cg.fillPath(using: .evenOdd)
    }
}

/// A four-pointed sparkle at the top right, over the frame's corner.
func drawSparkle(_ cg: CGContext) {
    func star(_ center: CGPoint, _ r: CGFloat) -> CGPath {
        let path = CGMutablePath(), w = r * 0.24
        path.move(to: CGPoint(x: center.x, y: center.y + r))
        path.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y), control: CGPoint(x: center.x + w, y: center.y + w))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r), control: CGPoint(x: center.x + w, y: center.y - w))
        path.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y), control: CGPoint(x: center.x - w, y: center.y - w))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r), control: CGPoint(x: center.x - w, y: center.y + w))
        return path
    }
    let big = CGPoint(x: 815, y: 775)
    cg.saveGState()
    cg.addPath(star(big, 140))
    cg.addPath(star(CGPoint(x: 925, y: 905), 58))
    cg.clip()
    cg.drawLinearGradient(grad([c(goldFront.0), c(goldFront.1)]), start: CGPoint(x: 0, y: 970), end: CGPoint(x: 0, y: 620), options: [])
    cg.restoreGState()
}

// MARK: The flat preview (tile, background, layers, simple shading)

func drawFlat(_ cg: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: c(0x000000, 0.22))
    cg.addPath(path); cg.setFillColor(c(0x000000)); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(path); cg.clip()
    cg.drawLinearGradient(grad([c(teal.top), c(teal.bottom)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.translateBy(x: tile.minX, y: tile.minY)
    cg.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    drawPicture(cg)
    drawLandscape(cg)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 28, color: c(0x000000, 0.35))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    drawFrame(cg)
    cg.endTransparencyLayer()
    cg.restoreGState()
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: c(0x000000, 0.3))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    drawSparkle(cg)
    cg.endTransparencyLayer()
    cg.restoreGState()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(path); cg.clip()
    cg.drawLinearGradient(grad([c(0xffffff, 0.18), c(0xffffff, 0)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    cg.restoreGState()
}

// MARK: Output

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()

/// The layered icon: fill + groups (front to back): sparkle (glass), frame (glass), landscape, picture (glass).
func makeLayeredIcon() throws {
    let icon = root.appendingPathComponent("ImageViewer/AppIcon.icon")
    let assets = icon.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: icon)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let layers: [(String, (CGContext) -> Void)] = [
        ("sparkle", drawSparkle), ("frame", drawFrame), ("landscape", drawLandscape), ("picture", drawPicture),
    ]
    for (name, draw) in layers {
        try render(1024, draw).representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("\(name).png"))
    }
    func layer(_ name: String, glass: Bool) -> [String: Any] {
        ["image-name": "\(name).png", "name": name, "glass": glass,
         "position": ["scale": 1, "translation-in-points": [0, 0]]]
    }
    func group(_ layers: [[String: Any]], shadow: String) -> [String: Any] {
        ["layers": layers, "shadow": ["kind": shadow, "opacity": 0.5], "translucency": ["enabled": true, "value": 0.4]]
    }
    let json: [String: Any] = [
        "fill": ["automatic-gradient": "extended-srgb:0.05490,0.56471,0.58431,1.00000"],
        "groups": [
            group([layer("sparkle", glass: true)], shadow: "layer-color"),
            group([layer("frame", glass: true)], shadow: "layer-color"),
            group([layer("landscape", glass: false)], shadow: "neutral"),
            group([layer("picture", glass: true)], shadow: "neutral"),
        ],
        "supported-platforms": ["squares": ["macOS"]],
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: icon.appendingPathComponent("icon.json"))
    print("ImageViewer/AppIcon.icon")
}

if CommandLine.arguments.count > 1 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    try render(1024, drawFlat).representation(using: .png, properties: [:])!.write(to: preview)
    print(preview.path)
}
if !CommandLine.arguments.contains("--preview-only") {
    try makeLayeredIcon()
}
