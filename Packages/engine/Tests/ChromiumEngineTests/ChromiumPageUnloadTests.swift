import AppKit
import ChromiumBridge
import Testing

@testable import ChromiumEngine

/// DEV-873: tab unloading is an export outside the ABI table, so an engine built before it
/// still loads and only can't unload pages.
@Suite(.serialized)
@MainActor
internal struct ChromiumPageUnloadTests {
	@Test
	internal func olderEnginesCannotUnload() throws {
		let fixture = UnloadFixture(exports: false)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		#expect(!fixture.runtime.supportsPageUnloading)
		#expect(fixture.runtime.unload(page, reason: .inactive) == .unavailable)
		#expect(!fixture.runtime.isUnloaded(page))
		#expect(!fixture.runtime.restoreUnloadedPage(page))
		#expect(UnloadFixture.calls.isEmpty)
	}

	@Test
	internal func unloadPassesTheReasonAndMapsTheEngineAnswer() throws {
		let fixture = UnloadFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()
		#expect(fixture.runtime.supportsPageUnloading)

		UnloadFixture.answer = (0, 0)
		#expect(fixture.runtime.unload(page, reason: .inactive) == .unloaded)
		UnloadFixture.answer = (3, (1 << 0) | (1 << 2))
		#expect(fixture.runtime.unload(page, reason: .memoryPressure) == .refused([.chrome, .developerTools]))
		UnloadFixture.answer = (3, 1 << 9)
		#expect(fixture.runtime.unload(page, reason: .memoryPressure) == .refused(.liveConnection))
		UnloadFixture.answer = (2, 0)
		#expect(fixture.runtime.unload(page, reason: .inactive) == .alreadyUnloaded)
		UnloadFixture.answer = (4, 1 << 6)
		#expect(fixture.runtime.unload(page, reason: .inactive) == .busy)
		UnloadFixture.answer = (1, 0)
		#expect(fixture.runtime.unload(page, reason: .inactive) == .unavailable)
		UnloadFixture.answer = (99, 0)
		#expect(fixture.runtime.unload(page, reason: .inactive) == .unavailable)
		// DEV-1104: a closed window's unload, and the input it keeps.
		UnloadFixture.answer = (0, 0)
		#expect(fixture.runtime.unload(page, reason: .windowClosed) == .unloaded)
		UnloadFixture.answer = (3, (1 << 10) | (1 << 4))
		#expect(fixture.runtime.unload(page, reason: .windowClosed) == .refused([.unsavedInput, .pictureInPicture]))

		#expect(UnloadFixture.calls.map(\.reason) == [0, 1, 1, 0, 0, 0, 0, 2, 2])
		#expect(UnloadFixture.calls.allSatisfy { $0.page == page.identifier })
	}

	/// DEV-1107: which pages a closing window asks, and their unload once answered, are newer
	/// exports; an engine built before them asks nothing.
	@Test
	internal func answeredUnloadsNeedTheirOwnExports() throws {
		let fixture = UnloadFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		#expect(!fixture.runtime.supportsAnsweredUnloads)
		#expect(fixture.runtime.unloadBlockers(page, reason: .windowClosed) == nil)
		#expect(fixture.runtime.unload(page, reason: .windowClosedAnswered) == .unavailable)
		#expect(UnloadFixture.calls.isEmpty)
	}

	@Test
	internal func answeredUnloadsUseTheirExports() throws {
		let fixture = UnloadFixture(exports: true, answers: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()
		#expect(fixture.runtime.supportsAnsweredUnloads)

		UnloadFixture.answer = (3, (1 << 10) | (1 << 1))
		#expect(fixture.runtime.unloadBlockers(page, reason: .windowClosed) == [.unsavedInput, .visible])
		#expect(UnloadFixture.probes.map(\.reason) == [2])
		// Unloading doesn't go through the probe, and the answered unload not through the old export.
		UnloadFixture.answer = (0, 0)
		#expect(fixture.runtime.unload(page, reason: .windowClosedAnswered) == .unloaded)
		UnloadFixture.answer = (3, 1 << 2)
		#expect(fixture.runtime.unload(page, reason: .windowClosedAnswered) == .refused(.developerTools))
		#expect(UnloadFixture.answered == [page.identifier, page.identifier])
		#expect(UnloadFixture.calls.isEmpty)

		page.close()
		#expect(fixture.runtime.unloadBlockers(page, reason: .windowClosed) == nil)
		#expect(fixture.runtime.unload(page, reason: .windowClosedAnswered) == .unavailable)
		#expect(UnloadFixture.answered.count == 2)
	}

	@Test
	internal func stateAndRestoreReadTheEngine() throws {
		let fixture = UnloadFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		UnloadFixture.unloaded = true
		#expect(fixture.runtime.isUnloaded(page))
		#expect(fixture.runtime.restoreUnloadedPage(page))
		#expect(UnloadFixture.restored == [page.identifier])
		#expect(!fixture.runtime.isUnloaded(page))
	}

	@Test
	internal func closedPagesAndStoppedEnginesAreNeverAsked() throws {
		let fixture = UnloadFixture(exports: true)
		let page = try fixture.runtime.makePage()
		page.close()

		#expect(fixture.runtime.unload(page, reason: .inactive) == .unavailable)
		fixture.runtime.finish()
		#expect(fixture.runtime.unload(page, reason: .memoryPressure) == .unavailable)
		#expect(!fixture.runtime.restoreUnloadedPage(page))
		#expect(UnloadFixture.calls.isEmpty)
		#expect(UnloadFixture.restored.isEmpty)
	}
}

@MainActor
private final class UnloadFixture {
	fileprivate static var view: NSView = .init()
	fileprivate static var calls: [(page: UInt64, reason: UInt32)] = []
	fileprivate static var answer: (status: Int32, blockers: UInt32) = (0, 0)
	fileprivate static var unloaded: Bool = false
	fileprivate static var restored: [UInt64] = []
	fileprivate static var probes: [(page: UInt64, reason: UInt32)] = []
	fileprivate static var answered: [UInt64] = []
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(exports: Bool, answers: Bool = false) {
		Self.calls = []
		Self.probes = []
		Self.answered = []
		Self.answer = (0, 0)
		Self.unloaded = false
		Self.restored = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { UnloadFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		let functions = ChromiumPageUnloadFunctions(
			unload: { page, reason, blockers in
				MainActor.assumeIsolated {
					UnloadFixture.calls.append((page, reason))
					blockers?.pointee = UnloadFixture.answer.blockers
					return UnloadFixture.answer.status
				}
			},
			isUnloaded: { _ in MainActor.assumeIsolated { UnloadFixture.unloaded } },
			restore: { page in
				MainActor.assumeIsolated {
					guard UnloadFixture.unloaded else { return false }
					UnloadFixture.unloaded = false
					UnloadFixture.restored.append(page)
					return true
				}
			},
			blockers: answers ? { page, reason in
				MainActor.assumeIsolated {
					UnloadFixture.probes.append((page, reason))
					return UnloadFixture.answer.blockers
				}
			} : nil,
			unloadAnswered: answers ? { page, blockers in
				MainActor.assumeIsolated {
					UnloadFixture.answered.append(page)
					blockers?.pointee = UnloadFixture.answer.blockers
					return UnloadFixture.answer.status
				}
			} : nil
		)
		self.runtime = .init(api: api, pageUnloading: exports ? functions : nil)
		runtime.didBecomeReady()
	}
}
