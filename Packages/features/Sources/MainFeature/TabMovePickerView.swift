import AppUI
import BrowserCore
import SwiftUI

internal struct TabMovePickerView: View {
	internal let picker: TabMovePicker
	internal let onChoose: (Space.ID, Folder.ID?) -> Void
	internal let onCancel: () -> Void

	/// Each destination is validated with a trial move, so they are resolved once per picker.
	private let destinations: [TabMovePicker.Destination]

	@SwiftUI.State
	private var query: String

	@SwiftUI.State
	private var selection: String?

	@FocusState
	private var searchFocused: Bool

	internal init(
		picker: TabMovePicker,
		onChoose: @escaping (Space.ID, Folder.ID?) -> Void,
		onCancel: @escaping () -> Void
	) {
		self.picker = picker
		self.onChoose = onChoose
		self.onCancel = onCancel
		self.destinations = picker.destinations
		self._query = .init(initialValue: "")
		self._selection = .init(initialValue: nil)
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(localized: .appUI.move.title).font(.title2)
			Text(localized: .appUI.move.order).foregroundStyle(.secondary)
			TextField(String.localized(.appUI.move.search), text: $query).focused($searchFocused)
				.onSubmit(choose)
			List(options, selection: $selection) { option in
				Text(option.path)

					// A double-click anywhere in the row chooses it, not only on the text (DEV-1002).
					.rowHitArea()
					.tag(option.id)
					.accessibilityLabel(option.path)
					.accessibilityAction { onChoose(option.spaceID, option.folderID) }
					.onTapGesture(count: 2) { onChoose(option.spaceID, option.folderID) }
			}
			.accessibilityLabel(String.localized(.appUI.move.destination))
			.onKeyPress(.return) {
				choose()
				return .handled
			}
			HStack {
				Spacer()
				Button(String.localized(.appUI.common.cancel), action: onCancel)
					.keyboardShortcut(.cancelAction)
				Button(String.localized(.appUI.move.confirm), action: choose)
					.keyboardShortcut(.defaultAction)
					.disabled(chosen == nil)
			}
		}
		.padding(24).frame(width: 560, height: 440)
		.onAppear { searchFocused = true }
	}

	private var options: [TabMovePicker.Destination] {
		destinations.filter { query.isEmpty || $0.path.localizedStandardContains(query) }
	}

	private var chosen: TabMovePicker.Destination? {
		let options = options
		return options.first { $0.id == selection } ?? options.first
	}

	private func choose() {
		guard let chosen else { return }

		onChoose(chosen.spaceID, chosen.folderID)
	}
}

extension TabMovePicker {
	public struct Destination: Identifiable, Equatable, Sendable {
		public var spaceID: Space.ID
		public var folderID: Folder.ID?
		public var path: String

		public init(
			spaceID: Space.ID,
			folderID: Folder.ID?,
			path: String
		) {
			self.spaceID = spaceID
			self.folderID = folderID
			self.path = path
		}

		public var id: String { spaceID.rawValue.uuidString + (folderID?.rawValue.uuidString ?? "") }
	}

	public var destinations: [Destination] {
		var result: [Destination] = []
		for profile in organization.profiles {
			for space in organization.spaces where space.profileID == profile.id {
				let path = profile.name + " / " + space.name

				func append(
					_ folderID: Folder.ID?,
					_ path: String
				) {
					let destination = folderID.map(OrganizationMoveDestination.folder) ?? .spaceRoot
					let isValid = (try? organization.moving(
						roots.map(\.savedItem),
						to: destination,
						in: space.id,
						newTabID: { .init(rawValue: UUID()) }
					)) != nil

					if isValid {
						result.append(.init(spaceID: space.id, folderID: folderID, path: path))
					}
				}

				func descend(
					_ items: [SavedItem],
					_ path: String
				) {
					for item in items {
						guard
							case let .folder(id) = item,
							let folder = organization.folders[id: id]
						else { continue }
						let nested = path + " / " + folder.name
						append(id, nested)
						descend(folder.children, nested)
					}
				}

				append(nil, path)
				descend(space.savedItems, path)
			}
		}
		return result
	}
}
