@testable import DiagnosticsClient
import Foundation
import Testing

/// Force quits, kills and RunningBoard terminations told apart from the system log (DEV-1070).
/// Lines are shaped as macOS 27 writes them.
internal struct SystemExitLogTests {
	private static let bundleIdentifier: String = "dev.capturecontext.arx"
	private static let exitDate: Date = .init(timeIntervalSince1970: 1_794_800_000)

	private static let query: SystemExitLog.Query = .init(
		pid: 4242,
		bundleIdentifier: bundleIdentifier,
		processName: "Arx",
		from: exitDate.addingTimeInterval(-60),
		through: exitDate.addingTimeInterval(60)
	)

	/// RunningBoard's line about a process of `bundle` ending with `reason`.
	private static func exitLine(
		pid: Int32 = 4242,
		bundle: String = bundleIdentifier,
		reason: String,
		at date: Date = exitDate
	) -> SystemExitLog.Entry {
		.init(
			date: date,
			process: "runningboardd",
			message: "[app<application.\(bundle).1152921500311883050.27498205-CDBE-49CF-8A22-0F599E7953ED(501)>:\(pid)] termination reported by launchd \(reason)"
		)
	}

	@Test
	internal func aSignalIsReadWithItsNumber() throws {
		let evidence: SystemExitLog.Evidence = try #require(
			SystemExitLog.evidence(in: [Self.exitLine(reason: "(2, 9, 9)")], for: Self.query)
		)

		#expect(evidence == .init(namespace: 2, code: 9, status: 9, date: Self.exitDate, forceQuit: false))
	}

	/// `launchservicesd`'s line as the run's app quits, with its ASN.
	private static let quitting: SystemExitLog.Entry = .init(
		date: exitDate.addingTimeInterval(0.01),
		process: "launchservicesd",
		message: "[com.apple.processmanager:front-35286506] QUITTING: pid=4242 asn=0x-0x7c4bc44 foreground=1 wasFront=0"
	)

	@Test
	internal func aForceQuitOfTheRunsAppJustBeforeTheExitIsNamed() throws {
		for line in [
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-1), process: "loginwindow", message: "-[ForceQuit] | Application force quit for Arx succeeded."),
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-2), process: "loginwindow", message: "-[ForceQuit] | _LSForceQuitApplication(Arx [4242]) failed"),
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-0.5), process: "Dock", message: "Did force quit asn=(0x0 0x7c4bc44)"),
			// The same ASN, written unsigned.
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-0.5), process: "Dock", message: "Did force quit asn=(0x0 0xf83b43bc)"),
		] {
			let evidence: SystemExitLog.Evidence = try #require(
				SystemExitLog.evidence(in: [line, Self.exitLine(reason: "(2, 9, 9)"), Self.quitting], for: Self.query)
			)
			#expect(evidence.forceQuit, "\(line.message)")
		}
	}

	@Test
	internal func aForceQuitOfAnotherOrAnUnnamedAppIsNotTheRunsOwn() throws {
		for line in [
			// Another app, by name, process ID or ASN.
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-1), process: "loginwindow", message: "Application force quit for Calculator succeeded."),
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-1), process: "loginwindow", message: "_LSForceQuitApplication(Calculator [42420]) failed"),
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-1), process: "loginwindow", message: "Application force quit for Arxiv Reader succeeded."),
			// Another Arx process.
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-1), process: "loginwindow", message: "_LSForceQuitApplication(Arx [4243]) failed"),
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-0.5), process: "Dock", message: "Did force quit asn=(0x0 0x7c4bc45)"),
			// The log redacted which app.
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-1), process: "loginwindow", message: "Application force quit for <private> succeeded."),
			SystemExitLog.Entry(date: Self.exitDate.addingTimeInterval(-2), process: "loginwindow", message: "forceQuit clicked"),
		] {
			let evidence: SystemExitLog.Evidence = try #require(
				SystemExitLog.evidence(in: [line, Self.exitLine(reason: "(2, 15, 15)"), Self.quitting], for: Self.query)
			)
			#expect(evidence.forceQuit == false, "\(line.message)")
			#expect(evidence.code == 15)
		}

		// The Dock's ASN counts only beside `launchservicesd`'s line for the run's process.
		let dock: SystemExitLog.Entry = .init(date: Self.exitDate.addingTimeInterval(-0.5), process: "Dock", message: "Did force quit asn=(0x0 0x7c4bc44)")
		#expect(try #require(SystemExitLog.evidence(in: [dock, Self.exitLine(reason: "(2, 9, 9)")], for: Self.query)).forceQuit == false)
	}

	@Test
	internal func aForceQuitLongBeforeOrAfterTheExitIsAnotherOne() throws {
		let lines: [SystemExitLog.Entry] = [
			.init(date: Self.exitDate.addingTimeInterval(-30), process: "loginwindow", message: "Application force quit for Arx succeeded."),
			Self.exitLine(reason: "(2, 9, 9)"),
			Self.quitting,
			.init(date: Self.exitDate.addingTimeInterval(1), process: "Dock", message: "Did force quit asn=(0x0 0x7c4bc44)"),
		]

		#expect(try #require(SystemExitLog.evidence(in: lines, for: Self.query)).forceQuit == false)
	}

	@Test
	internal func aCleanExitIsNeverAForceQuit() throws {
		let lines: [SystemExitLog.Entry] = [
			.init(date: Self.exitDate.addingTimeInterval(-1), process: "Dock", message: "Did force quit asn=(0x0 0x7c4bc44)"),
			Self.exitLine(reason: "(0, 0, 0)"),
			Self.quitting,
		]

		#expect(try #require(SystemExitLog.evidence(in: lines, for: Self.query)).forceQuit == false)
	}

	@Test
	internal func onlyTheRunsOwnProcessCounts() {
		let lines: [SystemExitLog.Entry] = [
			// Another process, another app with the run's ID, and the run's process outside its window.
			Self.exitLine(pid: 4243, reason: "(2, 9, 9)"),
			Self.exitLine(bundle: "com.apple.calculator", reason: "(2, 9, 9)"),
			Self.exitLine(reason: "(2, 15, 15)", at: Self.exitDate.addingTimeInterval(600)),
			Self.exitLine(reason: "(2, 15, 15)", at: Self.exitDate.addingTimeInterval(-600)),
			// The same process ID as a prefix of a longer one.
			Self.exitLine(pid: 42_420, reason: "(2, 9, 9)"),
		]

		#expect(SystemExitLog.evidence(in: lines, for: Self.query) == nil)
	}

	@Test
	internal func aBundleIDIsMatchedLiterally() {
		// A dot in the bundle ID matches only a dot.
		let line: SystemExitLog.Entry = Self.exitLine(bundle: "devXcapturecontextXarx", reason: "(2, 9, 9)")

		#expect(SystemExitLog.evidence(in: [line], for: Self.query) == nil)
	}

	// MARK: - Kinds

	@Test
	internal func evidenceNamesTheExit() {
		let exit: UncleanExit = .init(id: "run", kind: .terminated, pid: 4242, started: Self.exitDate, lastSeen: Self.exitDate, detected: Self.exitDate)
		func explained(_ evidence: SystemExitLog.Evidence) -> UncleanExit {
			exit.explained(by: .evidence(evidence))
		}

		let killed: UncleanExit = explained(.init(namespace: 2, code: 9, status: 9, date: Self.exitDate))
		#expect(killed.kind == .killed && killed.signal == 9 && killed.systemLog == .read)

		let forceQuit: UncleanExit = explained(.init(namespace: 2, code: 9, status: 9, date: Self.exitDate, forceQuit: true))
		#expect(forceQuit.kind == .forceQuit && forceQuit.signal == 9)

		#expect(explained(.init(namespace: 15, code: 0, status: 9, date: Self.exitDate)).kind == .watchdog)
		#expect(explained(.init(namespace: 1, code: 9, status: 9, date: Self.exitDate)).kind == .jetsam)

		// An exit status of its own, as from `exit(86)`, stays unexplained with its numbers.
		let exited: UncleanExit = explained(.init(namespace: 0, code: 0, status: 86 << 8, date: Self.exitDate))
		#expect(exited.kind == .terminated && exited.exitReason?.status == 86 << 8)

		let unavailable: UncleanExit = exit.explained(by: .unavailable)
		#expect(unavailable.kind == .terminated && unavailable.systemLog == .unavailable)
		#expect(exit.explained(by: .unexplained).systemLog == .read)

		// Other evidence wins.
		var crash: UncleanExit = exit
		crash.kind = .crash
		#expect(crash.explained(by: .evidence(.init(namespace: 2, code: 9, status: 9, date: Self.exitDate))) == crash)
	}
}
