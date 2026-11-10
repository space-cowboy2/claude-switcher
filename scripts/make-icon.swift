#!/usr/bin/env swift
// Draws the Second Wind app icon: two gusts of wind blowing opposite ways on a sunset plate. The
// faint one is the account that ran out; the bright one is the second wind.
//
// Usage: swift scripts/make-icon.swift <output folder>
// Writes <output folder>/AppIcon.iconset (for `iconutil -c icns`) and <output folder>/icon.png.
// scripts/make-icon.sh runs this and puts the results where the repo keeps them.
import AppKit

let canvas: CGFloat = 1024

/// Points of one gust: a straight run that curls up and back at its end. Coordinates are y-down.
func gust() -> [CGPoint] {
    var pts = [CGPoint(x: 240, y: 430), CGPoint(x: 640, y: 430)]
    let center = CGPoint(x: 640, y: 320), radius: CGFloat = 110
    let from = 90.0, to = -165.0, steps = 60
    for i in 0...steps {
        let a = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
        pts.append(CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a))))
    }
    return pts
}

func stroke(_ pts: [CGPoint], alpha: CGFloat, in ctx: CGContext) {
    // A transparency layer keeps the faint gust even where its curl crosses itself.
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.beginPath()
    ctx.addLines(between: pts)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(56)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(size) / canvas
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // The plate: the standard macOS rounded square, with a soft shadow under it.
    let plate = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 30 * scale,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(plate)
    ctx.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.25, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Sunset: warm yellow-orange at the top to crimson at the bottom.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let colors = [CGColor(red: 1.00, green: 0.72, blue: 0.28, alpha: 1),
                  CGColor(red: 1.00, green: 0.42, blue: 0.21, alpha: 1),
                  CGColor(red: 0.80, green: 0.13, blue: 0.27, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // Two gusts. The second is the first turned half a circle about the centre.
    let first = gust()
    let second = first.map { CGPoint(x: canvas - $0.x, y: canvas - $0.y) }
    stroke(first, alpha: 0.55, in: ctx)
    stroke(second, alpha: 1, in: ctx)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <output folder>\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, factor) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)" + (factor == 2 ? "@2x" : "") + ".png"
    try render(points * factor).write(to: iconset.appendingPathComponent(name))
}
try render(512).write(to: out.appendingPathComponent("icon.png"))
print("wrote \(iconset.path) and icon.png")
