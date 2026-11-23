import AppUI
import SwiftUI

/// The bar on top of a page inside a pane and of a sheet: AppUI's header bar
/// (DEV-762, DEV-782, DEV-790), with a rounded-square raised Back or Close tile, the title in
/// bold and, under it, the trail that led there in small grey type, then the bar's own controls
/// on the trailing edge.
///
/// It lays out its own row only and draws no background. A page pins it over its scroll view
/// with `arxScrollBar`, where Arx's progressive edge blurs content beneath it; a sheet
/// gets it from `SettingsSheet`.
///
/// ```swift
/// SettingsNavigationBar(.back { dismiss() }, title: "AI Commands", trail: ["Assistant"])
/// ```
internal struct SettingsNavigationBar<Trailing: View>: View {
	internal typealias Leading = ArxHeaderBarLeading

	private let leading: Leading
	private let title: String
	private let trail: [String]
	private let height: CGFloat
	private let trailing: Trailing

	/// `trail` is where the page or sheet sits, without its own title, such as
	/// `["Profiles", "Work"]` for a profile's Site Settings.
	internal init(
		_ leading: Leading,
		title: String,
		trail: [String] = [],
		height: CGFloat = ArxHeaderBarMetrics.height,
		@ViewBuilder trailing: () -> Trailing
	) {
		self.leading = leading
		self.title = title
		self.trail = trail
		self.height = height
		self.trailing = trailing()
	}

	internal var body: some View {
		ArxHeaderBar(
			leading,
			title: title,
			subtitle: trail.isEmpty ? nil : trail.joined(separator: " › "),
			height: height
		) {
			trailing
		}
	}
}

extension SettingsNavigationBar where Trailing == EmptyView {
	internal init(
		_ leading: Leading,
		title: String,
		trail: [String] = [],
		height: CGFloat = ArxHeaderBarMetrics.height
	) {
		self.init(leading, title: title, trail: trail, height: height) { EmptyView() }
	}
}
