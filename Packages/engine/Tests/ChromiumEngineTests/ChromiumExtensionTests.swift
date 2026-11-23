import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumExtensionTests {
	@Test
	internal func capabilityAndFixtureAreDisabledByDefault() async throws {
		let fixture = ExtensionFixture(enabled: false)
		await #expect(throws: ChromiumExtensionFailure.unavailable) { try await fixture.bridge.inspect(profileID: nil) }
		await #expect(throws: ChromiumExtensionFailure.unavailable) { try await fixture.bridge.loadFixture(profileID: nil) }
		#expect(ExtensionFixture.calls.isEmpty)
	}

	@Test
	internal func privateAndReleasedPrivateProfilesNeverReachInventory() async throws {
		var api = ArxEngineAPI()
		api.prepare_private_profile = { _ in true }
		api.release_private_profile = { _ in }
		api.inspect_extensions = { _, _ in Issue.record("Private inventory reached native code") }
		api.prepare_profile = { _, _ in Issue.record("Private profile became persistent") }
		let runtime = ChromiumRuntime(api: api)
		runtime.extensionBridge.configure(enabled: true, fixture: false)
		runtime.didBecomeReady()
		defer { runtime.finish() }
		let privateID = UUID()
		try runtime.preparePrivateProfile(privateID)
		await #expect(throws: ChromiumExtensionFailure.unavailable) {
			try await runtime.extensions(profileID: privateID)
		}
		runtime.releasePrivateProfile(privateID)
		await #expect(throws: ChromiumExtensionFailure.unavailable) {
			try await runtime.extensions(profileID: privateID)
		}
	}

	@Test
	internal func optionsOfferRequiresOneMatchingPendingProfileAndExtensionRequest() async throws {
		let fixture = ExtensionFixture()
		let profile = UUID()
		let loading = Task { try await fixture.bridge.inspect(profileID: profile) }
		fixture.deliver(await fixture.nextCall(), revision: 31, hasOptions: true)
		let inventory = try await loading.value
		let opening = Task {
			try await fixture.bridge.openOptions(extensionID: ExtensionFixture.extensionID, in: inventory)
		}
		let call = await fixture.nextCall()
		#expect(call.key == profile.uuidString.lowercased())
		#expect(call.revision == 31)
		let wrongProfile = fixture.bridge.consumeOptionsOffer(
			request: call.id,
			profileKey: "",
			extensionID: ExtensionFixture.extensionID
		)
		#expect(!wrongProfile)
		let foreignRequest = fixture.bridge.consumeOptionsOffer(
			request: call.id + 1,
			profileKey: call.key,
			extensionID: ExtensionFixture.extensionID
		)
		#expect(!foreignRequest)
		let wrongExtension = fixture.bridge.consumeOptionsOffer(
			request: call.id,
			profileKey: call.key,
			extensionID: String(repeating: "b", count: 32)
		)
		#expect(!wrongExtension)
		let accepted = fixture.bridge.consumeOptionsOffer(
			request: call.id,
			profileKey: call.key,
			extensionID: ExtensionFixture.extensionID
		)
		#expect(accepted)
		let replay = fixture.bridge.consumeOptionsOffer(
			request: call.id,
			profileKey: call.key,
			extensionID: ExtensionFixture.extensionID
		)
		#expect(!replay)
		fixture.deliver(call, revision: 31, hasOptions: true)
		#expect(try await opening.value.revision == 31)
		let late = fixture.bridge.consumeOptionsOffer(
			request: call.id,
			profileKey: call.key,
			extensionID: ExtensionFixture.extensionID
		)
		#expect(!late)
	}

	@Test
	internal func optionsCompletionWithoutAnyOwnedOfferCannotReportSuccess() async throws {
		let fixture = ExtensionFixture()
		let loading = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), hasOptions: true)
		let inventory = try await loading.value
		let opening = Task {
			try await fixture.bridge.openOptions(extensionID: ExtensionFixture.extensionID, in: inventory)
		}
		let call = await fixture.nextCall()
		fixture.deliver(call, hasOptions: true)

		await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await opening.value }
		#expect(!fixture.bridge.consumeOptionsOffer(
			request: call.id,
			profileKey: call.key,
			extensionID: ExtensionFixture.extensionID
		))
	}

	@Test
	internal func canceledOptionsCannotPublishThroughItsLateOffer() async throws {
		let fixture = ExtensionFixture()
		let loading = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), hasOptions: true)
		let inventory = try await loading.value
		let opening = Task {
			try await fixture.bridge.openOptions(extensionID: ExtensionFixture.extensionID, in: inventory)
		}
		let call = await fixture.nextCall()
		opening.cancel()

		await #expect(throws: CancellationError.self) { try await opening.value }
		#expect(ExtensionFixture.cancelled == [call.id])
		#expect(!fixture.bridge.consumeOptionsOffer(
			request: call.id,
			profileKey: call.key,
			extensionID: ExtensionFixture.extensionID
		))
		fixture.deliver(call, hasOptions: true)
	}

	@Test
	internal func copiesInventoryAndBindsItsProfileAndRevision() async throws {
		let fixture = ExtensionFixture()
		let profile = UUID()
		let task = Task { try await fixture.bridge.inspect(profileID: profile) }
		let request = await fixture.nextCall()
		expectNoDifference(request.key, profile.uuidString.lowercased())
		fixture.deliver(request, revision: 31)
		let inventory = try await task.value
		expectNoDifference(inventory.profileID, profile)
		#expect(inventory.revision == 31)
		let extension_ = try #require(inventory.extensions.first)
		expectNoDifference(extension_.name, "Fixture")
		expectNoDifference(extension_.activePermissions.hosts, ["http://127.0.0.1/*"])
		let change = Task { try await fixture.bridge.manage(.disable, extensionID: extension_.id, in: inventory) }
		let mutation = await fixture.nextCall()
		expectNoDifference(mutation.key, profile.uuidString.lowercased())
		#expect(mutation.revision == 31 && mutation.action == ARX_EXTENSION_DISABLE)
		fixture.deliver(mutation, state: "disabled", reasons: [1], revision: 32)
		#expect(try await change.value.extensions.first?.disableReasons == [.userAction])
	}

	@Test
	internal func rejectsInventoryFromAnotherRuntimeBeforeNativeMutation() async throws {
		let first = ExtensionFixture()
		let task = Task { try await first.bridge.inspect(profileID: nil) }
		first.deliver(await first.nextCall())
		let inventory = try await task.value
		let second = ExtensionFixture()
		await #expect(throws: ChromiumExtensionFailure.staleInventory) {
			try await second.bridge.manage(.disable, extensionID: ExtensionFixture.extensionID, in: inventory)
		}
		#expect(ExtensionFixture.calls.isEmpty)
	}

	@Test(arguments: [[1, 2], [2], [1, 1 << 25], [1, 1 << 29]])
	internal func neverEnablesPendingOrUnknownDisableReasons(_ reasons: [Int]) async throws {
		let fixture = ExtensionFixture()
		let task = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), state: "disabled", reasons: reasons)
		let inventory = try await task.value
		expectNoDifference(inventory.extensions[0].disableReasons.map(\.rawValue), reasons)
		await #expect(throws: ChromiumExtensionFailure.reviewRequired) {
			try await fixture.bridge.manage(.enable, extensionID: ExtensionFixture.extensionID, in: inventory)
		}
		#expect(ExtensionFixture.calls.isEmpty)
	}

	@Test
	internal func rejectsInconsistentEnableCapabilityInResponse() async throws {
		let fixture = ExtensionFixture()
		let task = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), state: "disabled", reasons: [1, 2], forceEnable: true)
		await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await task.value }
	}

	@Test
	internal func staleNativeRevisionCannotBeReportedAsSuccess() async throws {
		let fixture = ExtensionFixture()
		let task = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), state: "disabled", reasons: [1])
		let inventory = try await task.value
		let change = Task { try await fixture.bridge.manage(.enable, extensionID: ExtensionFixture.extensionID, in: inventory) }
		let request = await fixture.nextCall()
		fixture.deliver(request, status: ARX_EXTENSION_STALE)
		await #expect(throws: ChromiumExtensionFailure.staleInventory) { try await change.value }
	}

	@Test
	internal func rejectsWrongProfileWithoutConsumingOtherRequest() async throws {
		let fixture = ExtensionFixture()
		let first = Task { try await fixture.bridge.inspect(profileID: UUID()) }
		let a = await fixture.nextCall()
		let second = Task { try await fixture.bridge.inspect(profileID: UUID()) }
		let b = await fixture.nextCall()
		fixture.deliver(a, key: b.key)
		fixture.deliver(b)
		await #expect(throws: ChromiumExtensionFailure.staleInventory) { try await first.value }
		#expect(try await second.value.profileID?.uuidString.lowercased() == b.key)
	}

	@Test
	internal func cancellationIgnoresLateCallbackAndLeavesNextRequestLive() async throws {
		let fixture = ExtensionFixture()
		let first = Task { try await fixture.bridge.inspect(profileID: nil) }
		let old = await fixture.nextCall()
		first.cancel()
		await #expect(throws: CancellationError.self) { try await first.value }
		expectNoDifference(ExtensionFixture.cancelled, [old.id])
		let next = Task { try await fixture.bridge.inspect(profileID: nil) }
		let current = await fixture.nextCall()
		fixture.deliver(old)
		fixture.deliver(current, revision: 5)
		#expect(try await next.value.revision == 5)
	}

	@Test
	internal func shutdownDrainsRequestsAndRejectsNewWork() async throws {
		let fixture = ExtensionFixture()
		let task = Task { try await fixture.bridge.inspect(profileID: nil) }
		let request = await fixture.nextCall()
		fixture.bridge.stop()
		await #expect(throws: ChromiumExtensionFailure.unavailable) { try await task.value }
		fixture.deliver(request)
		await #expect(throws: ChromiumExtensionFailure.unavailable) { try await fixture.bridge.inspect(profileID: nil) }
	}

	@Test
	internal func rejectsOversizedBytesBeforeDereferencingPointer() async throws {
		let fixture = ExtensionFixture()
		let task = Task { try await fixture.bridge.inspect(profileID: nil) }
		let request = await fixture.nextCall()
		fixture.bridge.complete(
			request.id,
			profileKey: request.key,
			status: ARX_EXTENSION_SUCCESS,
			revision: 1,
			bytes: nil,
			count: 1_048_577
		)
		await #expect(throws: ChromiumExtensionFailure.limitExceeded) { try await task.value }
	}

	@Test
	internal func unpackedLoadBindsFolderToInventoryProfileAndRevision() async throws {
		let fixture = ExtensionFixture()
		let profile = UUID()
		let loading = Task { try await fixture.bridge.inspect(profileID: profile) }
		fixture.deliver(await fixture.nextCall(), revision: 7)
		let inventory = try await loading.value
		let directory = URL(fileURLWithPath: "/tmp/arx unpacked/./fixture", isDirectory: true)
		let load = Task { try await fixture.bridge.loadUnpacked(directory: directory, in: inventory) }
		let call = await fixture.nextCall()
		expectNoDifference(call.key, profile.uuidString.lowercased())
		#expect(call.revision == 7)
		expectNoDifference(call.directory, "/tmp/arx unpacked/fixture/")
		fixture.deliver(call, revision: 8, canReload: true, sourcePath: "/tmp/arx unpacked/fixture")
		let loaded = try await load.value
		#expect(loaded.extensions.first?.canReload == true)
		expectNoDifference(loaded.extensions.first?.sourcePath, "/tmp/arx unpacked/fixture")
	}

	@Test
	internal func unpackedLoadIsUnavailableWithoutTheNativeCapability() async throws {
		let fixture = ExtensionFixture(unpacked: false)
		let loading = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall())
		let inventory = try await loading.value
		#expect(!fixture.bridge.isUnpackedAvailable)
		await #expect(throws: ChromiumExtensionFailure.unavailable) {
			try await fixture.bridge.loadUnpacked(directory: URL(fileURLWithPath: "/tmp/fixture"), in: inventory)
		}
		#expect(ExtensionFixture.calls.isEmpty)
	}

	@Test
	internal func unpackedLoadRejectsAnotherRuntimesInventoryAndRelativeFolders() async throws {
		let first = ExtensionFixture()
		let loading = Task { try await first.bridge.inspect(profileID: nil) }
		first.deliver(await first.nextCall())
		let inventory = try await loading.value
		await #expect(throws: ChromiumExtensionFailure.invalidRequest) {
			try await first.bridge.loadUnpacked(directory: URL(string: "https://capturecontext.dev/fixture")!, in: inventory)
		}
		let second = ExtensionFixture()
		await #expect(throws: ChromiumExtensionFailure.staleInventory) {
			try await second.bridge.loadUnpacked(directory: URL(fileURLWithPath: "/tmp/fixture"), in: inventory)
		}
		#expect(ExtensionFixture.calls.isEmpty)
	}

	@Test
	internal func unpackedFailuresCarryTheirActionableReason() async throws {
		let fixture = ExtensionFixture()
		let loading = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall())
		let inventory = try await loading.value
		let directory = URL(fileURLWithPath: "/tmp/fixture")

		let missing = Task { try await fixture.bridge.loadUnpacked(directory: directory, in: inventory) }
		fixture.fail(await fixture.nextCall(), status: ARX_EXTENSION_DIRECTORY_MISSING)
		await #expect(throws: ChromiumExtensionFailure.directoryMissing) { try await missing.value }

		let unreadable = Task { try await fixture.bridge.loadUnpacked(directory: directory, in: inventory) }
		fixture.fail(await fixture.nextCall(), status: ARX_EXTENSION_DIRECTORY_UNREADABLE)
		await #expect(throws: ChromiumExtensionFailure.directoryUnreadable) { try await unreadable.value }

		let invalid = Task { try await fixture.bridge.loadUnpacked(directory: directory, in: inventory) }
		let manifestError = "Manifest is not valid JSON.  Line: 1, column: 2, Syntax error."
		fixture.fail(
			await fixture.nextCall(),
			status: ARX_EXTENSION_MANIFEST_INVALID,
			error: manifestError
		)
		await #expect(throws: ChromiumExtensionFailure.invalidManifest(manifestError)) {
			try await invalid.value
		}

		let controls = Task { try await fixture.bridge.loadUnpacked(directory: directory, in: inventory) }
		fixture.fail(await fixture.nextCall(), status: ARX_EXTENSION_MANIFEST_INVALID, error: "bad\nline")
		await #expect(throws: ChromiumExtensionFailure.invalidManifest("")) { try await controls.value }
	}

	@Test
	internal func reloadRequiresANativeUnpackedReloadCapability() async throws {
		let fixture = ExtensionFixture()
		let packed = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall())
		let packedInventory = try await packed.value
		await #expect(throws: ChromiumExtensionFailure.blockedByPolicy) {
			try await fixture.bridge.manage(.reload, extensionID: ExtensionFixture.extensionID, in: packedInventory)
		}
		#expect(ExtensionFixture.calls.isEmpty)

		let unpacked = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), revision: 4, canReload: true)
		let inventory = try await unpacked.value
		let reload = Task { try await fixture.bridge.manage(.reload, extensionID: ExtensionFixture.extensionID, in: inventory) }
		let call = await fixture.nextCall()
		#expect(call.action == ARX_EXTENSION_RELOAD && call.revision == 4)
		fixture.deliver(call, revision: 5, canReload: true)
		#expect(try await reload.value.revision == 5)
	}

	@Test
	internal func privateWindowSwitchNeedsTheNativeCapability() async throws {
		let fixture = ExtensionFixture()
		let older = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall())
		let olderInventory = try await older.value
		#expect(olderInventory.extensions.first?.canAllowInPrivate == nil)
		await #expect(throws: ChromiumExtensionFailure.blockedByPolicy) {
			try await fixture.bridge.manage(.allowInPrivate, extensionID: ExtensionFixture.extensionID, in: olderInventory)
		}
		#expect(ExtensionFixture.calls.isEmpty)

		let current = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), revision: 6, allowedInPrivate: false, canAllowInPrivate: true)
		let inventory = try await current.value
		#expect(inventory.extensions.first?.allowedInPrivate == false)
		let allow = Task { try await fixture.bridge.manage(.allowInPrivate, extensionID: ExtensionFixture.extensionID, in: inventory) }
		let call = await fixture.nextCall()
		#expect(call.action == ARX_EXTENSION_ALLOW_PRIVATE && call.revision == 6)
		fixture.deliver(call, revision: 7, allowedInPrivate: true, canAllowInPrivate: true)
		let allowed = try await allow.value
		#expect(allowed.extensions.first?.allowedInPrivate == true)

		let disallow = Task { try await fixture.bridge.manage(.disallowInPrivate, extensionID: ExtensionFixture.extensionID, in: allowed) }
		let second = await fixture.nextCall()
		#expect(second.action == ARX_EXTENSION_DISALLOW_PRIVATE && second.revision == 7)
		fixture.deliver(second, revision: 8, allowedInPrivate: false, canAllowInPrivate: true)
		#expect(try await disallow.value.extensions.first?.allowedInPrivate == false)
	}

	@Test
	internal func reloadAndSourceFolderBelongOnlyToUnpackedRows() async throws {
		let fixture = ExtensionFixture()
		let reloadable = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), location: 1, canReload: true)
		await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await reloadable.value }
		let source = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), sourcePath: "relative/folder")
		await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await source.value }
	}

	@Test
	internal func iconPathIsOptionalAndAbsolute() async throws {
		let fixture = ExtensionFixture()
		let older = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall())
		let olderInventory = try await older.value
		#expect(olderInventory.extensions.first?.iconPath == nil)

		let iconed = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), iconPath: "/tmp/arx extensions/fixture/icons/32.png")
		let iconedInventory = try await iconed.value
		expectNoDifference(
			iconedInventory.extensions.first?.iconPath,
			"/tmp/arx extensions/fixture/icons/32.png"
		)

		for path in ["icons/32.png", "/tmp/fixture/../escape.png", "/tmp/fixture/\u{7}.png"] {
			let invalid = Task { try await fixture.bridge.inspect(profileID: nil) }
			fixture.deliver(await fixture.nextCall(), iconPath: path)
			await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await invalid.value }
		}
	}

	@Test
	internal func iconSizesAreOptionalPlainSizesWithAbsolutePaths() async throws {
		let fixture = ExtensionFixture()
		let older = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall())
		let olderExtension = try #require(try await older.value.extensions.first)
		#expect(olderExtension.icons == nil)
		#expect(olderExtension.actionIcons == nil)
		#expect(ChromiumExtension.iconSizes(olderExtension.icons).isEmpty)

		let sized = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(
			await fixture.nextCall(),
			icons: ["16": "/x/icons/16.png", "128": "/x/icons/128.png"],
			actionIcons: ["32": "/x/action/32.png"]
		)
		let sizedExtension = try #require(try await sized.value.extensions.first)
		expectNoDifference(
			ChromiumExtension.iconSizes(sizedExtension.icons),
			[16: "/x/icons/16.png", 128: "/x/icons/128.png"]
		)
		expectNoDifference(ChromiumExtension.iconSizes(sizedExtension.actionIcons), [32: "/x/action/32.png"])

		let tooMany = Dictionary(uniqueKeysWithValues: (1...17).map { ("\($0)", "/x/\($0).png") })
		let invalid: [[String: String]] = [
			["0": "/x/0.png"],
			["032": "/x/32.png"],
			["-16": "/x/16.png"],
			["4097": "/x/4097.png"],
			["16px": "/x/16.png"],
			["16": "icons/16.png"],
			["16": "/x/../16.png"],
			tooMany,
		]
		for icons in invalid {
			let manifest = Task { try await fixture.bridge.inspect(profileID: nil) }
			fixture.deliver(await fixture.nextCall(), icons: icons)
			await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await manifest.value }

			let action = Task { try await fixture.bridge.inspect(profileID: nil) }
			fixture.deliver(await fixture.nextCall(), actionIcons: icons)
			await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await action.value }
		}
	}

	/// A component's files live in the engine's resources, so it sends its icon's bytes.
	@Test
	internal func onlyAComponentSendsItsIconAsBoundedBase64() async throws {
		let fixture = ExtensionFixture()
		let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
		let component = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), location: 5, componentIcon: png.base64EncodedString())
		let componentExtension = try #require(try await component.value.extensions.first)
		#expect(componentExtension.componentIconData == png)

		let invalid: [(location: Int, icon: String)] = [
			(4, png.base64EncodedString()),
			(5, "not base64!"),
			(5, ""),
			(5, Data(count: 16 * 1024 + 1).base64EncodedString()),
		]
		for (location, icon) in invalid {
			let task = Task { try await fixture.bridge.inspect(profileID: nil) }
			fixture.deliver(await fixture.nextCall(), location: location, componentIcon: icon)
			await #expect(throws: ChromiumExtensionFailure.invalidResponse) { try await task.value }
		}
	}

	@Test(arguments: [ARX_EXTENSION_POLICY_BLOCKED, ARX_EXTENSION_REVIEW_REQUIRED, ARX_EXTENSION_TIMEOUT, ARX_EXTENSION_BUSY])
	internal func preservesNativeFailure(_ status: ArxExtensionStatus) async throws {
		let fixture = ExtensionFixture()
		let task = Task { try await fixture.bridge.inspect(profileID: nil) }
		fixture.deliver(await fixture.nextCall(), status: status)
		await #expect(throws: ChromiumExtensionFailure(status: status)) { try await task.value }
	}
}

@MainActor
private final class ExtensionFixture {
	fileprivate static let extensionID: String = String(repeating: "a", count: 32)
	fileprivate static var calls: [Call] = []
	fileprivate static var cancelled: [UInt64] = []
	fileprivate let bridge: ChromiumExtensions

	fileprivate init(
		enabled: Bool = true,
		unpacked: Bool = true
	) {
		Self.calls = []
		Self.cancelled = []
		var api = ArxEngineAPI()
		api.inspect_extensions = { key, id in
			MainActor.assumeIsolated {
				ExtensionFixture.calls.append(.init(
					id: id,
					key: String(cString: key!),
					revision: 0,
					action: ARX_EXTENSION_INSPECT
				))
			}
		}
		api.manage_extension = { key, id, revision, _, action in
			MainActor.assumeIsolated {
				ExtensionFixture.calls.append(.init(
					id: id,
					key: String(cString: key!),
					revision: revision,
					action: action
				))
			}
		}
		api.extension_views_available = { true }
		api.open_extension_view = { key, id, revision, _, kind, source, generation in
			MainActor.assumeIsolated {
				#expect(kind == ARX_EXTENSION_VIEW_OPTIONS)
				#expect(source == 0 && generation == 0)
				ExtensionFixture.calls.append(.init(
					id: id,
					key: String(cString: key!),
					revision: revision,
					action: ARX_EXTENSION_INSPECT
				))
			}
		}
		api.cancel_extension_request = { id in
			MainActor.assumeIsolated { ExtensionFixture.cancelled.append(id) }
		}
		if unpacked {
			api.unpacked_extensions_available = { true }
		}
		api.load_unpacked_extension = { key, id, revision, directory in
			MainActor.assumeIsolated {
				ExtensionFixture.calls.append(.init(
					id: id,
					key: String(cString: key!),
					revision: revision,
					action: ARX_EXTENSION_INSPECT,
					directory: String(cString: directory!)
				))
			}
		}
		self.bridge = .init(api: api)
		bridge.configure(enabled: enabled, fixture: false)
	}

	fileprivate func nextCall() async -> Call {
		while Self.calls.isEmpty { await Task.yield() }
		return Self.calls.removeFirst()
	}

	fileprivate func deliver(
		_ request: Call,
		key: String? = nil,
		state: String = "enabled",
		reasons: [Int] = [],
		revision: UInt64 = 1,
		forceEnable: Bool? = nil,
		hasOptions: Bool = false,
		location: Int = 4,
		canReload: Bool? = nil,
		sourcePath: String? = nil,
		iconPath: String? = nil,
		icons: [String: String]? = nil,
		actionIcons: [String: String]? = nil,
		componentIcon: String? = nil,
		allowedInPrivate: Bool? = nil,
		canAllowInPrivate: Bool? = nil,
		status: ArxExtensionStatus = ARX_EXTENSION_SUCCESS
	) {
		let permissions: [String: Any] = ["apis": ["storage"], "hosts": ["http://127.0.0.1/*"]]
		var extension_: [String: Any] = [
			"id": Self.extensionID,
			"name": "Fixture",
			"version": "1.0",
			"manifestVersion": 3,
			"location": location,
			"fromWebStore": false,
			"state": state,
			"disableReasons": reasons,
			"permissionsIncreased": reasons.contains(2),
			"isFixture": true,
			"canEnable": forceEnable ?? (state == "disabled" && reasons == [1]),
			"canDisable": state == "enabled",
			"canRemove": true,
			"canOpenOptions": hasOptions,
			"requiredPermissions": permissions,
			"optionalPermissions": permissions,
			"activePermissions": permissions,
			"withheldPermissions": permissions,
		]
		if let canReload { extension_["canReload"] = canReload }
		if let sourcePath { extension_["sourcePath"] = sourcePath }
		if let iconPath { extension_["iconPath"] = iconPath }
		if let icons { extension_["icons"] = icons }
		if let actionIcons { extension_["actionIcons"] = actionIcons }
		if let componentIcon { extension_["componentIcon"] = componentIcon }
		if let allowedInPrivate { extension_["allowedInPrivate"] = allowedInPrivate }
		if let canAllowInPrivate { extension_["canAllowInPrivate"] = canAllowInPrivate }
		let data = try! JSONSerialization.data(withJSONObject: ["extensions": [extension_]])
		data.withUnsafeBytes { bytes in
			bridge.complete(
				request.id,
				profileKey: key ?? request.key,
				status: status,
				revision: revision,
				bytes: bytes.bindMemory(to: UInt8.self).baseAddress,
				count: bytes.count
			)
		}
	}

	fileprivate func fail(
		_ request: Call,
		status: ArxExtensionStatus,
		error: String? = nil
	) {
		let data = try! error.map { try JSONSerialization.data(withJSONObject: ["error": $0]) } ?? Data()
		data.withUnsafeBytes { bytes in
			bridge.complete(
				request.id,
				profileKey: request.key,
				status: status,
				revision: 0,
				bytes: bytes.bindMemory(to: UInt8.self).baseAddress,
				count: bytes.count
			)
		}
	}

	fileprivate struct Call {
		internal let id: UInt64
		internal let key: String
		internal let revision: UInt64
		internal let action: ArxExtensionAction
		internal var directory: String?

		internal init(
			id: UInt64,
			key: String,
			revision: UInt64,
			action: ArxExtensionAction,
			directory: String? = nil
		) {
			self.id = id
			self.key = key
			self.revision = revision
			self.action = action
			self.directory = directory
		}
	}
}
