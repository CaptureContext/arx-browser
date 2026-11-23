import BrowserCore
import ChromiumEngine

internal enum ChromiumCloseAdapter {
	/// Native approval may suspend. Consumption, service disposal, and publication may not.
	@MainActor
	internal static func perform<Approval: Sendable>(
		authorize: @escaping @MainActor @Sendable () -> Bool,
		isCurrent: @escaping @MainActor @Sendable () -> Bool,
		approve: @MainActor () async throws -> Approval?,
		consume: @MainActor (Approval) throws -> Void,
		cancel: @MainActor (Approval) -> Void,
		didClose: @MainActor @Sendable () -> Void
	) async throws -> Bool {
		try validate(authorize: authorize, isCurrent: isCurrent)

		do {
			guard let approval = try await approve() else {
				try validate(authorize: authorize, isCurrent: isCurrent)
				return false
			}

			defer { cancel(approval) }

			try validate(authorize: authorize, isCurrent: isCurrent)
			try consume(approval)
			didClose()
			return true
		} catch let error as ChromiumCloseFailure {
			switch error {
			case .staleDocument: throw AutomationFailure.staleTarget
			case .unavailable: throw AutomationFailure.unsupported
			case .busy, .timedOut: throw AutomationFailure.engineFailed
			}
		}
	}

	@MainActor
	private static func validate(
		authorize: @MainActor @Sendable () -> Bool,
		isCurrent: @MainActor @Sendable () -> Bool
	) throws {
		try Task.checkCancellation()
		guard authorize()
		else { throw AutomationFailure.denied }
		guard isCurrent()
		else { throw AutomationFailure.staleTarget }
	}
}
