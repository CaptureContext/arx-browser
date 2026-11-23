import Foundation

/// ABI62 (DEV-1264, DEV-1073). A ⌘ key down a page received, as the engine reports it: enough to
/// match the `NSEvent` the app let through to the page.
public struct ChromiumCommandKey: Equatable, Hashable, Sendable {
	/// The event's `keyCode`.
	public var keyCode: UInt16

	/// The event's device-independent `modifierFlags`, as raw bits.
	public var modifierFlags: UInt64

	/// The event's `timestamp`.
	public var timestamp: TimeInterval

	public init(
		keyCode: UInt16,
		modifierFlags: UInt64,
		timestamp: TimeInterval
	) {
		self.keyCode = keyCode
		self.modifierFlags = modifierFlags
		self.timestamp = timestamp
	}
}
