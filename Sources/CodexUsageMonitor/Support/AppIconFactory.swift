import AppKit

@MainActor
enum AppIconFactory {
    static let appIcon: NSImage = makeAppIcon(size: NSSize(width: 512, height: 512))

    static func menuBarIcon(session: QuotaWindow?, weekly: QuotaWindow?) -> NSImage {
        makeMenuBarIcon(
            size: NSSize(width: 21, height: 18),
            sessionFraction: session?.remainingFraction,
            weeklyFraction: weekly?.remainingFraction
        )
    }

    private static func makeAppIcon(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        drawAppIcon(in: rect)

        return image
    }

    private static func makeMenuBarIcon(
        size: NSSize,
        sessionFraction: Double?,
        weeklyFraction: Double?
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(
            x: (size.width - size.height) / 2,
            y: 0,
            width: size.height,
            height: size.height
        ).insetBy(dx: 1.9, dy: 1.55)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let edge = min(rect.width, rect.height)

        drawMenuProgressRing(
            center: center,
            radius: edge * 0.465,
            fraction: sessionFraction,
            lineWidth: 1.42,
            trackAlpha: 0.17,
            progressAlpha: 0.94,
            clockwise: true
        )

        drawMenuProgressRing(
            center: center,
            radius: edge * 0.275,
            fraction: weeklyFraction,
            lineWidth: 1.08,
            trackAlpha: 0.11,
            progressAlpha: 0.62,
            clockwise: false
        )

        image.isTemplate = true
        return image
    }

    private static func drawMenuProgressRing(
        center: NSPoint,
        radius: CGFloat,
        fraction: Double?,
        lineWidth: CGFloat,
        trackAlpha: CGFloat,
        progressAlpha: CGFloat,
        clockwise: Bool
    ) {
        strokeFullCircle(
            center: center,
            radius: radius,
            lineWidth: lineWidth,
            color: .black.withAlphaComponent(trackAlpha)
        )

        guard let fraction else { return }

        let clampedFraction = min(max(fraction, 0), 1)
        guard clampedFraction > 0 else { return }

        if clampedFraction >= 0.995 {
            strokeFullCircle(
                center: center,
                radius: radius,
                lineWidth: lineWidth,
                color: .black.withAlphaComponent(progressAlpha)
            )
            return
        }

        strokeArc(
            center: center,
            radius: radius,
            startAngle: 90,
            endAngle: clockwise ? 90 - CGFloat(clampedFraction * 360) : 90 + CGFloat(clampedFraction * 360),
            lineWidth: lineWidth,
            color: .black.withAlphaComponent(progressAlpha),
            clockwise: clockwise
        )
    }

    private static func strokeFullCircle(
        center: NSPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        color: NSColor
    ) {
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }

    private static func drawAppIcon(in rect: NSRect) {
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

    private static func drawTopSheen(in rect: NSRect, cornerRadius: CGFloat) {
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

    private static func drawTerminalDot(center: NSPoint, radius: CGFloat, angle: CGFloat, diameter: CGFloat) {
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

    private static func strokeArc(
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

    private static var graphite: NSColor {
        NSColor(calibratedRed: 0.075, green: 0.095, blue: 0.085, alpha: 1)
    }

    private static var graphiteHighlight: NSColor {
        NSColor(calibratedRed: 0.18, green: 0.205, blue: 0.18, alpha: 1)
    }

    private static var graphiteFloor: NSColor {
        NSColor(calibratedRed: 0.035, green: 0.05, blue: 0.045, alpha: 1)
    }

    private static var jade: NSColor {
        NSColor(calibratedRed: 0.27, green: 0.88, blue: 0.62, alpha: 1)
    }

    private static var porcelain: NSColor {
        NSColor(calibratedRed: 0.9, green: 0.96, blue: 0.9, alpha: 1)
    }
}
