import SwiftUI

/// The current space's profile badge beside the sidebar toggle.
/// With a menu, it offers moving the space to another profile.
internal struct SidebarProfileCapsule: View {
	private let name: String
	private let menu: (() -> AnyView)?

	internal init(
		name: String,
		menu: (() -> AnyView)? = nil
	) {
		self.name = name
		self.menu = menu
	}

	internal var body: some View {
		if let menu {
			Menu {
				menu()
			} label: {
				capsule
			}
			.menuStyle(.button)
			.buttonStyle(.plain)
			.menuIndicator(.hidden)
			.fixedSize(horizontal: false, vertical: true)
			.help(String.localized(.appUI.sidebar.profileHelp))
			.accessibilityLabel(String.localized(.appUI.sidebar.profileLabel(name)))
		} else {
			capsule
				.accessibilityElement(children: .combine)
				.accessibilityLabel(String.localized(.appUI.sidebar.profileLabel(name)))
		}
	}

	private var capsule: some View {
		ProfileBadge(name: name, style: .quiet)
			.fixedSize(horizontal: false, vertical: true)
	}
}
