import SwiftUI

public struct BrowserPeekActions: Sendable {
	public var openTab: @MainActor @Sendable (UUID) -> Void

	public init(openTab: @escaping @MainActor @Sendable (UUID) -> Void) {
		self.openTab = openTab
	}
}

extension EnvironmentValues {
	@Entry
	public var browserPeekActions: BrowserPeekActions? = nil
}

public struct BrowserPeekMenu: View {
	private let tabID: UUID

	@Environment(\.browserPeekActions)
	private var actions

	public init(tabID: UUID) {
		self.tabID = tabID
	}

	public var body: some View {
		if let actions {
			Button(String.localized(.appUI.peek.title)) { actions.openTab(tabID) }
		}
	}
}
