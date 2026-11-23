import AppUI
import SwiftUI

/// A row that opens a screen of its own (DEV-1114): an optional symbol, the title, a count or a
/// short summary on the right, such as "3 rules", and a chevron. Settings uses it for its pages,
/// such as Assistant › AI Commands and the long lists (Proxy Links, Search Shortcuts, …), and a
/// profile's page for its sheets.
///
/// A click, Return or → opens it; the screen it opens goes back with ⌘[ or ←.
///
/// ```swift
/// SettingsDrillDownRow("Proxy Links", symbol: "arrow.triangle.branch", summary: "3 rules") {
///     store.send(.ui(.pagePresented(.proxyLinks)))
/// }
/// ```
internal struct SettingsDrillDownRow: View {
	private let title: String
	private let symbol: String?
	private let summary: String?
	private let action: () -> Void

	internal init(
		_ title: String,
		symbol: String? = nil,
		summary: String? = nil,
		action: @escaping () -> Void
	) {
		self.title = title
		self.symbol = symbol
		self.summary = summary
		self.action = action
	}

	internal var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				if let symbol {
					Image(systemName: symbol)
						.foregroundStyle(.secondary)
						.frame(width: 20)
						.accessibilityHidden(true)
				}
				Text(title)
				Spacer(minLength: 12)
				if let summary {
					Text(summary)
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				Image(systemName: "chevron.right")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(.tertiary)
					.accessibilityHidden(true)
			}
			.settingsRow()
			.contentShape(.rect)
		}
		.buttonStyle(.settingsGroupRow)
		.onKeyPress(keys: [.return, .rightArrow]) { _ in
			action()
			return .handled
		}
		.accessibilityLabel(Text(title))
		.accessibilityValue(Text(summary ?? ""))
		.accessibilityHint(Text(localized: .appUI.settings.drillDownHint))
	}
}
