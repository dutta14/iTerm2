#!/usr/bin/env swift
// Renders the Dev Terminal "</>" app icon into an .iconset directory.
// Usage: make_devterminal_icon.swift <output.iconset>
// Geometry follows the design spec, section 9, on a 1024 grid with a top-left origin.
// The glyph is thinner and wider than the spec so the brackets and slash never touch.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func render(pixels: Int, to url: URL) {
    let small = pixels <= 64
    let scale = CGFloat(pixels) / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create bitmap context")
    }
    // Work in the 1024 top-left coordinate system by flipping the CTM. Shadow offsets ignore the CTM,
    // so they are given in device space, where positive height points up.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)

    let plate = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 185, cornerHeight: 185, transform: nil)
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
    }

    // Plate with its drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -(small ? 8 : 12) * scale), blur: (small ? 16 : 28) * scale,
                  color: color(15, 10, 40, small ? 0.30 : 0.35))
    ctx.addPath(plate)
    ctx.setFillColor(color(91, 33, 182))
    ctx.fillPath()
    ctx.restoreGState()

    // Plate gradient.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(139, 92, 246), color(124, 58, 237), color(91, 33, 182)] as CFArray,
                              locations: [0, 0.35, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // Inner highlight rim.
    if !small {
        ctx.saveGState()
        let rim = CGPath(roundedRect: CGRect(x: 101, y: 101, width: 822, height: 822),
                         cornerWidth: 184, cornerHeight: 184, transform: nil)
        ctx.addPath(rim)
        ctx.setLineWidth(2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rimGradient = CGGradient(colorsSpace: space,
                                     colors: [color(255, 255, 255, 0.28), color(255, 255, 255, 0)] as CFArray,
                                     locations: [0, 1])!
        ctx.drawLinearGradient(rimGradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 400), options: [])
        ctx.restoreGState()
    }

    // Glyph, as one path so the shadow is drawn once.
    let glyph = CGMutablePath()
    if small {
        glyph.move(to: CGPoint(x: 356, y: 400)); glyph.addLine(to: CGPoint(x: 252, y: 512)); glyph.addLine(to: CGPoint(x: 356, y: 624))
        glyph.move(to: CGPoint(x: 560, y: 360)); glyph.addLine(to: CGPoint(x: 464, y: 664))
        glyph.move(to: CGPoint(x: 668, y: 400)); glyph.addLine(to: CGPoint(x: 772, y: 512)); glyph.addLine(to: CGPoint(x: 668, y: 624))
    } else {
        glyph.move(to: CGPoint(x: 368, y: 380)); glyph.addLine(to: CGPoint(x: 248, y: 512)); glyph.addLine(to: CGPoint(x: 368, y: 644))
        glyph.move(to: CGPoint(x: 570, y: 336)); glyph.addLine(to: CGPoint(x: 454, y: 688))
        glyph.move(to: CGPoint(x: 656, y: 380)); glyph.addLine(to: CGPoint(x: 776, y: 512)); glyph.addLine(to: CGPoint(x: 656, y: 644))
    }
    ctx.saveGState()
    if !small {
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 12 * scale, color: color(40, 10, 100, 0.30))
    }
    ctx.addPath(glyph)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(small ? 88 : 60)
    ctx.setStrokeColor(color(255, 255, 255))
    ctx.strokePath()
    ctx.restoreGState()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create PNG destination")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        fatalError("Could not write \(url.path)")
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_devterminal_icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let slices: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in slices {
    render(pixels: pixels, to: outDir.appendingPathComponent("\(name).png"))
}
