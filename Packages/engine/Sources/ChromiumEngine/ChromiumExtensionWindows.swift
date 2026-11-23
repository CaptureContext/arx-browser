import AppKit
import ChromiumBridge

/// ABI22. One page's place in an Arx window for the extensions tabs and windows
/// APIs. A window is identified by its AppKit window number; the engine gives
/// it a stable extension window ID while it stays open.
public struct ChromiumExtensionTabPlacement: Equatable, Sendable {
	public var windowNumber: Int
	public var index: Int
	public var isActive: Bool
	public var isHighlighted: Bool

	public init(
		windowNumber: Int,
		index: Int,
		isActive: Bool,
		isHighlighted: Bool
	) {
		self.windowNumber = windowNumber
		self.index = index
		self.isActive = isActive
		self.isHighlighted = isHighlighted
	}
}

extension ChromiumRuntime {
	public var supportsExtensionWindows: Bool {
		api.set_extension_tab_placements != nil
	}

	/// Replaces every page's placement at once; pages left out are in no window.
	/// Closed and foreign pages are ignored. Private pages may be listed but are
	/// never shown to an extension.
	public func setExtensionTabPlacements(
		_ placements: [(page: ChromiumPage, placement: ChromiumExtensionTabPlacement)]
	) {
		guard state == .running, let set = api.set_extension_tab_placements else { return }

		let values = placements.compactMap { page, placement -> ArxExtensionTabPlacement? in
			guard
				isCurrent(page),
				placement.windowNumber > 0,
				(0 ... Int(Int32.max)).contains(placement.index)
			else { return nil }

			return ArxExtensionTabPlacement(
				page: page.id,
				window_number: Int64(placement.windowNumber),
				index: Int32(placement.index),
				active: placement.isActive,
				highlighted: placement.isHighlighted
			)
		}
		values.withUnsafeBufferPointer { buffer in
			set(buffer.baseAddress, buffer.count)
		}
	}
}
