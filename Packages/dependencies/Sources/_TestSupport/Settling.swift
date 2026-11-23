import Foundation
import Testing

/// Polls `condition` every millisecond until it holds, and fails the test if it doesn't within
/// `limit`. The limit only guards a hang: a busy Mac makes the condition arrive late, never early.
public func pollUntil(
	_ what: @autoclosure () -> String,
	within limit: Duration = .seconds(30),
	isolation: isolated (any Actor)? = #isolation,
	sourceLocation: SourceLocation = #_sourceLocation,
	_ condition: () throws -> Bool
) async throws {
	let deadline: ContinuousClock.Instant = .now.advanced(by: limit)
	while try !condition() {
		try #require(ContinuousClock.now < deadline, "Never happened: \(what())", sourceLocation: sourceLocation)
		try await Task.sleep(for: .milliseconds(1))
	}
}

/// Waits while `condition` holds, for at most `limit`, and leaves the verdict to the caller's
/// assertion. It replaces a fixed number of polls or yields, which a busy Mac used up before the
/// work they waited for had run.
public func waitWhile(
	within limit: Duration = .seconds(30),
	isolation: isolated (any Actor)? = #isolation,
	_ condition: () throws -> Bool
) async rethrows {
	let deadline: ContinuousClock.Instant = .now.advanced(by: limit)
	while try condition(), ContinuousClock.now < deadline {
		await Task.yield()
		try? await Task.sleep(for: .milliseconds(1))
	}
}

extension Task where Success == Never, Failure == Never {
	/// Gives work the test started a chance to run, as `Task.megaYield` does, but at the test's own
	/// priority. `megaYield` hops through `.background` tasks, which wait behind every other job in
	/// the process and run only on efficiency cores, so a busy Mac or a full test run starves them
	/// (DEV-972; the TCA fork's `TestStore` waits the same way).
	public static func settle(count: Int = 20) async {
		let priority: TaskPriority = currentPriority
		for _ in 0..<count {
			await Task<Void, Never>.detached(priority: priority) { await Task<Never, Never>.yield() }.value
		}
	}
}
