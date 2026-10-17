// Turns square artwork (e.g. an image-model render of a full-bleed icon tile) into a macOS
// AppIcon.icns that follows Apple's icon grid: 824 pt rounded-square body centred on a 1024
// canvas, with a soft drop shadow.
//
// Usage: swift scripts/make-icon.swift <artwork.png> <output-dir> [crop-inset-fraction]
//   crop-inset-fraction trims the artwork's own edges/corners first (default 0.06).
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <artwork.png> <output-dir> [inset]\n".utf8))
    exit(1)
}
let outputDir = URL(fileURLWithPath: args[2])
let inset = args.count > 3 ? Double(args[3]) ?? 0.06 : 0.06

func render(size: Int) -> Data {
    let canvas = CGFloat(size)
    let scale = canvas / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 185 * scale
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Soft shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Artwork, cropped to drop its own rounded edges, clipped to the tile.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let s = source.size
    let crop = NSRect(x: s.width * inset, y: s.height * inset,
                      width: s.width * (1 - 2 * inset), height: s.height * (1 - 2 * inset))
    source.draw(in: body, from: crop, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    // Hairline edge highlight, as on system icons.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    shape.lineWidth = max(1, 2 * scale)
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try render(size: 1024).write(to: outputDir.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(outputDir.appendingPathComponent("AppIcon.icns").path)")
