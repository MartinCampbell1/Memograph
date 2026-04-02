import SwiftUI

struct MemographGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .stroke(lineWidth: 1.6)

            VStack(spacing: 2.5) {
                MemographGlyphRow(width: 10)
                MemographGlyphRow(width: 7)
                MemographGlyphRow(width: 10)
            }
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(.primary)
        .accessibilityLabel("Memograph")
    }
}

private struct MemographGlyphRow: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            Circle()
                .frame(width: 2.5, height: 2.5)
            Capsule(style: .continuous)
                .frame(width: width, height: 2.5)
        }
    }
}
