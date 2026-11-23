#if DEBUG
import CloudKit
import Darwin
import Foundation

/// Debug-only check that a signed build can reach its iCloud container.
///
/// `Arx --arx-cloudkit-probe` asks CloudKit for the account status, prints one
/// `ARX_CLOUDKIT_PROBE` line and exits before the engine starts. Any status means the
/// entitlements and the embedded provisioning profile were accepted; an error or no
/// answer means they weren't.
internal enum CloudKitProbe {
	internal static let argument: String = "--arx-cloudkit-probe"
	internal static let containerIdentifier: String = "iCloud.dev.capturecontext.arx"
	private static let timeout: DispatchTimeInterval = .seconds(30)

	/// The exit code when the probe was asked for, otherwise `nil`.
	internal static func runIfRequested(arguments: [String]) -> Int32? {
		guard arguments.contains(argument)
		else { return nil }

		let outcome: Outcome = .init()
		let done: DispatchSemaphore = .init(value: 0)
		CKContainer(identifier: containerIdentifier).accountStatus { status, error in
			outcome.set(status: status, error: error)
			done.signal()
		}
		guard done.wait(timeout: .now() + timeout) == .success else {
			report("result=timeout")
			return 2
		}

		let (status, error) = outcome.value
		if let error {
			report("result=error domain=\((error as NSError).domain) code=\((error as NSError).code)")
			return 1
		}
		report("result=returned status=\(name(of: status))")
		return 0
	}

	private static func report(_ details: String) {
		print("ARX_CLOUDKIT_PROBE container=\(containerIdentifier) \(details)")
		fflush(stdout)
	}

	private static func name(of status: CKAccountStatus) -> String {
		switch status {
		case .available: "available"
		case .noAccount: "noAccount"
		case .restricted: "restricted"
		case .couldNotDetermine: "couldNotDetermine"
		case .temporarilyUnavailable: "temporarilyUnavailable"
		@unknown default: "unknown(\(status.rawValue))"
		}
	}
}

private final class Outcome: @unchecked Sendable {
	private let lock: NSLock = .init()
	private var status: CKAccountStatus = .couldNotDetermine
	private var error: (any Error)?

	internal var value: (CKAccountStatus, (any Error)?) {
		lock.withLock { (status, error) }
	}

	internal func set(
		status: CKAccountStatus,
		error: (any Error)?
	) {
		lock.withLock {
			self.status = status
			self.error = error
		}
	}
}
#endif
