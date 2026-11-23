import BrowserCore
import SwiftUI

/// One back or forward arrow. A click navigates; holding or secondary-clicking
/// it opens a native history menu, which provides keyboard selection, scrolling for long
/// histories and Escape cancellation.
public struct BrowserHistoryControl: View {
	private let navigation: BrowserNavigation
	private let direction: BrowserNavigation.HistoryDirection
	private let navigate: () -> Void
	private let select: (Int) -> Void

	public init(
		navigation: BrowserNavigation,
		direction: BrowserNavigation.HistoryDirection,
		navigate: @escaping () -> Void,
		select: @escaping (Int) -> Void
	) {
		self.navigation = navigation
		self.direction = direction
		self.navigate = navigate
		self.select = select
	}

	public var body: some View {
		let _ = RenderTrace.body("BrowserHistoryControl.body")
		Menu {
			historyMenu
		} label: {
			Image(systemName: direction == .back ? "arrow.left" : "arrow.right")
		} primaryAction: {
			navigate()
		}
		.menuStyle(.button)
		.menuIndicator(.hidden)
		.disabled(direction == .back ? !navigation.canGoBack : !navigation.canGoForward)
		.help(String.localized(direction == .back ? .appUI.navigation.back : .appUI.navigation.forward))
		.contextMenu { historyMenu }
		.accessibilityHint(historyTitle)
	}

	private var historyTitle: String {
		String.localized(direction == .back ? .appUI.navigation.backHistory : .appUI.navigation.forwardHistory)
	}

	private var historyMenu: some View {
		ForEach(navigation.entries(in: direction)) { entry in
			Button { select(entry.id) } label: {
				VStack(alignment: .leading) {
					Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title)
					if !entry.title.isEmpty {
						Text(entry.url.absoluteString)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
			.help(entry.url.absoluteString)
			.accessibilityLabel(
				entry.title.isEmpty
				? entry.url.absoluteString
				: entry.title + ", " + entry.url.absoluteString
			)
		}
	}
}
