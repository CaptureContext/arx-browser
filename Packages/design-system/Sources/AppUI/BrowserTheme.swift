import SwiftUI

public enum BrowserTheme {
	public static var text: Color { .resource(.browser.text) }

	/// Translucent white over the tinted chrome: rows, buttons, and the space heading on hover.
	public static var hover: Color { .resource(.browser.hover) }

	/// A sidebar tab row under the pointer (DEV-1310): a tint of the text's color, so in the light
	/// appearance it's a little darker than the sidebar, where `hover`'s white read
	/// as a second, fainter selection. In the dark appearance it's `hover`'s own lift.
	public static var rowHover: Color {
		.init(nsColor: .init(name: nil) { appearance in
			appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			? .init(white: 1, alpha: 0.08)
			: .init(white: 0, alpha: 0.06)
		})
	}

	/// Near-opaque white in light appearance; the selected row and favorite read as raised.
	public static var selection: Color { .resource(.browser.selection) }

	/// `selection` laid over the sidebar's own color, opaque, for selected rows: the chrome's grain
	/// doesn't show through. It follows the sidebar's tint and light or dark appearance.
	public static var selectedRow: BrowserSelectionFill { .init() }

	/// Resting fill for the URL pill and favorite tiles.
	public static var fill: Color { .resource(.browser.fill) }

	/// Darkens the Library's fills in the light appearance and lifts them in the dark one.
	public static var libraryTint: Color { .resource(.browser.libraryTint) }

	/// The page card's hairline: dark on light chrome, light on dark chrome.
	public static var pageBorder: Color { .resource(.browser.pageBorder) }

	/// The appearance cascade's accent (DEV-1117), legible on the sidebar; Arx's own with the
	/// feature flag off.
	public static var accent: BrowserAccent { .init() }
	public static var surface: Color { .resource(.browser.surface) }
	public static var divider: Color { .resource(.browser.divider) }
	public static var border: Color { .resource(.browser.border) }
	public static var commandBackground: Color { .resource(.browser.commandBackground) }

	/// Laid over the chrome tint so the revealed sidebar separates from the page behind it.
	public static var floatingSidebarOverlay: Color { .resource(.browser.floatingSidebarOverlay) }

	/// Text and symbols on an accent fill: white, or near black on a pale accent (DEV-1117).
	public static var onAccent: BrowserOnAccent { .init() }
	public static var folderOutline: Color { .resource(.browser.folderOutline) }

	/// `text` at `BrowserMetrics.State.secondaryOpacity`, less transparent under Increase Contrast.
	public static var secondary: Color { .resource(.browser.secondaryText) }

	/// Behind the sidebar and around the page card, in the tint the environment carries.
	public static var sidebar: BrowserChromeGradient { .init(.sidebar) }

	/// Behind web content in the page card, in the tint the environment carries.
	public static var page: BrowserChromeGradient { .init(.page) }
}

public enum SidebarTint: String, Codable, Sendable {
	case lavender
	case blue
	case green
	case orange
	case pink
	case yellow
	case white

	public var color: Color {
		switch self {
		case .lavender: .resource(.browser.lavender)
		case .blue: .resource(.browser.blue)
		case .green: .resource(.browser.green)
		case .orange: .resource(.browser.orange)
		case .pink: .resource(.browser.pink)
		case .yellow: .resource(.browser.yellow)
		case .white: BrowserTheme.text
		}
	}
}

internal struct ChromeButtonStyle: ButtonStyle {
	@SwiftUI.State
	private var hovered: Bool

	internal init() {
		self._hovered = .init(initialValue: false)
	}

	internal func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.background(
				hovered || configuration.isPressed ? BrowserTheme.hover : .clear,
				in: ArxControlShape()
			)
			.opacity(configuration.isPressed ? BrowserMetrics.State.pressedOpacity : 1)
			.onHover { hovered = $0 }
	}
}
