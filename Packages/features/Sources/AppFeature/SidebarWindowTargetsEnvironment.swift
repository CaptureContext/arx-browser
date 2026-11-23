import AppUI
import BrowserCore
import Foundation
import MainFeature
import SwiftUI
import _ComposableArchitecture

/// Keeps a window's list for Move to Window current. The list is read here, beside the window, so
/// a change renders only the tab menus that show it (DEV-883).
internal struct SidebarWindowTargetsEnvironment: ViewModifier {
	private let store: StoreOf<AppFeature>
	private let windowID: UUID
	private let isPrivate: Bool

	@SwiftUI.State
	private var targets: SidebarWindowTargets

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID,
		isPrivate: Bool
	) {
		self.store = store
		self.windowID = windowID
		self.isPrivate = isPrivate
		self._targets = .init(initialValue: .init())
	}

	internal func body(content: Content) -> some View {
		let current: [SidebarWindowTarget] = isPrivate ? [] : store.state.sidebarWindowTargets(from: windowID)
		content
			.environment(\.sidebarWindowTargets, isPrivate ? nil : targets)
			.onChange(of: current, initial: true) { _, current in
				guard targets.targets != current else { return }
				targets.targets = current
			}
	}
}
