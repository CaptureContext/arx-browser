import ChromiumEngine
import Darwin
import Foundation

/// Uses only a compiled extension page and its disposable native-host manifests.
@MainActor
internal enum NativeMessagingSmoke {
	internal static func run(
		page: ChromiumPage,
		extensionID: String
	) async throws {
		guard let url = URL(string: "chrome-extension://\(extensionID)/native.html")
		else { throw Failure.response }

		try page.navigate(to: url)
		let prefix = "ARX_EXTENSION_NATIVE:\(extensionID):once="
		try await wait { !page.navigation.isLoading && page.navigation.title.hasPrefix(prefix) }

		let value = page.navigation.title.dropFirst(prefix.count)
		let parts = value.components(separatedBy: ":")
		guard
			parts.count == 3,
			let once = pid_t(parts[0]),
			parts[1].hasPrefix("port="),
			let port = pid_t(parts[1].dropFirst("port=".count)),
			parts[2] == "forbidden=true",
			once > 0,
			port > 0,
			once != port,
			once != getpid(),
			port != getpid(),
			page.navigation.url == url,
			exists(port)
		else { throw Failure.response }

		// The zero signal reads process existence. It never terminates a process.
		try await wait { !exists(once) }
		page.close()
		try await wait { !exists(port) }
	}

	private static func exists(_ pid: pid_t) -> Bool {
		kill(pid, 0) == 0 || errno != ESRCH
	}

	private static func wait(_ ready: () -> Bool) async throws {
		for _ in 0..<300 {
			try Task.checkCancellation()

			if ready() { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.timeout
	}

	private enum Failure: Error {
		case response
		case timeout
	}
}
