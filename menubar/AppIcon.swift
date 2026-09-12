// Renders the CornellVPN.app icon set. install.sh runs this and pipes the
// output through `iconutil` to produce CornellVPN.icns, so no binary blob is
// checked into the repo.
//
// Usage: AppIcon <output.iconset directory>

import AppKit

// Cornell carnelian.
let carnelian = NSColor(srgbRed: 0.702, green: 0.106, blue: 0.106, alpha: 1)
let carnelianDeep = NSColor(srgbRed: 0.545, green: 0.071, blue: 0.071, alpha: 1)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons sit inset within their canvas rather than filling it.
    let inset = size * 0.09
    let box = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = box.width * 0.2237   // approximates the macOS squircle
    let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    if let gradient = NSGradient(starting: carnelian, ending: carnelianDeep) {
        gradient.draw(in: shape, angle: -90)
    } else {
        carnelian.setFill()
        shape.fill()
    }

    // "CU", centred, scaled to the icon.
    let fontSize = size * 0.40
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let text = NSAttributedString(string: "CU", attributes: attrs)
    let ts = text.size()
    text.draw(at: NSPoint(x: (size - ts.width) / 2, y: (size - ts.height) / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: AppIcon <output.iconset>\n".utf8))
    exit(1)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// (base point size, scale) pairs required by iconutil.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]
for (base, scale) in variants {
    let pixels = base * scale
    let rep = drawIcon(size: CGFloat(pixels))
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    let suffix = scale == 1 ? "" : "@2x"
    let name = "icon_\(base)x\(base)\(suffix).png"
    try? png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wrote \(variants.count) icon variants to \(outDir)")
