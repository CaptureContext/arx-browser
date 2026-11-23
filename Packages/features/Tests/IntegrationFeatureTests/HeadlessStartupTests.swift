import CustomDump
import Foundation
import Testing
import _ComposableArchitecture

@testable import AppFeature

/// A run that hasn't reached `ready` says which phase it waits in (`startupSlow`), so a silent
/// first start can be told apart: the engine, the host window or the MCP setup.
@Suite(.dependencies)
internal struct HeadlessStartupTests {
	@Test
	internal func aSlowStartReportsItsPhaseTwice() async throws {
		let reports = LockIsolated<[[String: String]]>([])
		let startup = HeadlessStartup(log: { _ in }) { report in
			let fields = report.mapValues { "\($0)" }
			reports.withValue { $0.append(fields) }
		}
		let checks = Checks()
		startup.enter(.window)
		startup.watch(schedule: checks.schedule)
		expectNoDifference(checks.delays, [HeadlessStartup.slow, HeadlessStartup.slower])

		checks.run(0)
		startup.enter(.automation)
		checks.run(1)

		expectNoDifference(reports.value.map { $0["phase"] }, ["window", "automation"])
		expectNoDifference(reports.value.map { $0["seconds"] }, ["30", "90"])
		expectNoDifference(Set(reports.value.map { $0["code"] }), ["startupSlow"])
	}

	@Test
	internal func aReadyOrStoppingRunReportsNothing() async throws {
		for last in [HeadlessStartup.Phase.ready, .stopping] {
			let reports = LockIsolated(0)
			let startup = HeadlessStartup(log: { _ in }) { _ in reports.withValue { $0 += 1 } }
			let checks = Checks()
			startup.enter(last)
			startup.watch(schedule: checks.schedule)
			checks.run(0)
			checks.run(1)
			#expect(reports.value == 0)
		}
	}

	@Test
	internal func phasesOnlyMoveForward() async throws {
		let lines = LockIsolated<[String]>([])
		let startup = HeadlessStartup(log: { line in lines.withValue { $0.append(line) } }) { _ in }
		startup.enter(.automation)
		startup.enter(.window)
		startup.enter(.automation)
		startup.enter(.ready)
		expectNoDifference(startup.current, .ready)
		expectNoDifference(lines.value.map { $0.split(separator: " ").dropLast().joined(separator: " ") }, [
			"ARX_HEADLESS_PHASE automation",
			"ARX_HEADLESS_PHASE ready",
		])
	}
}

/// The startup checks `watch` scheduled, run when the test says time has passed.
private final class Checks: @unchecked Sendable {
	private(set) var delays: [Duration] = []
	private var work: [@Sendable () -> Void] = []

	internal func schedule(
		_ delay: Duration,
		_ check: @escaping @Sendable () -> Void
	) {
		delays.append(delay)
		work.append(check)
	}

	internal func run(_ index: Int) { work[index]() }
}
