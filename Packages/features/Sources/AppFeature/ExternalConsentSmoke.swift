#if DEBUG
import AppKit
import Foundation

/// Signed disposable process only. Native initialization separately validates the
/// same root/token and intercepts every final OS launch for the process lifetime.
@MainActor
internal enum ExternalConsentSmoke {
	internal static var requested: Bool {
		ExternalConsentFixture.isRequested(
			environment: ProcessInfo.processInfo.environment,
			arguments: CommandLine.arguments
		)
	}

	internal static func run(
		view: NSView,
		window: NSWindow,
		baseURL: URL,
		navigate: @MainActor (URL) throws -> Void,
		isLoaded: @MainActor (String) -> Bool,
		tabsUnchanged: @MainActor () -> Bool
	) async throws {
		guard
			let path = ProcessInfo.processInfo.environment["ARX_EXTERNAL_CONSENT_FIXTURE_ROOT"],
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			(1...65_535).contains(parts.port ?? 0),
			parts.path == "/index.html",
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil
		else { throw Failure.invalidFixture }

		let root = URL(fileURLWithPath: path)
		guard
			root.standardizedFileURL.resolvingSymlinksInPath() == root,
			root.lastPathComponent.hasPrefix("app-smoke-"),
			ProcessInfo.processInfo.environment["ARX_ENGINE_PROFILE"]
				== root.appending(path: "profile").path
		else { throw Failure.invalidFixture }

		let receipt = root.appending(path: "external-consent.receipt")
		for phase in ["cancel", "accept", "stale", "noopener", "unregistered"] {
			var source = parts
			source.host = "arx-external-\(UUID().uuidString.lowercased()).localhost"
			source.path = "/external-consent/\(phase).html"
			guard let url = source.url else { throw Failure.invalidFixture }

			try navigate(url)
			try await wait { isLoaded("Arx External \(phase)") }
			window.makeKeyAndOrderFront(nil)
			try PageConsentSmoke.clickRequest(view: view, window: window)
			do {
				try await wait {
					let records = try records(at: receipt)
					return (phase == "unregistered" || records.contains("dialog:\(phase):visible"))
						&& records.contains("child:\(phase):drained")
				}
			} catch Failure.timedOut {
				// Receipt lines are fixed fixture categories, never page or OS values.
				let recorded = (try? records(at: receipt)) ?? []
				FileHandle.standardError.write(Data("ARX_EXTERNAL_CONSENT_TIMEOUT phase=\(phase) records=\(recorded.suffix(8))\n".utf8))
				throw Failure.timedOut
			}
			guard tabsUnchanged() else { throw Failure.publishedExternalTab }

			if phase == "stale" {
				try await wait { isLoaded("Arx External destination") }
			}
		}

		let records = try records(at: receipt)
		guard records.filter({ $0 == "os-attempt:accept:intercepted" }).count == 1 else {
			throw Failure.unexpectedLaunch
		}

		print("ARX_EXTERNAL_CONSENT_MAIN_SUCCESS")
	}

	private static func records(at receipt: URL) throws -> [String] {
		let text = try String(contentsOf: receipt, encoding: .utf8)
		let records = text.split(separator: "\n").map(String.init)
		guard records.allSatisfy({ !$0.hasPrefix("FAIL:") }) else {
			throw Failure.unexpectedLaunch
		}

		return records
	}

	private static func wait(
		_ predicate: @MainActor () throws -> Bool
	) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(12))
		while try !predicate() {
			guard clock.now < deadline else { throw Failure.timedOut }
			try await Task.sleep(for: .milliseconds(20))
		}
	}

	private enum Failure: Error {
		case invalidFixture
		case publishedExternalTab
		case unexpectedLaunch
		case timedOut
	}
}
#endif
