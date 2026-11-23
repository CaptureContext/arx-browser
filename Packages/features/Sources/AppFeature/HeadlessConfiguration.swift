import AppKit
import Foundation
import Synchronization

/// Command-line contract for `Arx --headless`. Parsing has no side effects.
internal struct HeadlessConfiguration: Equatable, Sendable {
	internal enum Grant: String, CaseIterable, Sendable {
		case read
		case screenshots
		case content
		case interaction
		case manage
	}

	internal var profile: URL?
	internal var viewport: NSSize

	/// Nil runs until SIGTERM/SIGINT or until the launcher goes away; see `HeadlessLifetime`.
	internal var timeout: Duration?
	internal var grants: Set<Grant>
	internal var configurationFile: URL?
	internal var initialURL: URL?

	internal static let defaultViewport: NSSize = .init(width: 1280, height: 800)
	internal static let viewportWidths: ClosedRange<Int> = 320 ... 3840
	internal static let viewportHeights: ClosedRange<Int> = 240 ... 2160
	internal static let timeouts: ClosedRange<Int> = 10 ... 86_400

	internal static func isRequested(arguments: [String]) -> Bool {
		arguments.dropFirst().contains("--headless")
	}

	/// Nil when the process was not launched with `--headless`.
	internal static func parse(arguments: [String]) throws(HeadlessFailure) -> Self? {
		var remaining = ArraySlice(arguments.dropFirst())
		guard remaining.contains("--headless") else { return nil }

		var configuration = Self(
			profile: nil,
			viewport: defaultViewport,
			timeout: nil,
			grants: [.read],
			configurationFile: nil,
			initialURL: nil
		)
		var seen: Set<String> = []
		while let option = remaining.popFirst() {
			// LaunchServices and AppKit may append `-psn_…` or `-Key value` arguments.
			if option.hasPrefix("-psn_") { continue }
			if option.hasPrefix("-"), !option.hasPrefix("--") {
				_ = remaining.popFirst()
				continue
			}
			guard seen.insert(option).inserted else { throw .usage("Repeated option \(option)") }
			if option == "--headless" { continue }
			guard let value = remaining.popFirst(), !value.hasPrefix("--")
			else { throw .usage("Missing value for \(option)") }

			switch option {
			case "--profile":
				configuration.profile = try absoluteFile(value, option: option)
			case "--viewport":
				configuration.viewport = try viewport(value)
			case "--timeout":
				guard let seconds = Int(value), timeouts.contains(seconds)
				else { throw .usage("--timeout must be \(timeouts.lowerBound)–\(timeouts.upperBound) seconds") }
				configuration.timeout = .seconds(seconds)
			case "--allow":
				configuration.grants = try grants(value)
			case "--mcp-configuration":
				configuration.configurationFile = try absoluteFile(value, option: option)
			case "--url":
				guard
					let url = URL(string: value),
					url.scheme == "http" || url.scheme == "https" || value == "about:blank"
				else { throw .usage("--url must be an http(s) URL or about:blank") }
				configuration.initialURL = url
			default:
				throw .usage("Unknown option \(option)")
			}
		}
		return configuration
	}

	private static func absoluteFile(
		_ value: String,
		option: String
	) throws(HeadlessFailure) -> URL {
		guard value.hasPrefix("/") else { throw .usage("\(option) must be an absolute path") }
		return URL(fileURLWithPath: value).standardizedFileURL
	}

	private static func viewport(_ value: String) throws(HeadlessFailure) -> NSSize {
		let parts = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
		guard
			parts.count == 2,
			let width = Int(parts[0]), let height = Int(parts[1]),
			viewportWidths.contains(width), viewportHeights.contains(height)
		else {
			throw .usage(
				"--viewport must be WIDTHxHEIGHT within \(viewportWidths.lowerBound)x\(viewportHeights.lowerBound)"
				+ "–\(viewportWidths.upperBound)x\(viewportHeights.upperBound) points"
			)
		}
		return NSSize(width: width, height: height)
	}

	private static func grants(_ value: String) throws(HeadlessFailure) -> Set<Grant> {
		var grants: Set<Grant> = []
		for name in value.split(separator: ",") {
			guard let grant = Grant(rawValue: String(name))
			else { throw .usage("--allow accepts \(Grant.allCases.map(\.rawValue).joined(separator: ","))") }
			grants.insert(grant)
		}

		// Every other grant is meaningless without metadata reads.
		guard grants.contains(.read) else { throw .usage("--allow must include read") }
		return grants
	}
}

/// Machine-readable failure codes with sysexits-style process statuses.
internal enum HeadlessFailure: Error, Equatable, Sendable {
	case usage(String)
	case profileInUse
	case profileUnavailable
	case engineUnavailable
	case automationUnavailable
	case timedOut
	case startupFailed

	/// No logged-in GUI session to host the engine in (DEV-596). Reported as
	/// `startupFailed`, with a message saying what's missing.
	case loginSessionUnavailable

	/// Shutdown did not finish in time and the process is forced to exit.
	case shutdownHung

	private static let loginSessionUnavailableMessage: String =
		"Arx --headless needs a logged-in macOS session for this user, and this process has none"
		+ " (as from a plain SSH login or a launchd daemon); see DEVELOPMENT.md › Headless runs"

	internal var code: String {
		switch self {
		case .usage: "usage"
		case .profileInUse: "profileInUse"
		case .profileUnavailable: "profileUnavailable"
		case .engineUnavailable: "engineUnavailable"
		case .automationUnavailable: "automationUnavailable"
		case .timedOut: "timedOut"
		case .startupFailed, .loginSessionUnavailable: "startupFailed"
		case .shutdownHung: "shutdownHung"
		}
	}

	internal var exitCode: Int32 {
		switch self {
		case .usage: 64

		case .engineUnavailable, .automationUnavailable: 69

		case .startupFailed, .loginSessionUnavailable: 70

		case .profileInUse, .profileUnavailable: 73

		case .timedOut: 75

		// Chromium's own code for a hung process (content::RESULT_CODE_HUNG).
		case .shutdownHung: 2
		}
	}

	internal var message: String {
		switch self {
		case let .usage(message): message
		case .profileInUse: "The profile is in use by another Arx process"
		case .profileUnavailable: "The profile directory cannot be created or locked"
		case .engineUnavailable: "This engine build does not support unattended runs"
		case .automationUnavailable: "The local MCP endpoint could not start"
		case .timedOut: "The run reached its --timeout deadline"
		case .startupFailed: "Arx could not start the browser runtime"
		case .loginSessionUnavailable: Self.loginSessionUnavailableMessage
		case .shutdownHung: "Arx did not finish shutting down in time and was forced to exit"
		}
	}
}

/// Protocol output: one JSON object per line on stdout. Diagnostics use stderr.
internal enum HeadlessOutput {
	private static let writing: Mutex<Void> = .init(())

	internal static func emit(
		_ event: String,
		_ fields: [String: Any] = [:]
	) {
		var object = fields
		object["event"] = event
		guard
			JSONSerialization.isValidJSONObject(object),
			var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
		else { return }
		data.append(0x0A)

		// Watchdogs report from their own threads; one line at a time keeps every line whole.
		// A launcher that exited no longer reads stdout; the run still stops cleanly.
		writing.withLock { _ in try? FileHandle.standardOutput.write(contentsOf: data) }
	}

	internal static func emit(_ failure: HeadlessFailure) {
		emit("error", ["code": failure.code, "message": failure.message, "exitCode": Int(failure.exitCode)])
	}
}
