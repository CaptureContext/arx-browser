import SwiftUI

/// The insertion line and committed move are derived from the same pointer position.
internal struct SidebarDropPlacement: Equatable {
	internal let target: SidebarDropTarget
	internal let lineY: CGFloat?
	internal let depth: Int

	internal init(
		target: SidebarDropTarget,
		lineY: CGFloat?,
		depth: Int
	) {
		self.target = target
		self.lineY = lineY
		self.depth = depth
	}
}

extension SidebarDropPlacement {
	/// Whether dropping here would make a split larger than the window fits, judged by the
	/// destination group's own orientation (side by side for a new one).
	internal func exceedsSplit(
		limits: SplitPaneLimits,
		in tabs: [SidebarItem]
	) -> Bool {
		guard case let .split(id) = target else { return false }
		let row = tabs.first(where: { $0.id == id })

		// Favorites in the group count too, though the row doesn't show them (DEV-1006).
		let members = row?.split?.paneIDs.count ?? row?.splitPanes?.count ?? 1
		let isVertical = row?.split?.isVertical ?? row?.splitPanes?.isVertical ?? false
		return members >= limits.panes(vertical: isVertical)
	}
}

internal struct SidebarDropLayout {
	internal let savedRows: [SidebarTreeRow]
	internal let regularTabs: [SidebarItem]
	internal let frames: [SidebarItem.ID: CGRect]
	internal let newTabFrame: CGRect

	internal init(
		savedRows: [SidebarTreeRow],
		regularTabs: [SidebarItem],
		frames: [SidebarItem.ID: CGRect],
		newTabFrame: CGRect
	) {
		self.savedRows = savedRows
		self.regularTabs = regularTabs
		self.frames = frames
		self.newTabFrame = newTabFrame
	}

	/// The rows are lazy, so `frames` holds only the rows on screen, one unbroken run of each
	/// section, and `newTabFrame` is empty while New Tab is off screen. The pointer is on screen,
	/// so it's over the rows that are measured.
	internal func placement(at point: CGPoint) -> SidebarDropPlacement? {
		guard !newTabFrame.isEmpty else {
			// New Tab is off screen, so the pointer is over one section: the one with rows on screen.
			let showsRegularTabs: Bool = regularTabs.contains { frames[$0.id] != nil }
			let showsSavedRows: Bool = savedRows.contains { frames[$0.id] != nil }
			if showsRegularTabs, !showsSavedRows { return regularPlacement(at: point) }
			if showsSavedRows { return savedPlacement(at: point) }
			return nil
		}

		// The action button never doubles as a drop target, including its horizontal padding.
		guard !(newTabFrame.minY ... newTabFrame.maxY).contains(point.y) else { return nil }

		if point.y > newTabFrame.maxY { return regularPlacement(at: point) }
		return savedPlacement(at: point)
	}

	private func regularPlacement(at point: CGPoint) -> SidebarDropPlacement {
		var lastMeasured: (index: Int, frame: CGRect)?
		for (index, tab) in regularTabs.enumerated() {
			guard let frame = frames[tab.id] else { continue }
			lastMeasured = (index, frame)

			// The middle of an open tab's row forms a split, and of a tab group's row joins the
			// group (DEV-911); their edges still reorder.
			if frame.insetBy(dx: 0, dy: frame.height * 0.25).contains(CGPoint(x: frame.midX, y: point.y)) {
				return .init(
					target: tab.isFolder ? .inside(tab.id) : .split(tab.id),
					lineY: nil,
					depth: 0
				)
			}
			if point.y < frame.midY {
				return .init(
					target: .before(tab.id),
					lineY: frame.minY - 1.5,
					depth: 0
				)
			}
		}

		// Below the last tab on screen, while more follow off screen: before the next one.
		if let lastMeasured, lastMeasured.index + 1 < regularTabs.count {
			return .init(
				target: .before(regularTabs[lastMeasured.index + 1].id),
				lineY: lastMeasured.frame.maxY + 1.5,
				depth: 0
			)
		}
		return .init(
			target: .unpinnedRoot,
			lineY: lastMeasured.map { $0.frame.maxY + 1.5 } ?? (newTabFrame.maxY + 4),
			depth: 0
		)
	}

	private func savedPlacement(at point: CGPoint) -> SidebarDropPlacement {
		// The tree comes from every row, so an ancestor off screen still takes a drop beside it;
		// where the pointer is comes from the measured rows.
		let rows: [SidebarTreeRow] = savedRows
		let measured: [Int] = rows.indices.filter { frames[rows[$0].id] != nil }
		for row in rows {
			guard let frame = frames[row.id] else { continue }
			if row.item.isFolder {
				// Only the middle of a folder accepts nesting. Its edges remain insertion targets.
				let center = frame.insetBy(dx: 0, dy: 11)
				if center.contains(point), point.x >= 16 + CGFloat(row.depth) * 17 {
					return .init(
						target: .inside(row.id),
						lineY: nil,
						depth: row.depth + 1
					)
				}
			} else if frame.insetBy(dx: 0, dy: frame.height * 0.25).contains(CGPoint(x: frame.midX, y: point.y)) {
				// The middle of a pinned tab's row forms a split, as an open tab's does (DEV-1006).
				return .init(
					target: .split(row.id),
					lineY: nil,
					depth: row.depth
				)
			}
		}

		guard let lastMeasured = measured.last
		else { return .init(target: .savedRoot, lineY: 2, depth: 0) }
		let boundary: Int = measured.first { index in
			frames[rows[index].id].map { point.y < $0.midY } ?? false
		} ?? lastMeasured + 1
		guard boundary > 0 else {
			guard
				let first = rows.first,
				let frame = frames[first.id]
			else { return .init(target: .savedRoot, lineY: 2, depth: 0) }
			return .init(
				target: .before(first.id),
				lineY: frame.minY - 1.5,
				depth: first.depth
			)
		}

		let previous = rows[boundary - 1]
		let next = boundary < rows.count ? rows[boundary] : nil
		let minimumDepth = next?.depth ?? 0
		let maximumDepth = previous.depth + (previous.item.isFolder && previous.item.isExpanded ? 1 : 0)
		let intendedDepth = max(0, Int((point.x - 16) / 17))
		let depth = max(minimumDepth, min(intendedDepth, maximumDepth))

		// One of the two is on screen: the boundary is next to a measured row.
		let lineY: CGFloat = next.flatMap { frames[$0.id]?.minY }.map { $0 - 1.5 }
		?? frames[previous.id].map { $0.maxY + 1.5 }
		?? 2

		if let next, next.depth == depth {
			return .init(
				// A tab shown from a folder deeper in goes to the folder it shows under (DEV-1110).
				target: next.shownParentID.map(SidebarDropTarget.inside) ?? .before(next.id),
				lineY: lineY,
				depth: depth
			)
		}
		if depth > previous.depth {
			return .init(
				target: .inside(previous.id),
				lineY: lineY,
				depth: depth
			)
		}

		// At a subtree's lower edge, moving left selects an ancestor's sibling level.
		let sibling = rows[..<boundary].last { $0.depth == depth } ?? previous
		return .init(
			target: sibling.shownParentID.map(SidebarDropTarget.inside) ?? .after(sibling.id),
			lineY: lineY,
			depth: depth
		)
	}
}

internal struct SidebarRowFrames: PreferenceKey {
	internal static var defaultValue: [SidebarItem.ID: CGRect] { [:] }

	internal static func reduce(
		value: inout [SidebarItem.ID: CGRect],
		nextValue: () -> [SidebarItem.ID: CGRect]
	) {
		value.merge(nextValue(), uniquingKeysWith: { _, new in new })
	}
}
