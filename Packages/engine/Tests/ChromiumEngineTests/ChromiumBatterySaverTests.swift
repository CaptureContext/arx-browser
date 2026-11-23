import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-915: Battery Saver's exports sit outside the ABI table.
@Suite(.serialized)
@MainActor
internal struct ChromiumBatterySaverTests {
	@Test
	internal func olderEnginesDoNothing() async throws {
		let fixture = BatterySaverFixture(exports: false)
		defer { fixture.runtime.finish() }
		#expect(!fixture.runtime.supportsBatterySaver)
		#expect(!fixture.runtime.setBatterySaverMode(3))
		#expect(!fixture.runtime.batterySaverIsActive)
		#expect(!fixture.runtime.observeBatterySaver { _ in })
	}

	@Test
	internal func modeActivityAndChangesReachTheEngine() async throws {
		let fixture = BatterySaverFixture(exports: true)
		defer { fixture.runtime.finish() }
		#expect(fixture.runtime.setBatterySaverMode(2))
		#expect(BatterySaverFixture.states == [2])
		BatterySaverFixture.isActive = true
		#expect(fixture.runtime.batterySaverIsActive)

		var heard: [Bool] = []
		#expect(fixture.runtime.observeBatterySaver { heard.append($0) })
		let handler = try #require(BatterySaverFixture.handler)
		handler(BatterySaverFixture.context, true)
		handler(BatterySaverFixture.context, false)
		#expect(heard == [true, false])

		#expect(fixture.runtime.observeBatterySaver(nil))
		#expect(BatterySaverFixture.handler == nil)
	}

	@Test
	internal func nothingBeforeTheEngineRuns() async throws {
		let fixture = BatterySaverFixture(exports: true, running: false)
		#expect(!fixture.runtime.setBatterySaverMode(1))
		#expect(BatterySaverFixture.states.isEmpty)
	}
}

@MainActor
private final class BatterySaverFixture {
	fileprivate static var states: [Int32] = []
	fileprivate static var isActive: Bool = false
	fileprivate static var handler: ChromiumBatterySaverHandler?
	fileprivate static var context: UnsafeMutableRawPointer?
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(
		exports: Bool,
		running: Bool = true
	) {
		Self.states = []
		Self.isActive = false
		Self.handler = nil
		Self.context = nil
		self.runtime = .init(api: ArxEngineAPI())
		if exports {
			runtime.optionalExports.setBatterySaverMode = { state in
				MainActor.assumeIsolated { BatterySaverFixture.states.append(state) }
				return true
			}
			runtime.optionalExports.batterySaverIsActive = {
				MainActor.assumeIsolated { BatterySaverFixture.isActive }
			}
			runtime.optionalExports.observeBatterySaver = { handler, context in
				MainActor.assumeIsolated {
					BatterySaverFixture.handler = handler
					BatterySaverFixture.context = context
				}
				return true
			}
		}
		if running { runtime.didBecomeReady() }
	}
}
