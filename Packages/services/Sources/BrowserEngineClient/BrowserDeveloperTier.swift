import BrowserCore
import Foundation

/// What an agent's script produced in a tab's developer world (DEV-668).
/// Every string is untrusted page data.
public enum BrowserScriptOutcome: Equatable, Sendable {
	/// JSON text of the awaited return value.
	case value(String)
	case undefined
	case unserializable(String)
	case exception(name: String, message: String)
	case syntaxError(name: String, message: String, line: Int?)
}

public enum BrowserDeveloperFailure: Error, Equatable, Sendable {
	/// No engine developer tier, or a private page.
	case unavailable

	/// Not an ordinary HTTP(S) document.
	case unsupported

	/// The tab navigated or closed.
	case stale
	case limitExceeded

	/// Another script is running in the tab.
	case busy
	case timedOut
	case invalid
	case failed

	/// The final authorization failed.
	case denied
}

extension BrowserEngineClient {
	/// How often a script that finds its page busy asks again, and how long it waits each time.
	/// The engine runs one script per page in the developer world, and Arx reads pages there as
	/// agents' scripts do: reading mode's check for an article once a page loads, history's read
	/// of its text and a hover card's read each hold the page for a moment. About two seconds
	/// covers their two-second limit (DEV-1143, DEV-1164).
	public static let busyRetries: Int = 8
	public static let busyPause: Duration = .milliseconds(250)

	/// Runs `evaluate`, asking again while the page is busy with another script; busy only when it
	/// still is after `busyRetries` more tries, or when the wait between them is cancelled.
	public static func evaluateWhenFree(
		clock: any Clock<Duration>,
		_ evaluate: () async throws(BrowserDeveloperFailure) -> BrowserScriptOutcome
	) async throws(BrowserDeveloperFailure) -> BrowserScriptOutcome {
		var attempt = 0
		while true {
			do {
				return try await evaluate()
			} catch .busy where attempt < busyRetries {
				attempt += 1
				do {
					try await clock.sleep(for: busyPause)
				} catch {
					throw .busy
				}
			}
		}
	}
}

public enum BrowserDeveloperLogKind: Sendable {
	case console
	case network
}

/// One read of a tab's console or network log, kept outside the app's state.
public struct BrowserDeveloperLog: Equatable, Sendable {
	public var capturing: Bool
	public var console: [AutomationConsoleEntry]
	public var network: [AutomationNetworkEntry]
	public var next: UInt64
	public var dropped: UInt64

	public init(
		capturing: Bool,
		console: [AutomationConsoleEntry] = [],
		network: [AutomationNetworkEntry] = [],
		next: UInt64,
		dropped: UInt64
	) {
		self.capturing = capturing
		self.console = console
		self.network = network
		self.next = next
		self.dropped = dropped
	}
}

extension BrowserEngineClient {
	public typealias EvaluateScript = @MainActor @Sendable (
		Tab.ID,
		_ script: String,
		_ maximumBytes: Int,
		_ timeoutMilliseconds: Int,
		@escaping @MainActor @Sendable () -> Bool
	) async throws(BrowserDeveloperFailure) -> BrowserScriptOutcome

	/// ABI57 (DEV-996): one of the app's page translation scripts, in the tab's translation
	/// world; private tabs too.
	public typealias EvaluateTranslationScript = @MainActor @Sendable (
		Tab.ID,
		_ script: String,
		_ maximumBytes: Int,
		_ timeoutMilliseconds: Int
	) async throws(BrowserDeveloperFailure) -> BrowserScriptOutcome

	public typealias ReadDeveloperLog = @MainActor @Sendable (
		Tab.ID,
		BrowserDeveloperLogKind,
		_ after: UInt64,
		_ limit: Int
	) async throws(BrowserDeveloperFailure) -> BrowserDeveloperLog
}
