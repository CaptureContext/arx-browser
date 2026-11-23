import Foundation

/// The search in a folder's hover preview (DEV-836): what's typed, which result is selected and
/// whether the preview may still close when the pointer leaves it.
///
/// Once the user takes the keyboard into the preview (Tab while the folder is hovered, or a click
/// in its field) or types, the preview stays open, even when nothing matches. It then closes
/// only when a tab is opened, the user clicks elsewhere or presses Escape.
public struct SidebarFolderSearch: Equatable, Sendable {
	public var query: String

	/// The row last chosen with the arrows or the pointer. `selection(in:)` is what's shown.
	public var selection: UUID?

	/// Whether the user has taken the keyboard into the preview or typed into it.
	public var isEngaged: Bool

	public init(
		query: String = "",
		selection: UUID? = nil,
		isEngaged: Bool = false
	) {
		self.query = query
		self.selection = selection
		self.isEngaged = isEngaged
	}

	public enum Direction: Equatable, Sendable {
		case up
		case down
	}

	public enum Action: Equatable, Sendable {
		/// The preview took the keyboard: Tab while the folder is hovered, or a click in its field.
		case focused
		case queryChanged(String)

		/// ↑ or ↓ over the results as they're listed now.
		case moved(Direction, results: [UUID])

		/// The pointer rests on a row, which selects it, as in the command bar.
		case rowHovered(UUID)

		/// Return over the results as they're listed now.
		case submitted(results: [UUID])
		case rowClicked(UUID)

		/// The pointer has left both the folder and its preview.
		case pointerLeft

		/// The preview lost the keyboard to another window: the user clicked elsewhere.
		case clickedElsewhere
		case escape
	}

	public enum Effect: Equatable, Sendable {
		case none
		case open(UUID)
		case dismiss
	}

	/// The selected row among `results`: the chosen one while it's still listed, otherwise the
	/// first result while there's a query, otherwise none.
	public func selection(in results: [UUID]) -> UUID? {
		if let selection, results.contains(selection) { return selection }
		return query.isEmpty ? nil : results.first
	}

	public mutating func reduce(_ action: Action) -> Effect {
		switch action {
		case .focused:
			isEngaged = true
			return .none

		case let .queryChanged(query):
			guard query != self.query else { return .none }
			self.query = query
			isEngaged = true
			return .none

		case let .moved(direction, results):
			guard !results.isEmpty else { return .none }
			let current = selection(in: results).flatMap(results.firstIndex(of:))
			let index = switch (direction, current) {
			case (.down, nil): results.startIndex
			case (.up, nil): results.index(before: results.endIndex)
			case let (.down, index?): min(index + 1, results.index(before: results.endIndex))
			case let (.up, index?): max(index - 1, results.startIndex)
			}
			selection = results[index]
			return .none

		case let .rowHovered(id):
			selection = id
			return .none

		case let .submitted(results):
			guard let id = selection(in: results) else { return .none }
			return .open(id)

		case let .rowClicked(id):
			return .open(id)

		case .pointerLeft:
			return isEngaged ? .none : .dismiss

		case .clickedElsewhere, .escape:
			return .dismiss
		}
	}
}
