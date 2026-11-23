import AppKit
import BrowserCore
import BrowserPageWaitClient
import ChromiumBridge
import CustomDump
import Foundation
import Testing
import _TestSupport

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumWaitFactoryTests {
	@Test
	internal func storedClientRejectsUnpublishedEpochAndTracksStartupAndShutdown() async throws {
		let fixture = NativeWaitFixture()
		let client = fixture.engine.pageWait
		#expect(!client.isAvailable())
		try fixture.start()
		defer { fixture.stop() }
		#expect(client.isAvailable())
		try await fixture.open()
		fixture.publish(loading: false)
		let target = try fixture.target()
		let stopped = try await client.waitAuthorized(fixture.request, target, { true })
		#expect(client.sourceIsCurrent(stopped.source))

		NativeWaitFixture.epoch = 2
		#expect(!client.sourceIsCurrent(stopped.source))
		await #expect(throws: AutomationFailure.notReady) {
			try await client.waitAuthorized(fixture.request, fixture.target(), { true })
		}
		fixture.stop()
		#expect(!client.isAvailable())
		#expect(!client.sourceIsCurrent(stopped.source))
	}

	@Test(arguments: ["navigation", "commit", "sameIDReopen", "closure"])
	internal func nativeOwnerChangesInvalidateHeldWait(change: String) async throws {
		let fixture = NativeWaitFixture()
		try fixture.start()
		defer { fixture.stop() }
		try await fixture.open()
		fixture.publish(loading: true)
		let target = try fixture.target()
		let client = fixture.engine.pageWait
		let before = NativeWaitFixture.queries
		let task = Task { try await client.waitAuthorized(fixture.request, target, { true }) }
		try await fixture.waitForQueries(after: before)

		if change == "sameIDReopen" || change == "closure" {
			fixture.engine.client.close(fixture.tab.id)
			if change == "sameIDReopen" {
				try await fixture.open()
				fixture.publish(loading: false)
			}

		} else {
			NativeWaitFixture.epoch += 1

			// The old Swift publication remains cached until this callback. The
			// epoch changes independently, just as native start/commit does.
			fixture.publish(loading: false)
		}
		await #expect(throws: AutomationFailure.staleTarget) { try await task.value }
		if change == "sameIDReopen" {
			#expect(fixture.engine.client.snapshot(fixture.tab.id) != nil)
		}
	}

	@Test
	internal func privateNativeOwnerCannotBeReadEvenWithMatchingTabAndProfile() async throws {
		let fixture = NativeWaitFixture(usesNamedProfile: true)
		try fixture.start()
		defer { fixture.stop() }
		try fixture.runtime.preparePrivateProfile(fixture.tab.profileID.rawValue)
		try await fixture.open()
		fixture.publish(loading: false)
		await #expect(throws: AutomationFailure.staleTarget) {
			try await fixture.engine.pageWait.waitAuthorized(fixture.request, fixture.target(), { true })
		}
	}
}

@MainActor
private final class NativeWaitFixture {
	fileprivate static var callbacks: ArxEngineCallbacks?
	fileprivate static var epoch: UInt64 = 1
	fileprivate static var nextPage: UInt64 = 1
	fileprivate static var queries: Int = 0
	private static let view: NSView = .init()
	fileprivate let runtime: ChromiumRuntime
	fileprivate let engine: ChromiumBrowserEngine
	fileprivate let tab: Tab = .init(
		id: .init(rawValue: UUID(21)),
		profileID: .init(rawValue: UUID(22)),
		restoration: .init(title: "Wait fixture", url: URL(string: "https://wait.test")!)
	)

	fileprivate init(usesNamedProfile: Bool = false) {
		Self.callbacks = nil
		Self.epoch = 1
		Self.nextPage = 1
		Self.queries = 0
		var api = ArxEngineAPI()
		api.run = { _, _, callbacks in
			MainActor.assumeIsolated {
				NativeWaitFixture.callbacks = callbacks?.pointee
			}
			return 0
		}
		api.create_page = { _, _ in
			MainActor.assumeIsolated {
				defer { NativeWaitFixture.nextPage += 1 }
				return NativeWaitFixture.nextPage
			}
		}
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { NativeWaitFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.prepare_profile = { _, request in
			MainActor.assumeIsolated {
				guard let callbacks = NativeWaitFixture.callbacks else { return }
				callbacks.profile_ready(callbacks.context, request, true)
			}
		}
		api.prepare_private_profile = { _ in true }
		api.navigate = { _, _ in true }
		api.destroy_page = { _ in }
		api.history_count = { _ in 0 }
		api.page_close_generation = { _ in
			MainActor.assumeIsolated {
				NativeWaitFixture.queries += 1
				return NativeWaitFixture.epoch
			}
		}
		api.request_authorized_close = { _, _, _ in }
		api.consume_authorized_close = { _, _, _ in ARX_CLOSE_STALE }
		api.cancel_authorized_close = { _, _ in }
		runtime = ChromiumRuntime(api: api)
		engine = ChromiumBrowserEngine(
			runtime: runtime,
			profileID: usesNamedProfile ? .init(rawValue: UUID(0)) : tab.profileID
		)
	}

	fileprivate var request: AutomationWaitRequest {
		.init(targetID: tab.id.rawValue, expectedRevision: String(repeating: "a", count: 64))
	}

	fileprivate func target() throws -> PageWaitTarget {
		let snapshot = try #require(engine.client.snapshot(tab.id))
		return .init(
			tabID: tab.id,
			profileID: tab.profileID,
			sessionRevision: snapshot.revision,
			documentRevision: try #require(snapshot.documentRevision)
		)
	}

	fileprivate func start() throws {
		// The injected C table does not start a process or read/write either URL.
		_ = try runtime.run(
			executable: URL(fileURLWithPath: "/tmp/arx-unit-test-no-executable"),
			profileDirectory: URL(fileURLWithPath: "/tmp/arx-unit-test-no-profile")
		) { _ in }

		// run() finishes when the fake entry point returns. Re-enter the test
		// running state with the captured callbacks, without a native loop.
		runtime.didBecomeReady()
	}

	fileprivate func open() async throws { try await engine.client.open(tab) }

	fileprivate func publish(loading: Bool) {
		guard let callbacks = Self.callbacks else { return }
		"https://wait.test".withCString { url in
			"Wait fixture".withCString { title in
				callbacks.page_changed(callbacks.context, Self.nextPage - 1, url, title, loading, false, false, 0)
			}
		}
	}

	fileprivate func waitForQueries(after previous: Int) async throws {
		for _ in 0..<1000 {
			if Self.queries >= previous + 3 { return }
			await Task.yield()
		}
		throw AutomationFailure.timedOut
	}

	fileprivate func stop() {
		engine.closeAll()
		runtime.finish()
		Self.callbacks = nil
	}
}
