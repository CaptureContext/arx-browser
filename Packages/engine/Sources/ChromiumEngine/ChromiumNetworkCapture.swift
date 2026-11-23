import ChromiumBridge
import Foundation

extension ChromiumRuntime {
	/// DEV-924: whether this engine keeps request headers and bodies for `browser_logs`.
	public var supportsNetworkCapture: Bool { networkCapture != nil }

	/// Starts or stops keeping an ordinary page's request details; stopping drops them.
	public func setNetworkCapture(
		_ page: ChromiumPage,
		enabled: Bool
	) -> Bool {
		guard state == .running, let networkCapture, pages[page.id] === page, !page.isPrivate
		else { return !enabled }

		return networkCapture.set(page.id, enabled)
	}

	/// The kept request details after `after`, as the engine's JSON, or nil when the page isn't
	/// keeping them.
	public func readNetworkCapture(
		_ page: ChromiumPage,
		after: UInt64,
		limit: Int,
		bodyBytes: Int
	) -> Data? {
		guard state == .running, let networkCapture, pages[page.id] === page, !page.isPrivate
		else { return nil }

		let limit = UInt32(clamping: limit)
		let bodyBytes = UInt32(clamping: bodyBytes)

		// New requests can land between the two calls; reading again with the larger size settles it.
		var capacity = 0
		for _ in 0..<4 {
			var buffer = [CChar](repeating: 0, count: capacity)
			let length = buffer.withUnsafeMutableBufferPointer { pointer in
				networkCapture.read(page.id, after, limit, bodyBytes, pointer.baseAddress, capacity)
			}
			guard length > 0 else { return nil }
			if capacity > length {
				return buffer.withUnsafeBufferPointer { pointer in
					Data(bytes: pointer.baseAddress!, count: length)
				}
			}
			capacity = length + 1 + 4_096
		}
		return nil
	}
}
