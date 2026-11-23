import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-905: device choosers' exports sit outside the ABI table.
@Suite(.serialized)
@MainActor
internal struct ChromiumDeviceChooserTests {
	@Test
	internal func choosersAreReadAnsweredAndRescanned() async throws {
		let fixture = DeviceChooserFixture()
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()
		#expect(fixture.runtime.supportsDeviceChoosers)

		var heard: [(UInt64, UInt64, Bool)] = []
		fixture.runtime.observeDeviceChoosers { page, token, isOpen in heard.append((page.identifier, token, isOpen)) }
		let handler = try #require(DeviceChooserFixture.handler)
		handler(DeviceChooserFixture.context, page.identifier, 7, true)
		handler(DeviceChooserFixture.context, 99, 8, true)
		#expect(heard.map(\.1) == [7])

		DeviceChooserFixture.json = """
		{"token":"18446744073709551615","revision":"4","title":"example.com wants to connect to a serial port","multiple":false,\
		"rescan":true,"scanning":true,"adapterOff":false,\
		"options":[{"name":"USB Serial","connected":false,"paired":true,"signal":3}]}
		"""
		let chooser = try #require(fixture.runtime.deviceChooser(on: page))
		#expect(chooser.token == UInt64.max)
		#expect(chooser.revision == 4)
		#expect(chooser.options == [.init(name: "USB Serial", paired: true, signal: 3)])
		#expect(chooser.rescan && chooser.scanning)

		#expect(fixture.runtime.answerDeviceChooser(on: page, token: 7, revision: 4, indices: [0]))
		#expect(DeviceChooserFixture.answers.map(\.indices) == [[0]])
		#expect(DeviceChooserFixture.answers.map(\.revision) == [4])
		#expect(!fixture.runtime.answerDeviceChooser(on: page, token: 7, revision: 4, indices: [-1]))
		#expect(fixture.runtime.rescanDeviceChooser(on: page, token: 7))
		#expect(DeviceChooserFixture.rescans == [7])

		fixture.runtime.observeDeviceChoosers(nil)
		#expect(DeviceChooserFixture.handler == nil)
	}

	@Test
	internal func grantsAreListedAndRevokedPerProfile() async throws {
		let fixture = DeviceChooserFixture()
		defer { fixture.runtime.finish() }
		DeviceChooserFixture.json = """
		[{"kind":"usb","origin":"https://flash.example","key":"1:2","name":"Board"}]
		"""
		let profile = UUID()
		let grants = try #require(fixture.runtime.deviceGrants(profile: profile))
		#expect(grants == [.init(kind: "usb", origin: "https://flash.example", key: "1:2", name: "Board")])
		#expect(DeviceChooserFixture.keys == [profile.uuidString.lowercased()])
		#expect(fixture.runtime.revokeDeviceGrant(grants[0], profile: nil))
		#expect(DeviceChooserFixture.revoked == ["|usb|https://flash.example|1:2"])
	}
}

@MainActor
private final class DeviceChooserFixture {
	fileprivate static var view: NSView = .init()
	fileprivate static var handler: ChromiumDeviceChooserHandler?
	fileprivate static var context: UnsafeMutableRawPointer?
	nonisolated(unsafe) fileprivate static var json: String = ""
	fileprivate static var answers: [(token: UInt64, revision: UInt64, indices: [UInt32])] = []
	fileprivate static var rescans: [UInt64] = []
	fileprivate static var keys: [String] = []
	fileprivate static var revoked: [String] = []
	fileprivate let runtime: ChromiumRuntime

	fileprivate init() {
		Self.handler = nil
		Self.context = nil
		Self.json = ""
		Self.answers = []
		Self.rescans = []
		Self.keys = []
		Self.revoked = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { DeviceChooserFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		self.runtime = .init(api: api)
		runtime.optionalExports.deviceChoosers = .init(
			setHandler: { handler, context in
				MainActor.assumeIsolated {
					DeviceChooserFixture.handler = handler
					DeviceChooserFixture.context = context
				}
			},
			copy: { _, buffer, capacity in DeviceChooserFixture.copy(buffer, capacity) },
			answer: { _, token, revision, indices, count in
				let values = (0 ..< count).map { indices![$0] }
				MainActor.assumeIsolated { DeviceChooserFixture.answers.append((token, revision, values)) }
				return true
			},
			rescan: { _, token in
				MainActor.assumeIsolated { DeviceChooserFixture.rescans.append(token) }
				return true
			},
			copyGrants: { key, buffer, capacity in
				let key = key.map { String(cString: $0) } ?? ""
				let isFirstRead = buffer == nil
				MainActor.assumeIsolated {
					if isFirstRead { DeviceChooserFixture.keys.append(key) }
				}
				return DeviceChooserFixture.copy(buffer, capacity)
			},
			revokeGrant: { key, kind, origin, grant in
				let parts = [key, kind, origin, grant].map { $0.map { String(cString: $0) } ?? "" }
				MainActor.assumeIsolated { DeviceChooserFixture.revoked.append(parts.joined(separator: "|")) }
				return true
			}
		)
		runtime.didBecomeReady()
	}

	nonisolated fileprivate static func copy(
		_ buffer: UnsafeMutablePointer<CChar>?,
		_ capacity: Int
	) -> Int {
		let bytes = Array(json.utf8)
		if let buffer, capacity > bytes.count {
			for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
			buffer[bytes.count] = 0
		}
		return bytes.count
	}
}
