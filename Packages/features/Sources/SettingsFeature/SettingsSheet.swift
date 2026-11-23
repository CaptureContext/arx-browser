import AppUI
import SwiftUI

/// The container every Settings sheet shares, such as Air Traffic Control, Search Shortcuts and
/// Local assistants (MCP): AppUI's header bar on top (DEV-782, DEV-790), with a rounded-square
/// raised Close tile, the title over the trail that led there and optional trailing controls,
/// such as a search that expands into a wide field; then the content, scrolling edge to edge
/// under the bar, where Arx's progressive edge blurs it, on the window's own background.
///
/// Close also answers Escape. The sheet scrolls the content itself.
public struct SettingsSheet<Trailing: View, Content: View>: View {
	private let title: String
	private let trail: [String]
	private let width: CGFloat
	private let height: CGFloat?
	private let close: () -> Void
	private let trailing: Trailing
	private let content: Content

	/// `trail` is where the sheet opens from, such as `["Links"]` for Air Traffic Control.
	/// `trailing` holds the bar's own controls, such as an `ArxHeaderSearch`.
	public init(
		_ title: String,
		trail: [String] = [],
		width: CGFloat = SettingsSheetMetrics.width,
		height: CGFloat? = nil,
		close: @escaping () -> Void,
		@ViewBuilder trailing: () -> Trailing,
		@ViewBuilder content: () -> Content
	) {
		self.title = title
		self.trail = trail
		self.width = width
		self.height = height
		self.close = close
		self.trailing = trailing()
		self.content = content()
	}

	public var body: some View {
		ArxModalScaffold(contentPadding: SettingsSheetMetrics.contentPadding) {
			SettingsNavigationBar(.close(close), title: title, trail: trail) { trailing }
		} content: {
			content
		}
		.font(SettingsTypography.body)
		.frame(width: width, height: height)
		.background(SettingsSheetMetrics.background)
		.settingsControls()
	}
}

extension SettingsSheet where Trailing == EmptyView {
	public init(
		_ title: String,
		trail: [String] = [],
		width: CGFloat = SettingsSheetMetrics.width,
		height: CGFloat? = nil,
		close: @escaping () -> Void,
		@ViewBuilder content: () -> Content
	) {
		self.init(title, trail: trail, width: width, height: height, close: close, trailing: { EmptyView() }, content: content)
	}
}

public enum SettingsSheetMetrics {
	public static let width: CGFloat = 620

	/// Between a sheet's content and its edges.
	public static let contentPadding: CGFloat = ArxModalMetrics.contentPadding

	/// The window's own background, as a sheet draws by default: no tint of its own.
	public static let background: Color = ArxModalMetrics.background
}
