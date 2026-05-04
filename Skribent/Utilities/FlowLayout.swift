import SwiftUI

/// Wrapping HStack: lays out children left-to-right and breaks to a new line when
/// they don't fit the available width. Items in the same line are vertically centered.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = computeLines(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let totalHeight = lines.reduce(0) { $0 + $1.height } + CGFloat(max(0, lines.count - 1)) * lineSpacing
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: min(proposal.width ?? widest, widest), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = computeLines(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for (i, item) in line.items.enumerated() {
                if i > 0 { x += spacing }
                // Vertically center the item within the line's height.
                let yOffset = (line.height - item.size.height) / 2
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + yOffset),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width
            }
            y += line.height + lineSpacing
        }
    }

    // MARK: - Private

    private struct Item { let index: Int; let size: CGSize }
    private struct Line { var items: [Item]; var width: CGFloat; var height: CGFloat }

    private func computeLines(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line(items: [], width: 0, height: 0)]
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let firstInLine = lines[lines.count - 1].items.isEmpty
            let advance = (firstInLine ? 0 : spacing) + size.width
            if lines[lines.count - 1].width + advance > maxWidth, !firstInLine {
                lines.append(Line(items: [], width: 0, height: 0))
            }
            var current = lines[lines.count - 1]
            if !current.items.isEmpty { current.width += spacing }
            current.items.append(Item(index: i, size: size))
            current.width += size.width
            current.height = max(current.height, size.height)
            lines[lines.count - 1] = current
        }
        return lines
    }
}
