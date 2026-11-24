import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count > 1 else { exit(0) }
let outputICNSPath = CommandLine.arguments[1]
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
let projectDir = scriptDir.deletingLastPathComponent()
let markURL = projectDir.appendingPathComponent("assets/flowfile-icon-mark.png")
let previewOutPath: String? = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

let markCGImage: CGImage? = {
    guard let src = CGImageSourceCreateWithURL(markURL as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}()

func renderIcon(pixelSize: Int) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let s = CGFloat(pixelSize)
    // Standard macOS Big Sur / Sonoma / Tahoe icon canvas padding (~9.7% inset inside 1024px grid)
    let pad = s * 0.095
    let cardRect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let cornerRadius = cardRect.width * 0.225
    let squirclePath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Subtle outer drop shadow for macOS Dock depth
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.015),
        blur: s * 0.032,
        color: CGColor(red: 0.01, green: 0.03, blue: 0.10, alpha: 0.42)
    )
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.04, green: 0.10, blue: 0.22, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to deep marine-blue squircle
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // Deep marine-blue gradient matching the FlowFile wordmark (#07142B -> #0D2247 -> #122E5E)
    let bgColors = [
        CGColor(red: 0.027, green: 0.078, blue: 0.169, alpha: 1.0),
        CGColor(red: 0.055, green: 0.137, blue: 0.282, alpha: 1.0),
        CGColor(red: 0.078, green: 0.192, blue: 0.376, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: cardRect.minX, y: cardRect.minY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.maxY),
            options: []
        )
    }

    // Soft ambient radial glow behind the F-document ribbon so purple/blue/cyan pops cleanly
    let glowColors = [
        CGColor(red: 0.20, green: 0.52, blue: 0.96, alpha: 0.24),
        CGColor(red: 0.18, green: 0.40, blue: 0.88, alpha: 0.0)
    ] as CFArray
    if let radial = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        let center = CGPoint(x: cardRect.midX, y: cardRect.midY)
        ctx.drawRadialGradient(
            radial,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: cardRect.width * 0.52,
            options: []
        )
    }

    // Draw the official FlowFile F-document mark centered with balanced breathing room
    if let mark = markCGImage {
        let markW = CGFloat(mark.width)
        let markH = CGFloat(mark.height)
        let maxDrawSide = cardRect.width * 0.72
        let scale = min(maxDrawSide / markW, maxDrawSide / markH)
        let drawW = markW * scale
        let drawH = markH * scale
        // Slight optical centering (+1.2% left/right balanced for folded corner + ribbon curve)
        let drawRect = CGRect(
            x: cardRect.midX - drawW * 0.50,
            y: cardRect.midY - drawH * 0.50,
            width: drawW,
            height: drawH
        )
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.012),
            blur: s * 0.030,
            color: CGColor(red: 0.01, green: 0.03, blue: 0.10, alpha: 0.55)
        )
        ctx.draw(mark, in: drawRect)
        ctx.restoreGState()
    }

    // Crisp glass inner rim highlight around squircle
    let borderRect = cardRect.insetBy(dx: max(0.5, s * 0.004), dy: max(0.5, s * 0.004))
    let borderPath = CGPath(roundedRect: borderRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(borderPath)
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.80, blue: 1.0, alpha: 0.24))
    ctx.setLineWidth(max(1.0, s * 0.008))
    ctx.strokePath()

    ctx.restoreGState()
    return ctx.makeImage()
}

func pngData(for image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "GenerateIcon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "GenerateIcon", code: 2)
    }
    return data as Data
}

/// Writes a 100% Apple-compliant `.icns` container directly in pure Swift (no `iconutil` dependency).
func buildICNS(entries: [(ostype: String, pixelSize: Int)]) throws -> Data {
    var body = Data()
    for entry in entries {
        guard let img = renderIcon(pixelSize: entry.pixelSize) else { continue }
        let png = try pngData(for: img)
        let tag = Data(entry.ostype.utf8)
        guard tag.count == 4 else { continue }
        var chunkLen = UInt32(8 + png.count).bigEndian
        body.append(tag)
        body.append(Data(bytes: &chunkLen, count: 4))
        body.append(png)
    }

    var file = Data("icns".utf8)
    var totalLen = UInt32(8 + body.count).bigEndian
    file.append(Data(bytes: &totalLen, count: 4))
    file.append(body)
    return file
}

let icnsEntries: [(String, Int)] = [
    ("icp4", 16),   // 16x16
    ("ic11", 32),   // 16x16@2x
    ("icp5", 32),   // 32x32
    ("ic12", 64),   // 32x32@2x
    ("ic07", 128),  // 128x128
    ("ic13", 256),  // 128x128@2x
    ("ic08", 256),  // 256x256
    ("ic14", 512),  // 256x256@2x
    ("ic09", 512),  // 512x512
    ("ic10", 1024)  // 512x512@2x
]

let icnsData = try buildICNS(entries: icnsEntries)
try icnsData.write(to: URL(fileURLWithPath: outputICNSPath), options: .atomic)

if let previewOutPath, let previewImg = renderIcon(pixelSize: 512) {
    let previewPNG = try pngData(for: previewImg)
    try previewPNG.write(to: URL(fileURLWithPath: previewOutPath), options: .atomic)
}
