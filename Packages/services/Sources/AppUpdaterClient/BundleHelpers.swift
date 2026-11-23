import Darwin
import Foundation

extension AppUpdaterClient {
	/// Waits until no helper runs, checking every `interval`, for at most `deadline`.
	///
	/// Returns whether every helper exited in time. Quitting goes on either way: the deadline only
	/// keeps a stuck helper from holding Arx open forever.
	@discardableResult
	public static func waitForHelpers(
		deadline: Duration,
		interval: Duration = .milliseconds(100),
		sleep: (Duration) -> Void = { duration in
			let (seconds, attoseconds) = duration.components
			Thread.sleep(forTimeInterval: TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
		},
		running: () -> Int
	) -> Bool {
		var waited: Duration = .zero
		while running() > 0 {
			guard waited < deadline
			else { return false }

			sleep(interval)
			waited += interval
		}
		return true
	}
}

/// Arx's own child processes that run from inside its bundle: Chromium's renderer, GPU,
/// network and plugin helpers. Agent processes and other tools Arx starts aren't counted.
internal enum BundleHelpers {
	internal static func running(in bundle: URL) -> Int {
		let prefix: String = bundle.resolvingSymlinksInPath().path(percentEncoded: false)
		let directory: String = prefix.hasSuffix("/") ? prefix : prefix + "/"
		return children().count { pid in
			path(of: pid)?.hasPrefix(directory) == true
		}
	}

	private static func children() -> [pid_t] {
		let parent: pid_t = getpid()
		let needed: Int32 = proc_listchildpids(parent, nil, 0)
		guard needed > 0
		else { return [] }

		// Room for helpers started between the two calls.
		let capacity: Int = Int(needed) + 16
		var pids: [pid_t] = .init(repeating: 0, count: capacity)
		let filled: Int32 = pids.withUnsafeMutableBytes { buffer in
			proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
		}
		guard filled > 0
		else { return [] }

		return Array(pids.prefix(Int(filled)).filter { $0 > 0 })
	}

	/// The executable's path, or nil for a process that already exited.
	private static func path(of pid: pid_t) -> String? {
		var buffer: [CChar] = .init(repeating: 0, count: Int(MAXPATHLEN) * 4)
		let length: Int32 = proc_pidpath(pid, &buffer, UInt32(buffer.count))
		guard length > 0
		else { return nil }

		return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
	}
}
