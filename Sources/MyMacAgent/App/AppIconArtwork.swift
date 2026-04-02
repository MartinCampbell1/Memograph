import AppKit

enum AppIconArtwork {
    static func makeImage(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        canvas.fill()

        let outerRect = canvas.insetBy(dx: size * 0.08, dy: size * 0.08)
        let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: size * 0.18, yRadius: size * 0.18)
        NSColor(calibratedRed: 0.95, green: 0.92, blue: 0.86, alpha: 1).setFill()
        outerPath.fill()

        let innerRect = outerRect.insetBy(dx: size * 0.11, dy: size * 0.11)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: size * 0.12, yRadius: size * 0.12)
        NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.14, alpha: 1).setFill()
        innerPath.fill()

        let insetStroke = innerRect.insetBy(dx: size * 0.018, dy: size * 0.018)
        let strokePath = NSBezierPath(roundedRect: insetStroke, xRadius: size * 0.1, yRadius: size * 0.1)
        strokePath.lineWidth = size * 0.018
        NSColor(calibratedRed: 0.24, green: 0.42, blue: 0.39, alpha: 1).setStroke()
        strokePath.stroke()

        let rowHeight = size * 0.06
        let rowSpacing = size * 0.052
        let startY = innerRect.midY + rowSpacing
        let dotX = innerRect.minX + size * 0.12
        let lineX = dotX + size * 0.07

        drawRow(y: startY, dotColor: NSColor(calibratedRed: 0.35, green: 0.73, blue: 0.62, alpha: 1), lineColor: NSColor(calibratedRed: 0.93, green: 0.66, blue: 0.33, alpha: 1), lineWidth: size * 0.2, height: rowHeight, dotX: dotX, lineX: lineX)
        drawRow(y: innerRect.midY, dotColor: NSColor(calibratedRed: 0.93, green: 0.66, blue: 0.33, alpha: 1), lineColor: NSColor(calibratedRed: 0.80, green: 0.88, blue: 0.84, alpha: 1), lineWidth: size * 0.14, height: rowHeight, dotX: dotX, lineX: lineX)
        drawRow(y: innerRect.midY - rowSpacing, dotColor: NSColor(calibratedRed: 0.35, green: 0.73, blue: 0.62, alpha: 1), lineColor: NSColor(calibratedRed: 0.35, green: 0.73, blue: 0.62, alpha: 1), lineWidth: size * 0.18, height: rowHeight, dotX: dotX, lineX: lineX)

        image.unlockFocus()
        return image
    }

    private static func drawRow(
        y: CGFloat,
        dotColor: NSColor,
        lineColor: NSColor,
        lineWidth: CGFloat,
        height: CGFloat,
        dotX: CGFloat,
        lineX: CGFloat
    ) {
        let dotRect = NSRect(x: dotX, y: y - height / 2, width: height, height: height)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        dotColor.setFill()
        dotPath.fill()

        let lineRect = NSRect(x: lineX, y: y - height / 2, width: lineWidth, height: height)
        let linePath = NSBezierPath(roundedRect: lineRect, xRadius: height / 2, yRadius: height / 2)
        lineColor.setFill()
        linePath.fill()
    }
}
