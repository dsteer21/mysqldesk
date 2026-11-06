// Draws the app icon (a database cylinder beside a results grid) and writes Resources/AppIcon.icns.
// Uses GitDesk's tile and colours so the two apps look like a pair.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Rounded-square background with a subtle gradient (same as GitDesk).
    let inset = 100 * s
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
                            xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))!.draw(in: tile, angle: -90)

    let teal = NSColor(red: 0.13, green: 0.71, blue: 0.86, alpha: 1)
    let purple = NSColor(red: 0.58, green: 0.40, blue: 0.94, alpha: 1)
    let dark = NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1)
    let line = 40 * s

    // Cylinder: three stacked discs.
    let left = 230 * s, width = 380 * s, discHeight = 120 * s
    let bottom = 250 * s, top = 740 * s
    func ellipse(_ y: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: left, y: y - discHeight / 2, width: width, height: discHeight))
    }
    // Fill the body first so the grid and bands sit on a solid shape.
    dark.setFill()
    NSBezierPath(rect: NSRect(x: left, y: bottom, width: width, height: top - bottom)).fill()
    ellipse(bottom).fill()

    teal.setStroke()
    for y in [bottom, bottom + (top - bottom) / 3, bottom + 2 * (top - bottom) / 3] {
        // Only the front (lower) half of each band shows.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: left - line, y: y - discHeight, width: width + line * 2, height: discHeight)).addClip()
        let band = ellipse(y)
        band.lineWidth = line
        band.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    let sides = NSBezierPath()
    sides.move(to: NSPoint(x: left, y: top))
    sides.line(to: NSPoint(x: left, y: bottom))
    sides.move(to: NSPoint(x: left + width, y: top))
    sides.line(to: NSPoint(x: left + width, y: bottom))
    sides.lineWidth = line
    sides.stroke()
    let cap = ellipse(top)
    dark.setFill()
    cap.fill()
    cap.lineWidth = line
    cap.stroke()

    // Results grid, overlapping the cylinder's lower right.
    let grid = NSRect(x: 520 * s, y: 210 * s, width: 300 * s, height: 250 * s)
    let frame = NSBezierPath(roundedRect: grid, xRadius: 28 * s, yRadius: 28 * s)
    dark.setFill()
    frame.fill()
    purple.setStroke()
    frame.lineWidth = 34 * s
    frame.stroke()
    let rules = NSBezierPath()
    rules.move(to: NSPoint(x: grid.minX, y: grid.maxY - 80 * s))
    rules.line(to: NSPoint(x: grid.maxX, y: grid.maxY - 80 * s))
    rules.move(to: NSPoint(x: grid.minX, y: grid.minY + 85 * s))
    rules.line(to: NSPoint(x: grid.maxX, y: grid.minY + 85 * s))
    rules.move(to: NSPoint(x: grid.midX, y: grid.minY))
    rules.line(to: NSPoint(x: grid.midX, y: grid.maxY))
    rules.lineWidth = 22 * s
    rules.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
// Keep a PNG preview next to the icns for the README / web page.
try? fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: URL(fileURLWithPath: "Resources/AppIcon.png"))
print(task.terminationStatus == 0 ? "✓ Wrote Resources/AppIcon.icns" : "iconutil failed")
