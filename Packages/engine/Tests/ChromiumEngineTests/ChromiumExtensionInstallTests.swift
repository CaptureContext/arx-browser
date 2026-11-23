import ChromiumBridge
import CryptoKit
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumExtensionInstallTests {
	@Test
	internal func verifiedPromptPrecedesOneUseConsentAndCopiedInventory() async throws {
		let fixture = InstallFixture()
		defer { fixture.bridge.stop() }
		let task = Task { try await fixture.prepare() }
		let call = await fixture.nextBegin()
		expectNoDifference(call.data, fixture.package)
		expectNoDifference(call.revision, 7)
		#expect(fixture.resolutions.isEmpty)
		fixture.prompt(call)
		let prompt = try await task.value
		expectNoDifference(prompt.profileID, fixture.profileID)
		expectNoDifference(prompt.candidate.sourceBasename, "Selected.crx")
		expectNoDifference(prompt.candidate.name, "Verified fixture")
		let result = Task { try await fixture.bridge.resolve(prompt, accept: true) }
		while fixture.resolutions.isEmpty { await Task.yield() }
		expectNoDifference(fixture.resolutions.first?.token, 11)
		expectNoDifference(fixture.resolutions.first?.accept, true)
		fixture.finish(call)
		let inventory = try await result.value
		expectNoDifference(inventory.profileID, fixture.profileID)
		expectNoDifference(inventory.revision, 8)
		expectNoDifference(inventory.extensions.first?.id, prompt.candidate.id)
		await #expect(throws: ChromiumExtensionFailure.staleInventory) {
			try await fixture.bridge.resolve(prompt, accept: true)
		}
	}

	@Test(arguments: ["profile", "token", "digest", "basename", "isUpdate", "id", "oversize", "publisher"])
	internal func inconsistentBorrowedPromptCannotReachConsent(change: String) async throws {
		let fixture = InstallFixture()
		defer { fixture.bridge.stop() }
		let task = Task { try await fixture.prepare() }
		let call = await fixture.nextBegin()
		fixture.prompt(call, change: change)
		await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await task.value }
		expectNoDifference(fixture.cancelled, [call.id])
		#expect(fixture.resolutions.isEmpty)
		fixture.prompt(call)
	}

	/// DEV-968: the manifest's author reaches the review as its publisher.
	@Test
	internal func aPromptCarriesItsPublisher() async throws {
		let fixture = InstallFixture()
		defer { fixture.bridge.stop() }
		let task = Task { try await fixture.prepare() }
		let call = await fixture.nextBegin()
		fixture.prompt(call, change: "named")
		let prompt = try await task.value
		expectNoDifference(prompt.candidate.publisher, "CaptureContext")
		fixture.bridge.cancel(prompt)
	}

	@Test
	internal func cancellationAndShutdownDropLateCallbacksWithoutReusingIDs() async throws {
		let fixture = InstallFixture()
		defer { fixture.bridge.stop() }
		let first = Task { try await fixture.prepare() }
		let old = await fixture.nextBegin()
		first.cancel()
		await #expect(throws: CancellationError.self) { try await first.value }
		let second = Task { try await fixture.prepare() }
		let current = await fixture.nextBegin()
		#expect(current.id > old.id)
		fixture.prompt(old)
		fixture.prompt(current)
		let prompt = try await second.value
		fixture.bridge.cancel(prompt)
		await #expect(throws: ChromiumExtensionFailure.staleInventory) {
			try await fixture.bridge.resolve(prompt, accept: true)
		}
		let third = Task { try await fixture.prepare() }
		let pending = await fixture.nextBegin()
		fixture.bridge.stop()
		await #expect(throws: ChromiumExtensionFailure.unavailable) { try await third.value }
		fixture.prompt(pending)
		expectNoDifference(fixture.cancelled, [old.id, current.id, pending.id])
	}

	@Test
	internal func noApprovalCanBeInferredFromAnEarlySuccessOrRejectedNativeToken() async throws {
		let fixture = InstallFixture()
		defer { fixture.bridge.stop() }
		let first = Task { try await fixture.prepare() }
		let early = await fixture.nextBegin()
		fixture.finish(early)
		await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await first.value }
		let second = Task { try await fixture.prepare() }
		let call = await fixture.nextBegin()
		fixture.prompt(call)
		let prompt = try await second.value
		fixture.acceptResolution = false
		await #expect(throws: ChromiumExtensionFailure.staleInventory) {
			try await fixture.bridge.resolve(prompt, accept: true)
		}
		expectNoDifference(fixture.cancelled, [call.id])
	}

	@Test(arguments: [ARX_EXTENSION_CANCELLED, ARX_EXTENSION_INVALID_PACKAGE, ARX_EXTENSION_TIMEOUT])
	internal func failedNativePreparationPreservesTypedError(_ status: ArxExtensionStatus) async throws {
		let fixture = InstallFixture()
		defer { fixture.bridge.stop() }
		let task = Task { try await fixture.prepare() }
		fixture.finish(await fixture.nextBegin(), status: status)
		await #expect(throws: ChromiumExtensionFailure(status: status)) { try await task.value }
	}
}

@MainActor
private final class InstallFixture {
	private static var active: InstallFixture?
	fileprivate let runtimeID: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000001")!
	fileprivate let profileID: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000002")!
	fileprivate let package: Data = .init([1, 2, 3])
	fileprivate var bridge: ChromiumExtensionInstalls!
	fileprivate var resolutions: [Resolution] = []
	fileprivate var cancelled: [UInt64] = []
	fileprivate var acceptResolution: Bool = true
	private var begins: [Begin] = []
	private var nextID: UInt64 = 1

	fileprivate init() {
		InstallFixture.active = self
		var api = ArxEngineAPI()
		api.extension_install_available = { true }
		api.install_extension_crx = { key, id, revision, _, _, bytes, count in
			MainActor.assumeIsolated {
				InstallFixture.active?.begins.append(.init(
					id: id,
					key: String(cString: key!),
					revision: revision,
					data: Data(bytes: bytes!, count: count)
				))
			}
		}
		api.resolve_extension_install = { _, id, token, accept in
			MainActor.assumeIsolated {
				InstallFixture.active?.resolutions.append(.init(id: id, token: token, accept: accept))
				return InstallFixture.active?.acceptResolution == true
			}
		}
		api.cancel_extension_request = { id in
			MainActor.assumeIsolated { InstallFixture.active?.cancelled.append(id) }
		}
		self.bridge = .init(api: api, runtimeID: runtimeID) { [unowned self] in
			defer { nextID += 1 }
			return nextID
		}
	}

	fileprivate func prepare() async throws -> ChromiumExtensionInstallPrompt {
		try await bridge.prepare(
			data: package,
			basename: "Selected.crx",
			expectedID: nil,
			inventory: .init(runtimeID: runtimeID, profileID: profileID, revision: 7, extensions: [])
		)
	}

	fileprivate func nextBegin() async -> Begin {
		while begins.isEmpty { await Task.yield() }
		return begins.removeFirst()
	}

	fileprivate func prompt(
		_ call: Begin,
		change: String = ""
	) {
		let permissions: [String: Any] = ["apis": ["storage"], "hosts": []]
		var object: [String: Any] = [
			"id": String(repeating: "a", count: 32),
			"name": "Verified fixture",
			"version": "1.0",
			"packageSHA256": SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined(),
			"sourceBasename": "Selected.crx",
			"isUpdate": false,
			"requiredPermissions": permissions,
			"optionalPermissions": permissions,
			"warnings": [],
		]
		switch change {
		case "digest": object["packageSHA256"] = String(repeating: "f", count: 64)
		case "basename": object["sourceBasename"] = "Other.crx"
		case "isUpdate": object["isUpdate"] = true
		case "id": object["id"] = "invalid"
		case "publisher": object["publisher"] = "Line\nbreak"
		case "named": object["publisher"] = "CaptureContext"
		default: break
		}
		if change == "oversize" {
			bridge.prompt(call.id, profileKey: call.key, token: 11, bytes: nil, count: 1_048_577)
			return
		}
		var bytes = Array(try! JSONSerialization.data(withJSONObject: object))
		bytes.withUnsafeBufferPointer {
			bridge.prompt(
				call.id,
				profileKey: change == "profile" ? "other" : call.key,
				token: change == "token" ? 0 : 11,
				bytes: $0.baseAddress,
				count: $0.count
			)
		}
		bytes = Array(repeating: 0, count: bytes.count)
	}

	fileprivate func finish(
		_ call: Begin,
		status: ArxExtensionStatus = ARX_EXTENSION_SUCCESS
	) {
		let permissions: [String: Any] = ["apis": ["storage"], "hosts": []]
		let object: [String: Any] = [
			"id": String(repeating: "a", count: 32),
			"name": "Verified fixture",
			"version": "1.0",
			"manifestVersion": 3,
			"location": 1,
			"fromWebStore": false,
			"state": "enabled",
			"disableReasons": [],
			"permissionsIncreased": false,
			"isFixture": false,
			"canEnable": false,
			"canDisable": true,
			"canRemove": true,
			"requiredPermissions": permissions,
			"optionalPermissions": permissions,
			"activePermissions": permissions,
			"withheldPermissions": permissions,
		]
		let bytes = try! JSONSerialization.data(withJSONObject: ["extensions": [object]])
		bytes.withUnsafeBytes {
			#expect(bridge.complete(
				call.id,
				profileKey: call.key,
				status: status,
				revision: 8,
				bytes: $0.bindMemory(to: UInt8.self).baseAddress,
				count: $0.count
			))
		}
	}

	fileprivate struct Begin {
		fileprivate let id: UInt64
		fileprivate let key: String
		fileprivate let revision: UInt64
		fileprivate let data: Data
	}

	fileprivate struct Resolution {
		fileprivate let id: UInt64
		fileprivate let token: UInt64
		fileprivate let accept: Bool
	}
}
