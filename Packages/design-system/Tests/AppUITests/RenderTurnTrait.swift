import Foundation
import Testing

extension Trait where Self == RenderTurnTrait {
	/// Runs the suite's tests one at a time with every other suite that lays out AppUI views,
	/// since `RenderTrace` and `SidebarRenderTrace` each keep one count for the whole process.
	/// Hosting tests spin the main run loop to let SwiftUI settle, which runs any other main-actor
	/// test that is waiting; one that renders a counted view in the meantime would land in the
	/// counts of the test that records (DEV-1080). Every suite that hosts views takes this trait,
	/// so a recording test is the only one rendering until it returns.
	internal static var renderTurn: Self { .init() }
}

internal struct RenderTurnTrait: SuiteTrait, TestTrait, TestScoping {
	internal var isRecursive: Bool { true }

	internal func provideScope(
		for test: Test,
		testCase: Test.Case?,
		performing function: @Sendable () async throws -> Void
	) async throws {
		// The suite itself only gathers its tests; each test case takes its turn.
		guard testCase != nil else { return try await function() }
		SynchronousComparisons.enable()
		await RenderTurns.shared.acquire()
		do {
			try await function()
		} catch {
			await RenderTurns.shared.release()
			throw error
		}
		await RenderTurns.shared.release()
	}
}

/// SwiftUI's AttributeGraph works out how to compare each view type on a background queue, and
/// until it has, a view whose parent renders counts as changed and renders too. How many views
/// render then depends on that queue's timing, not on the views: the back and forward buttons
/// rendered 2, 1 or 0 times for the same change, more under load or with more types to work
/// out (DEV-1028). Working each type out when it's first compared keeps the counts to what the
/// views do. It takes effect before the first view is hosted, so every hosting suite asks for it.
internal enum SynchronousComparisons {
	private static let enabled: Bool = setenv("AG_ASYNC_LAYOUTS", "0", 1) == 0

	internal static func enable() {
		_ = enabled
	}
}

/// Hands out turns to render, first come, first served.
private actor RenderTurns {
	internal static let shared: RenderTurns = .init()

	private var isTaken: Bool = false
	private var waiting: [CheckedContinuation<Void, Never>] = []

	internal func acquire() async {
		guard isTaken else {
			isTaken = true
			return
		}
		await withCheckedContinuation { waiting.append($0) }
	}

	internal func release() {
		guard !waiting.isEmpty else {
			isTaken = false
			return
		}

		// The turn passes straight to the next test, which already counts as holding it.
		waiting.removeFirst().resume()
	}
}
