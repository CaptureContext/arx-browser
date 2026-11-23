import AppKit
import BrowserCore

extension AppIconStyle {
	/// The icon as Icon Composer renders `AppIcon.icon` in this appearance (DEV-839).
	public var image: NSImage? {
		switch self {
		case .dark: NSImage.resource(.appIcon.dark)
		case .light: NSImage.resource(.appIcon.light)
		}
	}

	public var title: String {
		switch self {
		case .dark: String.localized(.appUI.settings.iconDark)
		case .light: String.localized(.appUI.settings.iconLight)
		}
	}
}
