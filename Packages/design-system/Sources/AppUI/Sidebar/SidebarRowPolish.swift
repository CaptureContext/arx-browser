import BrowserCore
import Foundation
import SwiftUI

/// Sidebar rows (17 Nov): a tab's close button takes room only while the row is
/// hovered, sits closer to the title and shows its shape on the selected row too; folder titles
/// are bold, and folders draw a light body in an accent outline. On by default, as every flag is
/// for the beta. `ARX_SIDEBAR_ROW_POLISH` set to `0`, `false`, `no` or `off` brings back the
/// earlier rows.
public enum SidebarRowPolish {
	public static let featureFlag: String = FeatureFlag.sidebarRowPolish.name

	/// Whether the rows are polished. Read once, through the `FeatureFlag` registry: the
	/// environment, then Arx's defaults under the flag's name.
	public static let isEnabled: Bool = FeatureFlag.sidebarRowPolish.isOn()

	/// What one value turns it to.
	internal static func isOn(read: (String) -> String?) -> Bool {
		read(featureFlag).flatMap(FeatureFlag.parse) ?? FeatureFlag.sidebarRowPolish.isOnByDefault
	}
}

extension EnvironmentValues {
	/// Whether sidebar rows draw as `SidebarRowPolish` describes. Snapshots set it; the app leaves
	/// it at the flag.
	@Entry
	internal var sidebarRowPolish: Bool = SidebarRowPolish.isEnabled
}

extension View {
	/// A row's close button: `ChromeInlineButtonStyle` filling the button while rows are polished,
	/// so its shape shows darker than the row under it, the selected row too; else the chrome's own.
	internal func sidebarRowControlButtonStyle() -> some View {
		modifier(SidebarRowControlButtonStyleChoice())
	}
}

private struct SidebarRowControlButtonStyleChoice: ViewModifier {
	@Environment(\.sidebarRowPolish)
	private var polish

	@ViewBuilder
	fileprivate func body(content: Content) -> some View {
		if polish {
			content.buttonStyle(ChromeInlineButtonStyle(shapeInset: 0))
		} else {
			content.buttonStyle(ChromeButtonStyle())
		}
	}
}
