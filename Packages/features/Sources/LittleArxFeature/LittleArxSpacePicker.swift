import AppUI
import BrowserCore
import SwiftUI

extension LittleArxView.Destination {
	/// Matches a search against the space's name and its profile's.
	public func matches(_ query: String) -> Bool {
		let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
		return query.isEmpty || menuTitle.localizedCaseInsensitiveContains(query)
	}
}

/// Chooses which space a Little Arx page opens in, by searching or with the arrow keys.
internal struct LittleArxSpacePicker: View {
	internal typealias Destination = LittleArxView.Destination

	private let destinations: [Destination]
	private let currentSpaceID: Space.ID
	private let onSelect: (Destination) -> Void
	private let onDismiss: () -> Void

	@SwiftUI.State
	private var query: String

	@SwiftUI.State
	private var highlightedID: Space.ID?

	@FocusState
	private var isSearching: Bool

	internal init(
		destinations: [Destination],
		currentSpaceID: Space.ID,
		onSelect: @escaping (Destination) -> Void,
		onDismiss: @escaping () -> Void
	) {
		self.destinations = destinations
		self.currentSpaceID = currentSpaceID
		self.onSelect = onSelect
		self.onDismiss = onDismiss
		self._query = .init(initialValue: "")
		self._highlightedID = .init(initialValue: currentSpaceID)
	}

	private var results: [Destination] {
		destinations.filter { $0.matches(query) }
	}

	private var metrics: BrowserMetrics.LittleArx.SpacePicker.Type {
		BrowserMetrics.LittleArx.SpacePicker.self
	}

	internal var body: some View {
		VStack(spacing: 0) {
			searchField
			ScrollViewReader { proxy in
				ScrollView {
					VStack(spacing: 0) {
						ForEach(results) { destination in
							row(destination).id(destination.id)
						}
					}
				}
				.onChange(of: highlightedID) { _, id in
					if let id { proxy.scrollTo(id) }
				}
			}
		}
		.frame(width: metrics.width)
		.frame(maxHeight: metrics.maximumHeight)
		.fixedSize(horizontal: false, vertical: true)
		.background { BrowserChromeBackground(textured: false) }
		.clipShape(.rect(cornerRadius: metrics.cornerRadius, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
				.strokeBorder(BrowserTheme.pageBorder, lineWidth: 1)
		}
		.browserShadow(BrowserMetrics.FloatingSidebar.shadow)
		.onAppear { isSearching = true }
		.onKeyPress(.upArrow) { move(-1) }
		.onKeyPress(.downArrow) { move(1) }
		.onKeyPress(.return) {
			if let highlighted = results.first(where: { $0.id == highlightedID }) ?? results.first {
				onSelect(highlighted)
			}
			return .handled
		}
		.onExitCommand(perform: onDismiss)
	}

	private var searchField: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(BrowserTheme.secondary)
			TextField(String.localized(.appUI.littleArx.searchSpaces), text: $query)
				.textFieldStyle(.plain)
				.focused($isSearching)
				.onChange(of: query) { _, _ in highlightedID = results.first?.id }
			Divider().frame(height: 16)
			Button(action: onDismiss) {
				Image(systemName: "chevron.up")
			}
			.buttonStyle(.plain)
			.accessibilityLabel(String.localized(.appUI.migration.close))
		}
		.font(.system(size: 13, weight: .medium))
		.padding(.horizontal, 12)
		.frame(height: metrics.searchHeight)
	}

	private func row(_ destination: Destination) -> some View {
		Button { onSelect(destination) } label: {
			HStack(spacing: 10) {
				SpaceIconImage(rawValue: destination.icon ?? SpaceIcon.dot.rawValue)
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(BrowserTheme.onAccent)
					.frame(width: metrics.tileSize, height: metrics.tileSize)
					.background(BrowserTheme.accent, in: ArxControlShape())
				Text(destination.name)
					.lineLimit(1)
				Spacer(minLength: 0)
			}
			.font(.system(size: 13, weight: .medium))
			.foregroundStyle(BrowserTheme.text)
			.padding(.horizontal, 8)
			.frame(height: metrics.rowHeight)
			.background(destination.id == highlightedID ? BrowserTheme.hover : .clear)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.help(destination.menuTitle)
		.onHover { if $0 { highlightedID = destination.id } }
		.accessibilityAddTraits(destination.id == currentSpaceID ? .isSelected : [])
	}

	private func move(_ offset: Int) -> KeyPress.Result {
		let results = results
		guard !results.isEmpty else { return .handled }

		let current = results.firstIndex { $0.id == highlightedID } ?? -offset
		highlightedID = results[min(max(current + offset, 0), results.count - 1)].id
		return .handled
	}
}
