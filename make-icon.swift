#!/usr/bin/env swift
// Draws Resources/AppIcon.icns — a rounded blue tile with two chevrons
// squeezing a bar, i.e. "make this smaller". Run via `./make-icon.swift`;
// build.sh picks the .icns up automatically if it is present.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconsetNames: [Int: [String]] = [
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
]

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS app tiles sit inset inside their canvas with a squircle-ish radius.
    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGradient(
        colors: [
            NSColor(srgbRed: 0.35, green: 0.60, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.32, blue: 0.85, alpha: 1),
        ]
    )!.draw(in: tile, angle: -90)

    // Two chevrons pressing inward on a centre bar.
    let centre = NSPoint(x: size / 2, y: size / 2)
    let unit = rect.width
    let lineWidth = unit * 0.085
    NSColor.white.setStroke()

    let chevronHalfWidth = unit * 0.15
    let chevronHeight = unit * 0.13
    let gap = unit * 0.115

    for direction in [1.0, -1.0] {
        let path = NSBezierPath()
        let tipY = centre.y + direction * gap
        let baseY = tipY + direction * chevronHeight
        path.move(to: NSPoint(x: centre.x - chevronHalfWidth, y: baseY))
        path.line(to: NSPoint(x: centre.x, y: tipY))
        path.line(to: NSPoint(x: centre.x + chevronHalfWidth, y: baseY))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    let bar = NSBezierPath()
    bar.move(to: NSPoint(x: centre.x - unit * 0.21, y: centre.y))
    bar.line(to: NSPoint(x: centre.x + unit * 0.21, y: centre.y))
    bar.lineWidth = lineWidth
    bar.lineCapStyle = .round
    bar.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fileManager = FileManager.default
let root = URL(filePath: fileManager.currentDirectoryPath)
let iconset = root.appending(path: "AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    let data = drawIcon(size: CGFloat(size)).representation(using: .png, properties: [:])!
    for name in iconsetNames[size] ?? [] {
        try data.write(to: iconset.appending(path: name))
    }
}

try? fileManager.createDirectory(
    at: root.appending(path: "Resources"), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
try? fileManager.removeItem(at: iconset)

print(iconutil.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
