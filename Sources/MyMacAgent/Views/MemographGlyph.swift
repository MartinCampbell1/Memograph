import AppKit
import SwiftUI

enum MemographMenuBarArtwork {
    static func makeImage() -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let dotSize: CGFloat = 3.2
        let rowHeight: CGFloat = 3.4
        let rowSpacing: CGFloat = 1.9
        let dotX: CGFloat = 0.8
        let barX: CGFloat = dotX + dotSize + 2.2
        let topY: CGFloat = 9.7

        drawRow(y: topY, dotSize: dotSize, rowHeight: rowHeight, dotX: dotX, barX: barX, barWidth: 10.2)
        drawRow(y: topY - (rowHeight + rowSpacing), dotSize: dotSize, rowHeight: rowHeight, dotX: dotX, barX: barX, barWidth: 6.6)
        drawRow(y: topY - 2 * (rowHeight + rowSpacing), dotSize: dotSize, rowHeight: rowHeight, dotX: dotX, barX: barX, barWidth: 10.2)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawRow(
        y: CGFloat,
        dotSize: CGFloat,
        rowHeight: CGFloat,
        dotX: CGFloat,
        barX: CGFloat,
        barWidth: CGFloat
    ) {
        let dotRect = NSRect(x: dotX, y: y, width: dotSize, height: dotSize)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        NSColor.labelColor.setFill()
        dotPath.fill()

        let barRect = NSRect(x: barX, y: y - 0.1, width: barWidth, height: rowHeight)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: rowHeight / 2, yRadius: rowHeight / 2)
        NSColor.labelColor.setFill()
        barPath.fill()
    }
}

struct MemographGlyph: View {
    private static let image = MemographMenuBarArtwork.makeImage()

    var body: some View {
        Image(nsImage: Self.image)
            .renderingMode(.template)
            .interpolation(.high)
            .antialiased(true)
            .accessibilityLabel("Memograph")
    }
}
