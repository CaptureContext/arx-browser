import Darwin
import Foundation
import Synchronization

/// A run that ended without Arx quitting (DEV-1018): a crash, a kill while the main thread was
/// stalled, a jetsam kill, a restart of the Mac, a Force Quit, a signal, a termination by macOS,
/// or an end that left no trace. It holds counts and identifiers only: never a URL, a title or a
/// path.
public struct UncleanExit: Codable, Equatable, Identifiable, Sendable {
	public enum Kind: String, Codable, Sendable {
		/// A crash report of Arx's own process falls inside the run.
		case crash

		/// The run's last stall never ended: the app was most likely killed while it hung.
		case killedWhileStalled

		/// macOS killed it to free memory; `reason` is jetsam's.
		case jetsam

		/// The Mac restarted or lost power during the run.
		case systemRestart

		/// Someone force quit it, from the Force Quit window or the Dock (DEV-1070).
		case forceQuit

		/// A signal ended it, such as `kill -9`; `signal` is its number (DEV-1070).
		case killed

		/// macOS ended it through RunningBoard, as its watchdog does an app that stops answering
		/// (DEV-1070).
		case watchdog

		/// Nothing else explains it: no report, and nothing in the system log, or no system log.
		case terminated
	}

	/// Whether the next launch could read the system log for the run (DEV-1070).
	public enum SystemLog: String, Codable, Sendable {
		case read

		/// Not readable, as for an account that isn't an administrator.
		case unavailable
	}

	/// The run's own ID.
	public var id: String
	public var kind: Kind

	/// Jetsam's reason, such as `vm-pageshortage`.
	public var reason: String?

	/// The signal that ended a run that was ``Kind/killed`` or force quit.
	public var signal: Int?

	/// The exit reason the system log gave, in numbers, and whether it could be read.
	public var exitReason: SystemExitLog.Evidence?
	public var systemLog: SystemLog?

	public var pid: Int32
	public var started: Date

	/// When the run was last known to be alive.
	public var lastSeen: Date

	/// When the next launch found it.
	public var detected: Date

	public var appVersion: String?
	public var appBuild: String?

	/// How many tabs and spaces the workspace held when last saved.
	public var tabs: Int?
	public var spaces: Int?

	/// The matching ``CrashReport``'s ID.
	public var crashReportID: String?

	/// The unended stall, from the stall log (DEV-1010).
	public var stallID: String?
	public var stallDuration: TimeInterval?

	/// The Mac's last memory-pressure level during the run, `warning` or `critical`, and when it
	/// came: evidence for a memory kill that left no jetsam report, not its proof.
	public var memoryPressure: String?
	public var memoryPressureAt: Date?

	public init(
		id: String,
		kind: Kind,
		reason: String? = nil,
		signal: Int? = nil,
		exitReason: SystemExitLog.Evidence? = nil,
		systemLog: SystemLog? = nil,
		pid: Int32,
		started: Date,
		lastSeen: Date,
		detected: Date,
		appVersion: String? = nil,
		appBuild: String? = nil,
		tabs: Int? = nil,
		spaces: Int? = nil,
		crashReportID: String? = nil,
		stallID: String? = nil,
		stallDuration: TimeInterval? = nil,
		memoryPressure: String? = nil,
		memoryPressureAt: Date? = nil
	) {
		self.id = id
		self.kind = kind
		self.reason = reason
		self.signal = signal
		self.exitReason = exitReason
		self.systemLog = systemLog
		self.pid = pid
		self.started = started
		self.lastSeen = lastSeen
		self.detected = detected
		self.appVersion = appVersion
		self.appBuild = appBuild
		self.tabs = tabs
		self.spaces = spaces
		self.crashReportID = crashReportID
		self.stallID = stallID
		self.stallDuration = stallDuration
		self.memoryPressure = memoryPressure
		self.memoryPressureAt = memoryPressureAt
	}
}

extension UncleanExit {
	/// This exit, explained by what the system log says, if it had no other explanation: a Force
	/// Quit, a signal or RunningBoard ending it, or jetsam without a report (DEV-1070).
	public func explained(by result: SystemExitLog.Result) -> UncleanExit {
		guard kind == .terminated else { return self }

		var exit: UncleanExit = self
		switch result {
		case .unavailable:
			exit.systemLog = .unavailable
		case .unexplained:
			exit.systemLog = .read
		case let .evidence(evidence):
			exit.systemLog = .read
			exit.exitReason = evidence
			let signal: Int? = evidence.namespace == SystemExitLog.Namespace.signal ? evidence.code : nil
			if evidence.forceQuit {
				exit.kind = .forceQuit
				exit.signal = signal
			} else if let signal {
				exit.kind = .killed
				exit.signal = signal
			} else if evidence.namespace == SystemExitLog.Namespace.runningBoard {
				exit.kind = .watchdog
			} else if evidence.namespace == SystemExitLog.Namespace.jetsam {
				exit.kind = .jetsam
			}
		}
		return exit
	}
}

/// The clean-quit ledger (DEV-1018).
///
/// A run writes a marker, `…/Diagnostics/Sessions/session-<profile>.json`, as it starts and
/// removes it when Arx quits. A marker the next launch finds belongs to a run that didn't quit: the
/// launch explains it from the crash reports, the stall log, jetsam reports and the Mac's boot
/// time, and appends it to `unclean-exits.jsonl`. Each profile folder has its own marker, so runs
/// on different profiles never mistake each other's markers, and a marker whose process is still
/// running is left alone.
public final class CleanQuitLedger: @unchecked Sendable {
	public struct Marker: Codable, Equatable, Sendable {
		public var id: String
		public var pid: Int32
		public var started: Date
		public var lastSeen: Date
		public var appVersion: String?
		public var appBuild: String?
		public var tabs: Int?
		public var spaces: Int?

		/// The last memory-pressure level above normal, and when it came.
		public var memoryPressure: String?
		public var memoryPressureAt: Date?

		public init(
			id: String,
			pid: Int32,
			started: Date,
			lastSeen: Date,
			appVersion: String? = nil,
			appBuild: String? = nil,
			tabs: Int? = nil,
			spaces: Int? = nil,
			memoryPressure: String? = nil,
			memoryPressureAt: Date? = nil
		) {
			self.id = id
			self.pid = pid
			self.started = started
			self.lastSeen = lastSeen
			self.appVersion = appVersion
			self.appBuild = appBuild
			self.tabs = tabs
			self.spaces = spaces
			self.memoryPressure = memoryPressure
			self.memoryPressureAt = memoryPressureAt
		}
	}

	/// Where it reads what explains an exit, besides the stall log and crash reports.
	public struct Sources: Sendable {
		/// Folders holding `JetsamEvent*.ips` reports.
		public var jetsamReports: [URL]

		/// When the Mac last booted.
		public var bootTime: @Sendable () -> Date?

		/// When `pid` started, if it's a running process with this executable's name.
		public var processStart: @Sendable (Int32) -> Date?

		/// The app's bundle ID, which RunningBoard names its processes by.
		public var bundleIdentifier: String?

		/// What the system log says ended a run. Takes seconds.
		public var systemLog: @Sendable (SystemExitLog.Query) -> SystemExitLog.Result

		public init(
			jetsamReports: [URL],
			bootTime: @escaping @Sendable () -> Date?,
			processStart: @escaping @Sendable (Int32) -> Date?,
			bundleIdentifier: String? = nil,
			systemLog: @escaping @Sendable (SystemExitLog.Query) -> SystemExitLog.Result = { _ in .unavailable }
		) {
			self.jetsamReports = jetsamReports
			self.bootTime = bootTime
			self.processStart = processStart
			self.bundleIdentifier = bundleIdentifier
			self.systemLog = systemLog
		}

		public static var live: Self {
			.init(
				jetsamReports: [
					URL.libraryDirectory.appendingPathComponent("Logs/DiagnosticReports"),
					URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
				],
				bootTime: { CleanQuitLedger.bootTime() },
				processStart: { CleanQuitLedger.arxProcessStart($0) },
				bundleIdentifier: Bundle.main.bundleIdentifier,
				systemLog: { SystemExitLog.read($0) }
			)
		}
	}

	public static let retention: TimeInterval = 30 * 24 * 3600
	public static let limit: Int = 100

	/// How often a run says it's still alive, which bounds when an unclean exit happened.
	public static let heartbeatInterval: TimeInterval = 60

	/// The ledger of a run started with ``begin(profile:store:environment:)``, for the workspace to
	/// report its counts to.
	public static var current: CleanQuitLedger? {
		_current.withLock { $0 }
	}

	private static let _current: Mutex<CleanQuitLedger?> = .init(nil)

	public let folder: URL
	public let store: CrashReportStore
	private let marker: URL
	private let sources: Sources
	private let pid: Int32
	private let session: Mutex<Marker?> = .init(nil)
	private var heartbeat: DispatchSourceTimer?
	private var memoryPressureSource: DispatchSourceMemoryPressure?

	public init(
		profile: URL,
		store: CrashReportStore,
		sources: Sources = .live,
		pid: Int32 = getpid()
	) {
		self.store = store
		self.folder = store.locations.sessions
		self.marker = folder.appendingPathComponent("session-\(Self.profileKey(profile)).json")
		self.sources = sources
		self.pid = pid
	}

	/// Records the previous run's unclean exit, if there was one, then marks this run as running and
	/// makes it ``current``. Returns the exit it recorded.
	@discardableResult
	public static func begin(
		profile: URL,
		store: CrashReportStore = .init(locations: .standard),
		environment: DiagnosticsEnvironment = .current()
	) -> (ledger: CleanQuitLedger, uncleanExit: UncleanExit?) {
		let ledger: CleanQuitLedger = .init(profile: profile, store: store)
		let exit: UncleanExit? = ledger.start(environment: environment)
		ledger.log.prune()
		ledger.startHeartbeat()
		_current.withLock { $0 = ledger }

		// Reading the system log takes seconds, more on a busy Mac, so the exit is recorded first and
		// explained after, at the lowest priority.
		if let exit, exit.kind == .terminated {
			DispatchQueue.global(qos: .background).async {
				ledger.refine(exit)
			}
		}
		return (ledger, exit)
	}

	/// Checks the previous marker and writes this run's. Returns the unclean exit it recorded.
	@discardableResult
	public func start(
		environment: DiagnosticsEnvironment?,
		now: Date = Date()
	) -> UncleanExit? {
		// Another Arx process starting on this profile waits here, so a stale marker is recorded
		// once and a live run's marker is never replaced.
		JSONLines.withLock(marker) {
			var recorded: UncleanExit?
			if let previous = readMarker() {
				// The marker's run is the process with its ID only if that process started before the
				// marker was written; a later one reused the ID. Markers keep whole seconds.
				let started: Date? = sources.processStart(previous.pid)
				let alive: Bool = started.map { $0 <= previous.started.addingTimeInterval(1) } ?? false
				if alive {
					// This run's own marker needs nothing; another live run's isn't stale.
					guard previous.pid == pid else { return nil }
				} else {
					let exit: UncleanExit = explain(previous, detected: now)
					log.append(exit)
					recorded = exit
				}
			}
			let marker: Marker = .init(
				id: UUID().uuidString,
				pid: pid,
				started: now,
				lastSeen: now,
				appVersion: environment?.appVersion,
				appBuild: environment?.appBuild
			)
			session.withLock { session in
				session = marker
				write(marker)
			}
			return recorded
		}
	}

	/// Updates the marker's counts (only when they change) and its last-seen time.
	public func note(
		tabs: Int,
		spaces: Int
	) {
		// The file is written under the same lock `end()` removes it under, so a quit is never
		// followed by a stale write that brings the marker back.
		JSONLines.withLock(marker) {
			session.withLock { marker in
				guard var current = marker, current.tabs != tabs || current.spaces != spaces else { return }

				current.tabs = tabs
				current.spaces = spaces
				current.lastSeen = Date()
				marker = current
				write(current)
			}
		}
	}

	/// A clean quit: removes this run's marker, and only this run's.
	public func end() {
		heartbeat?.cancel()
		heartbeat = nil
		memoryPressureSource?.cancel()
		memoryPressureSource = nil
		JSONLines.withLock(marker) {
			session.withLock { session in
				defer { session = nil }
				guard let mine = session, readMarker()?.id == mine.id else { return }

				try? FileManager.default.removeItem(at: marker)
			}
		}
	}

	/// The unclean exits kept, newest first.
	public var exits: [UncleanExit] {
		log.exits()
	}

	public var log: UncleanExitLog {
		store.uncleanExits
	}

	// MARK: - Explaining

	/// Why `previous` didn't quit: its crash report, else its unended stall, else jetsam's report,
	/// else a restart of the Mac, else an unexplained termination.
	internal func explain(
		_ previous: Marker,
		detected: Date
	) -> UncleanExit {
		var exit: UncleanExit = .init(
			id: previous.id,
			kind: .terminated,
			pid: previous.pid,
			started: previous.started,
			lastSeen: previous.lastSeen,
			detected: detected,
			appVersion: previous.appVersion,
			appBuild: previous.appBuild,
			tabs: previous.tabs,
			spaces: previous.spaces,
			memoryPressure: previous.memoryPressure,
			memoryPressureAt: previous.memoryPressureAt
		)
		store.collect()
		let boot: Date? = sources.bootTime()
		let latest: Date = latestEnd(started: previous.started, lastSeen: previous.lastSeen, detected: detected, boot: boot)
		let crash: CrashReport? = store.entries()
			.map(\.report)
			.filter { report in
				report.source == .system
				&& report.process == "Arx"
				&& (report.processID.map { $0 == previous.pid } ?? true)
				&& report.date >= previous.started.addingTimeInterval(-1)
				&& report.date <= latest
			}
			.max { $0.date < $1.date }

		// Evidence from another Arx run, such as a smoke on another profile, never counts.
		let stall: StallRecord? = store.stalls.records()
			.first { stall in
				!stall.ended
				&& (stall.processID.map { $0 == previous.pid } ?? true)
				&& stall.date >= previous.started.addingTimeInterval(-1)
				&& stall.date <= latest
			}
		if let stall {
			exit.stallID = stall.id
			exit.stallDuration = stall.duration
		}
		if let crash {
			exit.kind = .crash
			exit.crashReportID = crash.id
		} else if stall != nil {
			exit.kind = .killedWhileStalled
		} else if let reason = jetsamReason(pid: previous.pid, from: previous.started, through: latest) {
			exit.kind = .jetsam
			exit.reason = reason
		} else if let boot, boot > previous.started {
			exit.kind = .systemRestart
		}
		return exit
	}

	/// When a run could have ended at the latest: within two heartbeats of when it was last seen,
	/// and before any later boot. Evidence after that belongs to another process, perhaps one that
	/// reused its ID.
	private func latestEnd(
		started: Date,
		lastSeen: Date,
		detected: Date,
		boot: Date?
	) -> Date {
		var latest: Date = min(detected, lastSeen.addingTimeInterval(2 * Self.heartbeatInterval + 1))
		if let boot, boot > started { latest = min(latest, boot) }
		return latest
	}

	/// Explains a ``UncleanExit/Kind/terminated`` exit from the system log and updates it in the
	/// log of unclean exits (DEV-1070). Returns the updated exit.
	@discardableResult
	internal func refine(_ exit: UncleanExit) -> UncleanExit {
		guard exit.kind == .terminated, let bundleIdentifier = sources.bundleIdentifier else { return exit }

		// RunningBoard logs the exit after the process is gone, so after its last sign of life.
		let query: SystemExitLog.Query = .init(
			pid: exit.pid,
			bundleIdentifier: bundleIdentifier,
			processName: ProcessInfo.processInfo.processName,
			from: exit.lastSeen.addingTimeInterval(-1),
			through: latestEnd(started: exit.started, lastSeen: exit.lastSeen, detected: exit.detected, boot: sources.bootTime())
		)
		let result: SystemExitLog.Result = sources.systemLog(query)
		var refined: UncleanExit = exit
		log.update(exit.id) { stored in
			stored = stored.explained(by: result)
			refined = stored
		}
		return refined
	}

	/// Jetsam's reason for killing `pid`, from a `JetsamEvent` report of an event between `start`
	/// and `end`. A report from before or after the run names another process that had its ID,
	/// perhaps after a restart of the Mac (DEV-1079).
	private func jetsamReason(
		pid: Int32,
		from start: Date,
		through end: Date
	) -> String? {
		let earliest: Date = start.addingTimeInterval(-1)
		for folder in sources.jetsamReports {
			let files: [URL] = (try? FileManager.default.contentsOfDirectory(
				at: folder,
				includingPropertiesForKeys: [.contentModificationDateKey]
			)) ?? []
			for file in files where file.lastPathComponent.hasPrefix("JetsamEvent") && file.pathExtension == "ips" {
				// A report is written once its event is over, so one modified before the run is older.
				let modified: Date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
				guard modified >= earliest, let data = try? Data(contentsOf: file) else { continue }

				let date: Date = Self.jetsamDate(in: data) ?? modified
				guard date >= earliest, date <= end else { continue }

				if let reason = Self.jetsamReason(in: data, pid: pid) { return reason }
			}
		}
		return nil
	}

	/// When the jetsam event happened: the body's `date`, else the header's `timestamp`.
	internal static func jetsamDate(in data: Data) -> Date? {
		let parts: [Data] = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).map { Data($0) }
		let object: (Data?) -> [String: Any]? = { part in
			part.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
		}
		let body: [String: Any]? = parts.count > 1 ? object(parts.last) : nil
		return SystemCrashReport.date(body?["date"] as? String)
			?? SystemCrashReport.date(object(parts.first)?["timestamp"] as? String)
	}

	/// An `.ips` jetsam report is a JSON header line, then a JSON body listing processes.
	internal static func jetsamReason(
		in data: Data,
		pid: Int32
	) -> String? {
		let parts: [Data] = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).map { Data($0) }
		guard
			let body = parts.last,
			let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
			let processes = json["processes"] as? [[String: Any]]
		else { return nil }

		let process: [String: Any]? = processes.first { process in
			(process["pid"] as? NSNumber)?.int32Value == pid && (process["name"] as? String) == "Arx"
		}
		guard let process else { return nil }

		// A report lists survivors too; only a process with a kill reason was the victim. Only
		// jetsam's own short code is kept: `vm-pageshortage`, `per-process-limit` and so on.
		guard let reason = process["reason"] as? String, !reason.isEmpty else { return nil }
		guard reason.count <= 64, reason.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
		else { return "jetsam" }

		return reason
	}

	// MARK: - Marker

	private func readMarker() -> Marker? {
		(try? Data(contentsOf: marker)).flatMap { try? CrashReportStore.decoder.decode(Marker.self, from: $0) }
	}

	private func write(_ value: Marker) {
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		guard let data = try? CrashReportStore.encoder.encode(value) else { return }

		try? data.write(to: marker, options: .atomic)
		JSONLines.ownerOnly(marker)
	}

	/// Notes the Mac's memory pressure in the marker when it rises above normal.
	internal func notePressure(
		_ level: String,
		at date: Date = Date()
	) {
		JSONLines.withLock(marker) {
			session.withLock { marker in
				guard var current = marker, current.memoryPressure != level || level == "critical" else { return }

				current.memoryPressure = level
				current.memoryPressureAt = date
				marker = current
				write(current)
			}
		}
	}

	private func startHeartbeat() {
		let timer: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
		timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
		timer.setEventHandler { [weak self] in
			guard let self else { return }

			JSONLines.withLock(marker) {
				session.withLock { marker in
					guard var current = marker else { return }

					current.lastSeen = Date()
					marker = current
					write(current)
				}
			}
		}
		timer.resume()
		heartbeat = timer

		let pressure: DispatchSourceMemoryPressure = DispatchSource.makeMemoryPressureSource(
			eventMask: [.warning, .critical],
			queue: .global(qos: .utility)
		)
		pressure.setEventHandler { [weak self, weak pressure] in
			guard let self, let event = pressure?.data else { return }

			notePressure(event.contains(.critical) ? "critical" : "warning")
		}
		pressure.resume()
		memoryPressureSource = pressure
	}

	// MARK: - System

	/// A short, stable name for a profile folder, so its marker file never shows the path.
	internal static func profileKey(_ profile: URL) -> String {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in profile.standardizedFileURL.path.utf8 {
			hash ^= UInt64(byte)
			hash &*= 0x0000_0100_0000_01b3
		}
		return String(hash, radix: 16)
	}

	internal static func bootTime() -> Date? {
		var time: timeval = .init()
		var size: Int = MemoryLayout<timeval>.size
		guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }

		return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
	}

	/// When `pid` started, if it's running with this process's name.
	internal static func arxProcessStart(_ pid: Int32) -> Date? {
		guard pid > 0 else { return nil }

		var info: kinfo_proc = .init()
		var size: Int = MemoryLayout<kinfo_proc>.stride
		var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
		guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }

		// The kernel keeps the first `MAXCOMLEN` bytes of the name.
		let command: String = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
			String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
		}
		guard command == String(ProcessInfo.processInfo.processName.utf8.prefix(Int(MAXCOMLEN)))! else { return nil }

		let start: timeval = info.kp_proc.p_un.__p_starttime
		return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
	}
}

/// The unclean exits, `…/Diagnostics/Sessions/unclean-exits.jsonl`.
public struct UncleanExitLog: Sendable {
	public var file: URL
	public var now: @Sendable () -> Date

	public init(
		file: URL,
		now: @escaping @Sendable () -> Date = Date.init
	) {
		self.file = file
		self.now = now
	}

	public init(folder: URL) {
		self.init(file: folder.appendingPathComponent("unclean-exits.jsonl"))
	}

	/// Newest first, within the retention and the limit.
	public func exits() -> [UncleanExit] {
		Array(
			JSONLines.read(UncleanExit.self, from: file)
				.filter { $0.detected >= now().addingTimeInterval(-CleanQuitLedger.retention) }
				.sorted { $0.detected > $1.detected }
				.prefix(CleanQuitLedger.limit)
		)
	}

	public func exits(since date: Date) -> [UncleanExit] {
		exits().filter { $0.detected >= date }
	}

	public func append(_ exit: UncleanExit) {
		JSONLines.withLock(file) {
			JSONLines.append(exit, to: file)
			prune()
		}
	}

	/// Changes the exit with `id`, if it's still kept.
	public func update(
		_ id: String,
		_ change: (inout UncleanExit) -> Void
	) {
		JSONLines.withLock(file) {
			var all: [UncleanExit] = JSONLines.read(UncleanExit.self, from: file)
			guard let index = all.firstIndex(where: { $0.id == id }) else { return }

			change(&all[index])
			JSONLines.compact(file: file, force: true, threshold: 0, values: all)
		}
	}

	/// Rewrites the ledger without exits past the retention or the limit, as ``StallLog/prune()``.
	public func prune() {
		JSONLines.withLock(file) {
			let all: [UncleanExit] = JSONLines.read(UncleanExit.self, from: file)
			let oldest: Date = now().addingTimeInterval(-CleanQuitLedger.retention)
			let stale: Bool = all.count > CleanQuitLedger.limit || all.contains { $0.detected < oldest }
			JSONLines.compact(file: file, force: stale, threshold: StallLog.compactionSize, values: exits().reversed())
		}
	}

	public func removeAll() {
		JSONLines.withLock(file) {
			try? FileManager.default.removeItem(at: file)
		}
	}
}
