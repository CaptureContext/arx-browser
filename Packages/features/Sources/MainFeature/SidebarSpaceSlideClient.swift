import AppKit
import AppUI
import BrowserCore
import _ComposableArchitecture

/// Slides the key window's sidebar to a space before the space is selected, for a choice the
/// reducer hears of first, such as the command bar's Switch to Space (DEV-1310).
///
/// The keys, the menu and the switcher's buttons reach `SidebarSpaceSwitch` from their views.
/// The command bar's choice arrives as an action, so the reducer asks through this instead of
/// selecting the space itself, and selects it only where the sidebar can't slide.
public struct SidebarSpaceSlideClient: Sendable {
	/// Slides to the space at this place among the window's spaces, counting from 0. Returns
	/// whether the sidebar took it; it then reports the space as selected once it lands.
	public var slide: @MainActor @Sendable (_ spaceIndex: Int) -> Bool

	public init(slide: @escaping @MainActor @Sendable (_ spaceIndex: Int) -> Bool) {
		self.slide = slide
	}

	/// Never slides, so the space is selected at once: tests, previews and windows without a sidebar.
	public static let none: Self = .init { _ in false }
}

extension SidebarSpaceSlideClient: DependencyKey {
	public static var liveValue: Self {
		.init { index in
			guard let window = NSApplication.shared.keyWindow else { return false }
			return SidebarSpaceSwitch.select(spaceAt: index, in: window)
		}
	}

	public static var testValue: Self { .none }

	public static var previewValue: Self { .none }
}

extension DependencyValues {
	public var sidebarSpaceSlide: SidebarSpaceSlideClient {
		get { self[SidebarSpaceSlideClient.self] }
		set { self[SidebarSpaceSlideClient.self] = newValue }
	}
}
