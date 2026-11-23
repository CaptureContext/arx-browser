@testable import AgentToolsClient
import Foundation
import Testing

@Suite("Running a helper process")
internal struct AgentToolsRunTests {
	private let shell: URL = .init(fileURLWithPath: "/bin/sh")

	@Test("A finished process returns its output")
	internal func finished() async {
		let result: AgentToolsRun.Result? = await AgentToolsRun.run(
			shell,
			arguments: ["-c", "printf hello"],
			timeout: .seconds(5)
		)
		#expect(result == .init(status: 0, output: "hello"))
	}

	@Test("A process that ignores SIGTERM is still stopped at the timeout")
	internal func ignoresTerminate() async {
		let clock: ContinuousClock = .init()
		let start: ContinuousClock.Instant = clock.now
		let result: AgentToolsRun.Result? = await AgentToolsRun.run(
			shell,
			arguments: ["-c", "trap '' TERM; sleep 30 & wait; sleep 30"],
			timeout: .milliseconds(200)
		)
		#expect(result == nil)
		#expect(clock.now - start < .seconds(10))
	}

	@Test("Cancelling the caller stops the process instead of crashing")
	internal func cancelled() async {
		let task: Task<AgentToolsRun.Result?, Never> = .init {
			await AgentToolsRun.run(
				shell,
				arguments: ["-c", "trap '' TERM; sleep 30"],
				timeout: .seconds(30)
			)
		}
		try? await Task.sleep(for: .milliseconds(200))
		let clock: ContinuousClock = .init()
		let start: ContinuousClock.Instant = clock.now
		task.cancel()
		let result: AgentToolsRun.Result? = await task.value
		#expect(result == nil)
		#expect(clock.now - start < .seconds(5))
	}
}
