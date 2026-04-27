import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift <output.iconset>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard outputURL.pathExtension == "iconset" else {
    fputs("output path must end with .iconset\n", stderr)
    exit(2)
}

try? FileManager.default.removeItem(at: outputURL)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let iconFiles: [(String, Int)] = [
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

for (filename, pixels) in iconFiles {
    let url = outputURL.appendingPathComponent(filename)
    try renderIcon(pixels: pixels).write(to: url)
}

private func renderIcon(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)
    else {
        throw IconError.bitmapCreationFailed
    }

    rep.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw IconError.contextCreationFailed
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)
    drawIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw IconError.pngCreationFailed
    }
    return data
}

private func drawIcon(in rect: NSRect) {
    let size = rect.width
    let bodyRect = rect.insetBy(dx: size * 0.07, dy: size * 0.07)
    let cornerRadius = size * 0.205
    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.024)
    shadow.shadowBlurRadius = size * 0.055
    shadow.shadowColor = .black.withAlphaComponent(0.32)
    shadow.set()
    graphite.setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(colors: [graphiteHighlight, graphite, graphiteFloor])?.draw(in: bodyRect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    drawTopSheen(in: bodyRect, cornerRadius: cornerRadius)

    NSColor.white.withAlphaComponent(0.12).setStroke()
    bodyPath.lineWidth = size * 0.006
    bodyPath.stroke()

    let center = NSPoint(x: rect.midX, y: rect.midY + size * 0.012)
    let outerRadius = size * 0.255
    let innerRadius = size * 0.16

    strokeArc(
        center: center,
        radius: outerRadius,
        startAngle: 0,
        endAngle: 360,
        lineWidth: size * 0.042,
        color: porcelain.withAlphaComponent(0.16)
    )

    strokeArc(
        center: center,
        radius: outerRadius,
        startAngle: 214,
        endAngle: 28,
        lineWidth: size * 0.047,
        color: jade
    )

    strokeArc(
        center: center,
        radius: innerRadius,
        startAngle: 34,
        endAngle: 300,
        lineWidth: size * 0.028,
        color: porcelain.withAlphaComponent(0.78),
        clockwise: true
    )

    drawTerminalDot(center: center, radius: outerRadius, angle: 28, diameter: size * 0.031)

    NSColor.white.withAlphaComponent(0.08).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: center.x - size * 0.038,
        y: center.y - size * 0.038,
        width: size * 0.076,
        height: size * 0.076
    )).fill()
}

private func drawTopSheen(in rect: NSRect, cornerRadius: CGFloat) {
    let sheenRect = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    let sheenPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSGraphicsContext.saveGraphicsState()
    sheenPath.addClip()
    NSGradient(colors: [.white.withAlphaComponent(0.16), .white.withAlphaComponent(0)])?.draw(
        in: sheenRect,
        angle: -90
    )
    NSGraphicsContext.restoreGraphicsState()
}

private func drawTerminalDot(center: NSPoint, radius: CGFloat, angle: CGFloat, diameter: CGFloat) {
    let radians = angle * .pi / 180
    let point = NSPoint(
        x: center.x + cos(radians) * radius,
        y: center.y + sin(radians) * radius
    )

    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: point.x - diameter * 0.72,
        y: point.y - diameter * 0.72,
        width: diameter * 1.44,
        height: diameter * 1.44
    )).fill()

    jade.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: point.x - diameter / 2,
        y: point.y - diameter / 2,
        width: diameter,
        height: diameter
    )).fill()
}

private func strokeArc(
    center: NSPoint,
    radius: CGFloat,
    startAngle: CGFloat,
    endAngle: CGFloat,
    lineWidth: CGFloat,
    color: NSColor,
    clockwise: Bool = false
) {
    let path = NSBezierPath()
    path.appendArc(
        withCenter: center,
        radius: radius,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: clockwise
    )
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

private var graphite: NSColor {
    NSColor(calibratedRed: 0.075, green: 0.095, blue: 0.085, alpha: 1)
}

private var graphiteHighlight: NSColor {
    NSColor(calibratedRed: 0.18, green: 0.205, blue: 0.18, alpha: 1)
}

private var graphiteFloor: NSColor {
    NSColor(calibratedRed: 0.035, green: 0.05, blue: 0.045, alpha: 1)
}

private var jade: NSColor {
    NSColor(calibratedRed: 0.27, green: 0.88, blue: 0.62, alpha: 1)
}

private var porcelain: NSColor {
    NSColor(calibratedRed: 0.9, green: 0.96, blue: 0.9, alpha: 1)
}

private enum IconError: Error {
    case bitmapCreationFailed
    case contextCreationFailed
    case pngCreationFailed
}
