import Foundation

/// Invalidated by the reducer before cancellation effects are scheduled. A delayed effect
/// must still pass this check before admitting typed text to a provider (DEV-606).
internal final class SuggestionRequest: @unchecked Sendable, Equatable {
	private let lock: NSLock = .init()
	private var isValid: Bool = true

	internal init() {}

	internal var canSend: Bool { lock.withLock { isValid } }

	internal func invalidate() {
		lock.withLock { isValid = false }
	}

	internal static func == (lhs: SuggestionRequest, rhs: SuggestionRequest) -> Bool {
		lhs === rhs
	}
}
