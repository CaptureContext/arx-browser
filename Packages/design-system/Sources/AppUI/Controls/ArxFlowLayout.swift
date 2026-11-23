import SwiftUI

/// Lays its views out in rows, left to right, starting a new row when the next one wouldn't fit,
/// as chips wrap under a narrow header. Each view keeps its ideal size, narrowed to the row's
/// width at most.
///
/// ```swift
/// ArxFlowLayout(spacing: 4) {
///     ForEach(filters) { SidebarLibraryFilterChip($0.name) { remove($0) } }
/// }
/// ```
public struct ArxFlowLayout: Layout {
	private let spacing: CGFloat
	private let lineSpacing: CGFloat

	public init(
		spacing: CGFloat = 4,
		lineSpacing: CGFloat? = nil
	) {
		self.spacing = spacing
		self.lineSpacing = lineSpacing ?? spacing
	}

	public func sizeThatFits(
		proposal: ProposedViewSize,
		subviews: Subviews,
		cache: inout Void
	) -> CGSize {
		let rows: [[Placement]] = arrange(subviews, width: proposal.width ?? .infinity)
		let width: CGFloat = rows.map { $0.last.map { $0.frame.maxX } ?? 0 }.max() ?? 0
		let height: CGFloat = rows.last?.map(\.frame.maxY).max() ?? 0
		return .init(width: width, height: height)
	}

	public func placeSubviews(
		in bounds: CGRect,
		proposal: ProposedViewSize,
		subviews: Subviews,
		cache: inout Void
	) {
		for row in arrange(subviews, width: bounds.width) {
			for placement in row {
				subviews[placement.index].place(
					at: .init(x: bounds.minX + placement.frame.minX, y: bounds.minY + placement.frame.minY),
					proposal: .init(placement.frame.size)
				)
			}
		}
	}

	private struct Placement {
		internal let index: Int
		internal let frame: CGRect
	}

	private func arrange(
		_ subviews: Subviews,
		width: CGFloat
	) -> [[Placement]] {
		var rows: [[Placement]] = []
		var row: [Placement] = []
		var x: CGFloat = 0
		var y: CGFloat = 0
		var rowHeight: CGFloat = 0
		for index in subviews.indices {
			var size: CGSize = subviews[index].sizeThatFits(.unspecified)
			size.width = min(size.width, width)
			if !row.isEmpty, x + size.width > width {
				rows.append(row)
				row = []
				x = 0
				y += rowHeight + lineSpacing
				rowHeight = 0
			}
			row.append(.init(index: index, frame: .init(origin: .init(x: x, y: y), size: size)))
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
		}
		if !row.isEmpty { rows.append(row) }
		return rows
	}
}
