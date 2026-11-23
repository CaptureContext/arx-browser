import ChromiumBridge
import Foundation

extension ChromiumRuntime {
	/// ABI19. Unattended runs suppress page JavaScript dialogs and keep pages on
	/// before-unload instead of presenting app-modal UI. Configure before `run`.
	public var supportsUnattendedRuns: Bool {
		api.set_unattended != nil && api.unattended_dialog_count != nil
	}

	public func configureUnattended() throws {
		guard state == .idle else { throw ChromiumError.alreadyStarted }
		guard let configure = api.set_unattended else { throw ChromiumError.incompatibleBridge }
		configure(true)
	}

	/// Count only; dialog text is never retained.
	public var unattendedDialogCount: UInt64 {
		guard state == .running, let count = api.unattended_dialog_count else { return 0 }
		return count()
	}

	/// ABI22. Whether an unattended run can bound its shutdown and learn of a
	/// forced exit before it happens.
	public var supportsUnattendedShutdown: Bool {
		api.set_unattended_shutdown != nil
	}

	/// ABI22. Chromium force-exits a shutdown that is still running `deadline`
	/// after teardown starts. `expired` receives the exit code on Chromium's
	/// watchdog thread just before that exit; it must return quickly. Configure
	/// before `run`, after `configureUnattended()`.
	public func configureUnattendedShutdown(
		deadline: Duration,
		expired: @escaping @Sendable (Int32) -> Void
	) throws {
		guard state == .idle else { throw ChromiumError.alreadyStarted }
		guard let configure = api.set_unattended_shutdown
		else { throw ChromiumError.incompatibleBridge }

		let seconds = UInt32(clamping: max(1, deadline.components.seconds))

		// Chromium may call it until the process exits; the box is never released.
		let box = Unmanaged.passRetained(ShutdownExpiry(expired)).toOpaque()
		configure(
			seconds,
			{ context, code in
				guard let context else { return }
				Unmanaged<ShutdownExpiry>.fromOpaque(context).takeUnretainedValue().handler(Int32(code))
			},
			box
		)
	}
}

private final class ShutdownExpiry: Sendable {
	internal let handler: @Sendable (Int32) -> Void

	internal init(_ handler: @escaping @Sendable (Int32) -> Void) {
		self.handler = handler
	}
}
