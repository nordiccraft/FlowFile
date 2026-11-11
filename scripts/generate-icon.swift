import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else { exit(0) }
let outputICNSPath = CommandLine.arguments[1]
let tempIconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FlowFile.iconset")
try? FileManager.default.removeItem(at: tempIconset)
try FileManager.default.createDirectory(at: tempIconset, withIntermediateDirectories: true)

func drawIcon(pixelSize: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixelSize)
    let pad = s * 0.08
    let rect = NSRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)

    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.38, blue: 0.92, alpha: 1.0),
        NSColor(calibratedRed: 0.14, green: 0.72, blue: 0.96, alpha: 1.0)
    ])
    grad?.draw(in: bgPath, angle: -55)

    // Dual-pane glass cards motif
    let inset = s * 0.21
    let gap = s * 0.035
    let cardW = (s - inset * 2 - gap) / 2
    let cardH = s * 0.52
    let cardY = (s - cardH) / 2

    let leftCard = NSBezierPath(
        roundedRect: NSRect(x: inset, y: cardY, width: cardW, height: cardH),
        xRadius: s * 0.06,
        yRadius: s * 0.06
    )
    NSColor.white.withAlphaComponent(0.92).setFill()
    leftCard.fill()

    let rightCard = NSBezierPath(
        roundedRect: NSRect(x: inset + cardW + gap, y: cardY, width: cardW, height: cardH),
        xRadius: s * 0.06,
        yRadius: s * 0.06
    )
    NSColor.white.withAlphaComponent(0.62).setFill()
    rightCard.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in sizes {
    if let data = drawIcon(pixelSize: px) {
        try data.write(to: tempIconset.appendingPathComponent(filename))
    }
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tempIconset.path, "-o", outputICNSPath]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: tempIconset)
