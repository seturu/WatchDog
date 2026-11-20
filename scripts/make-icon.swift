// Draws WatchDog's app icon and writes every size macOS wants into
// App/Assets.xcassets/AppIcon.appiconset. Run from the project root:
//
//   swift scripts/make-icon.swift
//
// The icon is code so it can be tweaked and regenerated; no design tool needed.
import AppKit

let canvas: CGFloat = 1024
// Apple's macOS icon grid: the rounded square occupies 824 of 1024 points,
// leaving room for the system-drawn shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

func drawIcon() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Soft drop shadow under the body.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    shape.fill()
    context.restoreGState()

    // Body: deep indigo falling to near-black, lit from above.
    context.saveGState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.34, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.48, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.04, blue: 0.16, alpha: 1),
    ])!.draw(in: body, angle: -90)

    // A faint glow behind the eye.
    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    glow.draw(fromCenter: CGPoint(x: 512, y: 560), radius: 0, toCenter: CGPoint(x: 512, y: 560), radius: 420, options: [])

    // Top edge highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.maxY - 220, width: body.width, height: 220), angle: -90)
    context.restoreGState()

    // The eye, drawn here from plain curves. (Not an SF Symbol: Apple's terms
    // rule out SF Symbols, or anything confusingly similar, in app icons and
    // logos.) An open lens, an iris that doubles as a timer ring with its last
    // stretch still to run, and a pupil.
    let eye = CGPoint(x: 512, y: 520)
    // Strokes are thick enough to stay a crisp line at 16 x 16.
    let half: CGFloat = 305, lift: CGFloat = 275
    let lens = NSBezierPath()
    lens.move(to: CGPoint(x: eye.x - half, y: eye.y))
    lens.curve(to: CGPoint(x: eye.x + half, y: eye.y),
               controlPoint1: CGPoint(x: eye.x - half * 0.48, y: eye.y + lift),
               controlPoint2: CGPoint(x: eye.x + half * 0.48, y: eye.y + lift))
    lens.curve(to: CGPoint(x: eye.x - half, y: eye.y),
               controlPoint1: CGPoint(x: eye.x + half * 0.48, y: eye.y - lift),
               controlPoint2: CGPoint(x: eye.x - half * 0.48, y: eye.y - lift))
    lens.close()
    lens.lineWidth = 80
    lens.lineJoinStyle = .round

    // From 12 o'clock, clockwise, five sixths of the way round.
    let ring = NSBezierPath()
    ring.appendArc(withCenter: eye, radius: 108, startAngle: 90, endAngle: -210, clockwise: true)
    ring.lineWidth = 62
    ring.lineCapStyle = .round

    let pupilRadius: CGFloat = 46
    let pupil = NSBezierPath(ovalIn: CGRect(x: eye.x - pupilRadius, y: eye.y - pupilRadius,
                                            width: pupilRadius * 2, height: pupilRadius * 2))

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
    // One transparency layer so the three parts cast a single shadow.
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setStroke()
    NSColor.white.setFill()
    lens.stroke()
    ring.stroke()
    pupil.fill()
    context.endTransparencyLayer()
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func resized(_ source: NSBitmapImageRep, to pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    source.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let master = drawIcon()
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try resized(master, to: points * scale).write(to: folder.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(
    to: URL(fileURLWithPath: "App/Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) icon sizes to \(folder.path)")
