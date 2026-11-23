import BrowserCore
import Foundation

/// Who asked for a tab's picker, so it opens on that window (DEV-927).
public struct CastPickerRequest: Equatable, Sendable {
	public var tabID: BrowserCore.Tab.ID
	public var windowID: UUID

	public init(
		tabID: BrowserCore.Tab.ID,
		windowID: UUID
	) {
		self.tabID = tabID
		self.windowID = windowID
	}
}
