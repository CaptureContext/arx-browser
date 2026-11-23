import Foundation

/// A weak reference to a main-actor object, for a completion handler that runs on another queue
/// and hops back to the main actor (DEV-1144).
internal final class WeakReference<Object: AnyObject>: @unchecked Sendable {
	internal weak var object: Object?

	internal init(_ object: Object) {
		self.object = object
	}
}

/// A flag read from any thread under a lock (DEV-1144).
internal final class FairPlaySharedFlag: @unchecked Sendable {
	private let lock: NSLock = NSLock()
	private var value: Bool = false

	internal func withLock<Result>(_ body: (inout Bool) -> Result) -> Result {
		lock.lock()
		defer { lock.unlock() }
		return body(&value)
	}
}
