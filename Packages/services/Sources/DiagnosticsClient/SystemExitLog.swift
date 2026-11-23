import Foundation
import OSLog

/// What macOS's unified log says ended a run that left no other trace (DEV-1070).
///
/// RunningBoard logs the exit reason launchd reports for every app it launched:
/// `[app<application.<bundle ID>.….(501)>:<pid>] termination reported by launchd (2, 9, 9)`, the
/// reason's namespace, its code and the process's wait status. A signal (namespace 2) carries
/// the signal number as its code; RunningBoard's own terminations are namespace 15. A Force Quit is
/// logged just before the app ends: by the Dock with the app's LaunchServices ASN, which
/// `launchservicesd` logs beside the process ID as the app quits, or by the Force Quit window
/// (`loginwindow`), with the app's name when the log doesn't redact it. Only a request naming
/// this run's app counts. Only these numbers and whether a force quit came are read; log text
/// never leaves memory, since other lines can hold a page title.
public enum SystemExitLog {
	/// How the system log ended a run.
	public struct Evidence: Codable, Equatable, Sendable {
		/// The exit reason's namespace: 1 jetsam, 2 a signal, 15 RunningBoard, others as macOS
		/// numbers them.
		public var namespace: Int

		/// The reason's code: for a signal, its number.
		public var code: Int

		/// The process's wait status.
		public var status: Int

		/// When RunningBoard logged the exit.
		public var date: Date

		/// A Force Quit, from the Force Quit window or the Dock, came within ``forceQuitLead`` of
		/// the exit.
		public var forceQuit: Bool

		public init(
			namespace: Int,
			code: Int,
			status: Int,
			date: Date,
			forceQuit: Bool = false
		) {
			self.namespace = namespace
			self.code = code
			self.status = status
			self.date = date
			self.forceQuit = forceQuit
		}
	}

	/// What a read found: the evidence, or that the log couldn't be read.
	public enum Result: Equatable, Sendable {
		case evidence(Evidence)

		/// The log was read and says nothing about the run's process.
		case unexplained

		/// The system log can't be opened, as for an account that isn't an administrator.
		case unavailable
	}

	/// A run to look up: its process, its app's bundle ID and name, and when it could have ended.
	public struct Query: Equatable, Sendable {
		public var pid: Int32
		public var bundleIdentifier: String
		public var processName: String
		public var from: Date
		public var through: Date

		public init(
			pid: Int32,
			bundleIdentifier: String,
			processName: String,
			from: Date,
			through: Date
		) {
			self.pid = pid
			self.bundleIdentifier = bundleIdentifier
			self.processName = processName
			self.from = from
			self.through = through
		}
	}

	/// One log line, as read from the store.
	public struct Entry: Equatable, Sendable {
		public var date: Date
		public var process: String
		public var message: String

		public init(
			date: Date,
			process: String,
			message: String
		) {
			self.date = date
			self.process = process
			self.message = message
		}
	}

	/// The namespaces macOS numbers exit reasons with, as far as the ledger tells them apart.
	public enum Namespace {
		public static let exit: Int = 0
		public static let jetsam: Int = 1
		public static let signal: Int = 2
		public static let runningBoard: Int = 15
	}

	/// How long before an exit a Force Quit line can come: the Force Quit window and the Dock log
	/// their request, then LaunchServices ends the app.
	public static let forceQuitLead: TimeInterval = 5

	// MARK: - Reading

	/// Reads the system log for `query`. Takes seconds: never call it on the main thread.
	public static func read(_ query: Query) -> Result {
		guard let store = try? OSLogStore(scope: .system) else { return .unavailable }

		// The store filters by process and the run's process ID before any text reaches Arx.
		let predicate: NSPredicate = .init(
			format: """
			(process == 'runningboardd' AND composedMessage CONTAINS %@) \
			OR (process == 'launchservicesd' AND composedMessage CONTAINS %@) \
			OR (process IN %@ AND (composedMessage CONTAINS[c] 'force quit' OR composedMessage CONTAINS[c] 'forcequit'))
			""",
			":\(query.pid)] termination reported by launchd",
			"QUITTING: pid=\(query.pid) ",
			["loginwindow", "Dock"]
		)
		let start: Date = query.from.addingTimeInterval(-forceQuitLead)
		guard let entries = try? store.getEntries(at: store.position(date: start), matching: predicate)
		else { return .unavailable }

		var lines: [Entry] = []
		for case let entry as OSLogEntryLog in entries {
			guard entry.date <= query.through else { break }

			lines.append(.init(date: entry.date, process: entry.process, message: entry.composedMessage))
		}
		return evidence(in: lines, for: query).map(Result.evidence) ?? .unexplained
	}

	/// The run's exit among `entries`: the last exit RunningBoard logged for the run's process and
	/// app between `from` and `through`, and whether a Force Quit of that app came just before it.
	public static func evidence(
		in entries: [Entry],
		for query: Query
	) -> Evidence? {
		let exit: Evidence? = entries
			.filter { $0.process == "runningboardd" && $0.date >= query.from && $0.date <= query.through }
			.compactMap { entry in
				exitReason(in: entry.message, pid: query.pid, bundleIdentifier: query.bundleIdentifier)
					.map { Evidence(namespace: $0.namespace, code: $0.code, status: $0.status, date: entry.date) }
			}
			.last
		guard var exit else { return nil }

		// A clean exit status needs no Force Quit; any other end a Force Quit of this app requested
		// was one. A request for another app, or one whose app the log redacts, doesn't count.
		let asn: UInt64? = entries
			.filter { $0.process == "launchservicesd" && $0.date <= exit.date.addingTimeInterval(forceQuitLead) }
			.compactMap { quittingASN(in: $0.message, pid: query.pid) }
			.last
		exit.forceQuit = exit.namespace != Namespace.exit && entries.contains { entry in
			entry.date <= exit.date
			&& entry.date >= exit.date.addingTimeInterval(-forceQuitLead)
			&& entry.message.range(of: "force ?quit", options: [.regularExpression, .caseInsensitive]) != nil
			&& names(entry, query: query, asn: asn)
		}
		return exit
	}

	/// Whether a Force Quit line is about the run's app: the Dock's by the app's ASN, the Force Quit
	/// window's by the process ID or the app's name.
	private static func names(
		_ entry: Entry,
		query: Query,
		asn: UInt64?
	) -> Bool {
		switch entry.process {
		case "Dock":
			guard let asn, let dock = dockASN(in: entry.message) else { return false }

			// `launchservicesd` writes the half as `-0x…`, which may be a separator or a sign; the
			// Dock writes it unsigned.
			return dock == asn || dock == (1 << 32) &- asn
		case "loginwindow":
			// A process ID the line gives, as in `_LSForceQuitApplication(Arx [4242])`, decides: another
			// Arx process may be the one force quit. Without one, the app's name does.
			let pids: [Int32] = numbers(in: entry.message, pattern: #"[\[(](\d+)[\])]"#)
			guard pids.isEmpty else { return pids.contains(query.pid) }

			let name: String = NSRegularExpression.escapedPattern(for: query.processName)
			return entry.message.range(of: #"(?<![\w.])"# + name + #"(?![\w.])"#, options: .regularExpression) != nil
		default:
			return false
		}
	}

	/// The low half of the ASN `launchservicesd` logs as `pid` quits: `QUITTING: pid=48006
	/// asn=0x-0x7c4bc44 …`.
	internal static func quittingASN(
		in message: String,
		pid: Int32
	) -> UInt64? {
		hex(in: message, pattern: #"QUITTING: pid="# + "\(pid)" + #" asn=0x[0-9a-f]*-0x([0-9a-f]+)\b"#)
	}

	/// The low half of the ASN in the Dock's `Did force quit asn=(0x0 0x7c4bc44)`.
	internal static func dockASN(in message: String) -> UInt64? {
		hex(in: message, pattern: #"force quit asn=\(0x[0-9a-f]+ 0x([0-9a-f]+)\)"#)
	}

	/// Every number the first group of `pattern` captures in `message`.
	private static func numbers(
		in message: String,
		pattern: String
	) -> [Int32] {
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

		return regex.matches(in: message, range: NSRange(message.startIndex..., in: message)).compactMap { match in
			Range(match.range(at: 1), in: message).flatMap { Int32(message[$0]) }
		}
	}

	private static func hex(
		in message: String,
		pattern: String
	) -> UInt64? {
		guard
			let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
			let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
			let range = Range(match.range(at: 1), in: message)
		else { return nil }

		return UInt64(message[range], radix: 16)
	}

	/// `(namespace, code, status)` from RunningBoard's line about `pid` of the app `bundleIdentifier`.
	internal static func exitReason(
		in message: String,
		pid: Int32,
		bundleIdentifier: String
	) -> (namespace: Int, code: Int, status: Int)? {
		let app: String = NSRegularExpression.escapedPattern(for: "application.\(bundleIdentifier).")
		let pattern: String = #"\[app<"# + app + #"[^>(]*\(\d+\)>:"# + "\(pid)"
			+ #"\] termination reported by launchd \((\d+), (\d+), (\d+)\)"#
		guard
			let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
		else { return nil }

		let numbers: [Int] = (1 ... 3).compactMap { index in
			Range(match.range(at: index), in: message).flatMap { Int(message[$0]) }
		}
		guard numbers.count == 3 else { return nil }

		return (numbers[0], numbers[1], numbers[2])
	}
}
