@testable import DiagnosticsClient
import Foundation
import Testing
import _TestSupport

/// The clean-quit ledger (DEV-1018): a run that didn't quit is found and explained by the next.
internal struct CleanQuitLedgerTests {
	private let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-sessions-\(UUID().uuidString)")
	private let profile: URL = URL(fileURLWithPath: "/tmp/arx-test-profile")

	private var store: CrashReportStore {
		.init(
			locations: .init(
				reports: root.appendingPathComponent("Crash Reports"),
				systemReports: root.appendingPathComponent("DiagnosticReports"),
				engineDatabase: root.appendingPathComponent("Crashpad")
			)
		)
	}

	private func ledger(
		pid: Int32,
		running: Set<Int32> = [],
		bootTime: Date? = nil,
		jetsamReports: [URL] = [],
		systemLog: @escaping @Sendable (SystemExitLog.Query) -> SystemExitLog.Result = { _ in .unavailable }
	) -> CleanQuitLedger {
		.init(
			profile: profile,
			store: store,
			sources: .init(
				jetsamReports: jetsamReports,
				bootTime: { bootTime },
				// Running processes started long before any marker.
				processStart: { running.contains($0) ? .distantPast : nil },
				bundleIdentifier: "dev.capturecontext.arx",
				systemLog: systemLog
			),
			pid: pid
		)
	}

	@Test
	internal func aCleanQuitIsNotAnUncleanExit() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		let first: CleanQuitLedger = ledger(pid: 100)
		#expect(first.start(environment: nil) == nil)
		first.end()

		#expect(ledger(pid: 200).start(environment: nil) == nil)
		#expect(store.uncleanExits.exits().isEmpty)
	}

	@Test
	internal func aRunThatNeverQuitIsRecordedWithItsCounts() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		let killed: CleanQuitLedger = ledger(pid: 100)
		killed.start(environment: .preview)
		killed.note(tabs: 12, spaces: 3)

		// Killed: no `end()`.

		let exit: UncleanExit = try #require(ledger(pid: 200).start(environment: nil))
		#expect(exit.kind == .terminated)
		#expect(exit.pid == 100)
		#expect(exit.tabs == 12 && exit.spaces == 3)
		#expect(exit.appVersion == DiagnosticsEnvironment.preview.appVersion)
		#expect(store.uncleanExits.exits().map(\.id) == [exit.id])

		// Recorded once: the next run's marker replaced it.
		#expect(ledger(pid: 300, running: [200]).start(environment: nil) == nil)
	}

	@Test
	internal func aRunStillGoingIsLeftAlone() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		let running: CleanQuitLedger = ledger(pid: 100)
		running.start(environment: nil)
		let second: CleanQuitLedger = ledger(pid: 200, running: [100])

		#expect(second.start(environment: nil) == nil)
		// The second run quitting doesn't remove the first run's marker.
		second.end()
		#expect(ledger(pid: 300).start(environment: nil)?.pid == 100)
	}

	@Test
	internal func launchesRacingOnOneProfileRecordAStaleMarkerOnce() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		ledger(pid: 100).start(environment: nil, now: Date().addingTimeInterval(-600))
		let ledgers: [CleanQuitLedger] = (200 ..< 208).map { ledger(pid: Int32($0)) }
		DispatchQueue.concurrentPerform(iterations: ledgers.count) { index in
			ledgers[index].start(environment: nil)
		}

		#expect(store.uncleanExits.exits().filter { $0.pid == 100 }.count == 1)
	}

	@Test
	internal func aStaleMarkerWithThisRunsProcessIDIsStillRecorded() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		// The last run had process ID 100 and was killed; after a restart this one got 100 too.
		ledger(pid: 100).start(environment: nil, now: Date().addingTimeInterval(-600))
		let reused: CleanQuitLedger = .init(
			profile: profile,
			store: store,
			sources: .init(jetsamReports: [], bootTime: { nil }, processStart: { _ in Date() }),
			pid: 100
		)

		#expect(reused.start(environment: nil)?.pid == 100)
	}

	@Test
	internal func evidenceFromAnotherProcessDoesNotCount() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		ledger(pid: 100).start(environment: nil, now: Date().addingTimeInterval(-600))
		store.stalls.append(.init(id: "smoke", date: Date().addingTimeInterval(-60), duration: 4, processID: 555))

		#expect(try #require(ledger(pid: 200).start(environment: nil)).kind == .terminated)
	}

	@Test
	internal func evidenceAfterTheRunWasLastSeenOrAfterARestartDoesNotCount() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		// The run was last seen ten minutes ago; the Mac restarted five minutes ago, and a later
		// run that reused process ID 100 stalled a minute ago.
		ledger(pid: 100).start(environment: nil, now: Date().addingTimeInterval(-600))
		store.stalls.append(.init(id: "later", date: Date().addingTimeInterval(-60), duration: 4, processID: 100))

		let exit: UncleanExit = try #require(ledger(pid: 200, bootTime: Date().addingTimeInterval(-300)).start(environment: nil))
		#expect(exit.kind == .systemRestart)
		#expect(exit.stallID == nil)
	}

	@Test
	internal func aJetsamReportWhereArxSurvivedIsNotAKill() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		let reports: URL = root.appendingPathComponent("Jetsam")
		try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
		let started: Date = Date().addingTimeInterval(-600)
		try Self.writeJetsamReport(
			#"[{"pid":100,"name":"Arx"},{"pid":5,"name":"Other","reason":"per-process-limit"}]"#,
			date: started.addingTimeInterval(30),
			to: reports.appendingPathComponent("JetsamEvent-2026-11-16-020000.ips")
		)

		ledger(pid: 100).start(environment: nil, now: started)
		#expect(try #require(ledger(pid: 200, jetsamReports: [reports]).start(environment: nil)).kind == .terminated)
	}

	@Test
	internal func memoryPressureDuringTheRunIsKeptWithItsExit() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		let killed: CleanQuitLedger = ledger(pid: 100)
		killed.start(environment: nil)
		killed.notePressure("warning")
		killed.notePressure("critical")

		let exit: UncleanExit = try #require(ledger(pid: 200).start(environment: nil))
		#expect(exit.memoryPressure == "critical")
		#expect(exit.memoryPressureAt != nil)
		let marker: URL = try #require(
			try FileManager.default.contentsOfDirectory(at: store.locations.sessions, includingPropertiesForKeys: nil)
				.first { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json" }
		)
		let permissions: Int? = try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? Int
		#expect(permissions == 0o600)
	}

	@Test
	internal func anUnendedStallMeansItWasKilledWhileStalled() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		ledger(pid: 100).start(environment: nil, now: Date().addingTimeInterval(-600))

		// Shortly after the run's last heartbeat, as a hang right before a kill would be.
		store.stalls.append(.init(id: "stall", date: Date().addingTimeInterval(-550), duration: 4, processID: 100))

		let exit: UncleanExit = try #require(ledger(pid: 200).start(environment: nil))
		#expect(exit.kind == .killedWhileStalled)
		#expect(exit.stallID == "stall" && exit.stallDuration == 4)
	}

	@Test
	internal func anEndedStallOrOneBeforeTheRunDoesNotCount() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		ledger(pid: 100).start(environment: nil, now: Date().addingTimeInterval(-600))
		store.stalls.append(.init(id: "ended", date: Date().addingTimeInterval(-60), duration: 2, ended: true))
		store.stalls.append(.init(id: "earlier", date: Date().addingTimeInterval(-900), duration: 2))

		#expect(try #require(ledger(pid: 200).start(environment: nil)).kind == .terminated)
	}

	@Test
	internal func aCrashReportInsideTheRunMakesItACrash() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		// The fixture crashed at 1_794_560_462.
		let started: Date = .init(timeIntervalSince1970: 1_794_560_462 - 60)
		ledger(pid: 100).start(environment: nil, now: started)
		try FileManager.default.createDirectory(at: store.locations.systemReports, withIntermediateDirectories: true)
		try CrashReportTests.ipsReport().write(to: store.locations.systemReports.appendingPathComponent("Arx-2026-11-13-100102.ips"))

		let exit: UncleanExit = try #require(ledger(pid: 200).start(environment: nil, now: started.addingTimeInterval(3600)))
		#expect(exit.kind == .crash)
		#expect(exit.crashReportID != nil)
	}

	@Test
	internal func jetsamAndRestartsAreNamed() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		let reports: URL = root.appendingPathComponent("Jetsam")
		try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
		let started: Date = Date().addingTimeInterval(-600)
		try Self.writeJetsamReport(
			Self.killedArx,
			date: started.addingTimeInterval(30),
			to: reports.appendingPathComponent("JetsamEvent-2026-11-16-010000.ips")
		)

		ledger(pid: 100).start(environment: nil, now: started)
		let jetsam: UncleanExit = try #require(ledger(pid: 200, jetsamReports: [reports]).start(environment: nil))
		#expect(jetsam.kind == .jetsam && jetsam.reason == "vm-pageshortage")

		let restarted: UncleanExit = try #require(ledger(pid: 300, bootTime: Date()).start(environment: nil))
		#expect(restarted.kind == .systemRestart)
	}

	@Test
	internal func aJetsamKillOfALaterProcessWithTheRunsIDIsNotTheRunsOwn() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		// The run was last seen ten minutes ago. A later process that reused its ID was killed for
		// memory a minute ago; another one was killed before the run started.
		let reports: URL = root.appendingPathComponent("Jetsam")
		try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
		let started: Date = Date().addingTimeInterval(-600)
		try Self.writeJetsamReport(
			Self.killedArx,
			date: Date().addingTimeInterval(-60),
			to: reports.appendingPathComponent("JetsamEvent-2026-11-16-030000.ips")
		)
		try Self.writeJetsamReport(
			Self.killedArx,
			date: started.addingTimeInterval(-3600),
			to: reports.appendingPathComponent("JetsamEvent-2026-11-16-020000.ips")
		)

		ledger(pid: 100).start(environment: nil, now: started)
		#expect(try #require(ledger(pid: 200, jetsamReports: [reports]).start(environment: nil)).kind == .terminated)
	}

	@Test
	internal func aJetsamKillAfterARestartIsNotTheRunsOwn() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		// The Mac restarted five minutes into the run, and after it a process with the run's ID
		// was killed for memory, still within two heartbeats of the run's last sign of life.
		let reports: URL = root.appendingPathComponent("Jetsam")
		try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
		let started: Date = Date().addingTimeInterval(-600)
		try Self.writeJetsamReport(
			Self.killedArx,
			date: started.addingTimeInterval(60),
			to: reports.appendingPathComponent("JetsamEvent-2026-11-16-010000.ips")
		)

		ledger(pid: 100).start(environment: nil, now: started)
		let exit: UncleanExit = try #require(
			ledger(pid: 200, bootTime: started.addingTimeInterval(30), jetsamReports: [reports]).start(environment: nil)
		)
		#expect(exit.kind == .systemRestart)
	}

	@Test
	internal func aJetsamReportIsDatedByItsBodyElseItsHeader() throws {
		let body: Data = Data(#"{"bug_type":"298","timestamp":"2026-11-16 02:12:11.00 +0100"}"#.utf8)
			+ Data("\n".utf8)
			+ Data(#"{"date":"2026-11-16 02:12:11.06 +0100","processes":[]}"#.utf8)
		let header: Data = Data(#"{"bug_type":"298","timestamp":"2026-11-16 02:12:11.00 +0100"}"#.utf8)
			+ Data("\n".utf8)
			+ Data(#"{"processes":[]}"#.utf8)

		let dated: Date = try #require(CleanQuitLedger.jetsamDate(in: body))
		#expect(abs(dated.timeIntervalSince1970 - 1_794_791_531.06) < 0.001)
		#expect(CleanQuitLedger.jetsamDate(in: header) == Date(timeIntervalSince1970: 1_794_791_531))
		#expect(CleanQuitLedger.jetsamDate(in: Data(#"{"processes":[]}"#.utf8)) == nil)
	}

	@Test
	internal func aKillTheSystemLogNamesIsRecordedAsOne() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		// Killed with `kill -9` a minute after it was last seen. The logs keep whole seconds.
		let lastSeen: Date = .init(timeIntervalSince1970: (Date().timeIntervalSince1970 - 600).rounded(.down))
		ledger(pid: 100).start(environment: nil, now: lastSeen)
		let asked: LockIsolated<[SystemExitLog.Query]> = .init([])
		let next: CleanQuitLedger = ledger(pid: 200) { query in
			asked.withValue { $0.append(query) }
			let date: Date = lastSeen.addingTimeInterval(60)
			guard query.pid == 100, query.from <= date, date <= query.through else { return .unexplained }

			return .evidence(.init(namespace: 2, code: 9, status: 9, date: date))
		}

		let exit: UncleanExit = try #require(next.start(environment: nil))
		#expect(exit.kind == .terminated)

		let killed: UncleanExit = next.refine(exit)
		#expect(killed.kind == .killed && killed.signal == 9 && killed.systemLog == .read)
		#expect(store.uncleanExits.exits() == [killed])
		// Read only for the run's process, from its last sign of life to two heartbeats after it.
		#expect(asked.value.map(\.bundleIdentifier) == ["dev.capturecontext.arx"])
		#expect(asked.value.first?.through == lastSeen.addingTimeInterval(2 * CleanQuitLedger.heartbeatInterval + 1))
	}

	@Test
	internal func anExitWithOtherEvidenceIsNotReadFromTheSystemLog() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		ledger(pid: 100).start(environment: nil, now: Date().addingTimeInterval(-600))
		let restarted: UncleanExit = try #require(ledger(pid: 200, bootTime: Date()).start(environment: nil))
		let read: LockIsolated<Bool> = .init(false)
		let next: CleanQuitLedger = ledger(pid: 300) { _ in
			read.setValue(true)
			return .evidence(.init(namespace: 2, code: 9, status: 9, date: Date()))
		}

		#expect(next.refine(restarted) == restarted)
		#expect(read.value == false)
	}

	@Test
	internal func aSystemLogThatCantBeReadIsNoted() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		ledger(pid: 100).start(environment: nil, now: Date().addingTimeInterval(-600))
		let next: CleanQuitLedger = ledger(pid: 200)
		let exit: UncleanExit = try #require(next.start(environment: nil))

		next.refine(exit)
		let stored: UncleanExit = try #require(store.uncleanExits.exits().first)
		#expect(stored.kind == .terminated && stored.systemLog == .unavailable)
	}

	@Test
	internal func profilesKeepSeparateMarkersNamedWithoutTheirPath() throws {
		defer { try? FileManager.default.removeItem(at: root) }

		let other: CleanQuitLedger = .init(
			profile: URL(fileURLWithPath: "/tmp/another-profile"),
			store: store,
			sources: .init(jetsamReports: [], bootTime: { nil }, processStart: { _ in nil }),
			pid: 100
		)
		other.start(environment: nil)

		#expect(ledger(pid: 200).start(environment: nil) == nil)
		let names: [String] = try FileManager.default.contentsOfDirectory(atPath: store.locations.sessions.path)
		#expect(names.filter { $0.hasPrefix("session-") && $0.hasSuffix(".json") }.count == 2)
		#expect(!names.contains { $0.contains("profile") })
	}

	@Test
	internal func diagnosticsCarryTheLedgerAndRemoveDeletesIt() async throws {
		defer { try? FileManager.default.removeItem(at: root) }

		ledger(pid: 100).start(environment: nil)
		ledger(pid: 200).start(environment: nil)
		let client: DiagnosticsClient = .live(store: store)

		#expect(await client.diagnostics().uncleanExits?.map(\.pid) == [100])
		#expect(await client.status().uncleanExits == 1)
		#expect(await client.removeCrashReports().uncleanExits == 0)
	}

	// MARK: - Jetsam reports

	/// The run's process, killed for memory, beside one that survived.
	private static let killedArx: String = #"[{"pid":100,"name":"Arx","reason":"vm-pageshortage"},{"pid":5,"name":"Other"}]"#

	/// A `JetsamEvent` report as macOS writes it: a header line, then a body with the event's date.
	private static func writeJetsamReport(
		_ processes: String,
		date: Date,
		to file: URL
	) throws {
		let formatter: DateFormatter = .init()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
		let time: String = formatter.string(from: date)
		let report: String = """
		{"bug_type":"298","timestamp":"\(time)"}
		{"date":"\(time)","processes":\(processes)}
		"""
		try Data(report.utf8).write(to: file)
	}
}
