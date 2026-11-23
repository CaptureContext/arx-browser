import ChromiumEngine

/// Keeps the intentional stale-authority probe separate from a fresh user action
/// after asynchronous unload work. This is used only by the disposable fixture.
@MainActor
internal enum ExtensionSmokeDisableEnable {
	internal static func run(
		extensionID: String,
		inspect: () async throws -> ChromiumExtensionInventory,
		manage: (ChromiumExtensionAction, ChromiumExtensionInventory) async throws -> ChromiumExtensionInventory,
		waitUntilUnloaded: () async throws -> Void,
		phase: (String) -> Void
	) async throws {
		phase("disable-inspect")
		let initial = try await inspect()
		phase("disable-apply")
		let disabled = try await manage(.disable, initial)
		try requireUserDisabled(extensionID, in: disabled)

		phase("stale-probe")
		do {
			_ = try await manage(.disable, initial)
			throw Failure.staleAccepted
		} catch ChromiumExtensionFailure.staleInventory {}

		phase("disabled-page-reload")
		try await waitUntilUnloaded()
		try Task.checkCancellation()

		// Registry/prefs callbacks can invalidate the mutation response while
		// the page reloads. A new enable action must inspect its current authority.
		phase("enable-refresh")
		let current = try await inspect()
		try requireUserDisabled(extensionID, in: current)
		phase("enable-apply")
		_ = try await manage(.enable, current)
	}

	private static func requireUserDisabled(
		_ extensionID: String,
		in inventory: ChromiumExtensionInventory
	) throws {
		guard
			let extension_ = inventory.extensions.first(where: { $0.id == extensionID }),
			extension_.isFixture,
			extension_.state == .disabled,
			extension_.disableReasons == [.userAction]
		else { throw Failure.disabledState }
	}

	internal enum Failure: Error, Equatable {
		case disabledState
		case staleAccepted
	}
}
