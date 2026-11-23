import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Darwin
import Foundation
import Testing
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func retirementIdentityIsStableAndNeverExportedOrAdoptedByAnotherRoot() async throws {
		let directory = try retirementTemporaryRoot()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = Profile.ID(rawValue: UUID(1))
		let first = try BrowserProfileRetirementStore(
			root: directory,
			legacyProfileID: legacy,
			uuid: { UUID(99) }
		)
		let second = try BrowserProfileRetirementStore(
			root: directory,
			legacyProfileID: legacy,
			uuid: { UUID(3) }
		)
		expectNoDifference(first.installationID, second.installationID)
		expectNoDifference(first.installationID, UUID(99))
		#expect(throws: (any Error).self) {
			try BrowserProfileRetirementStore(root: directory, legacyProfileID: .init(rawValue: UUID(4)))
		}
		let copied = directory.appendingPathComponent("copy")
		try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: false)
		try FileManager.default.copyItem(
			at: directory.appendingPathComponent(".arx-installation-v1"),
			to: copied.appendingPathComponent(".arx-installation-v1")
		)
		#expect(throws: (any Error).self) {
			try BrowserProfileRetirementStore(root: copied, legacyProfileID: legacy)
		}
		let export = directory.appendingPathComponent("export.json")
		try BrowserWorkspaceClient(file: directory.appendingPathComponent("workspace.json")).export(
			fixture(),
			to: export
		)
		#expect(
			!String(decoding: try Data(contentsOf: export), as: UTF8.self).contains(first.installationID.uuidString)
		)
	}

	@Test
	internal func retirementIntentSurvivesRestartAndKeepsOriginalRevisionAcrossRetries() async throws {
		let directory = try retirementTemporaryRoot()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = Profile.ID(rawValue: UUID(1))
		let intent = ProfileRetirementIntent(
			profileID: legacy,
			profileName: "Default",
			requestID: UUID(2),
			expectedRevision: 12
		)
		let first = try BrowserProfileRetirementStore(root: directory, legacyProfileID: legacy)
		try first.record(intent)
		let second = try BrowserProfileRetirementStore(root: directory, legacyProfileID: legacy)
		expectNoDifference(try second.load(), [intent])
		var retry = intent
		retry.attemptRevision = 20
		try second.record(retry)
		expectNoDifference(try first.load().first?.expectedRevision, 12)
		expectNoDifference(try first.load().first?.attemptRevision, 20)
		try first.acknowledge(intent.requestID)
		expectNoDifference(try second.load().first?.acknowledged, true)
		#expect(throws: (any Error).self) { try first.record(retry) }
		let info = try FileManager.default.attributesOfItem(
			atPath: directory.appendingPathComponent(".arx-installation-v1").path
		)
		expectNoDifference((info[.posixPermissions] as? NSNumber)?.intValue, 0o600)
	}

	@Test
	internal func interruptedIdentityAndMissingIntentCannotManufactureAuthority() async throws {
		let directory = try retirementTemporaryRoot()
		defer { try? FileManager.default.removeItem(at: directory) }
		let path = directory.appendingPathComponent(".arx-installation-v1")
		let truncated = Data("partial".utf8)
		try truncated.write(to: path)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
		#expect(throws: (any Error).self) {
			try BrowserProfileRetirementStore(root: directory, legacyProfileID: .init(rawValue: UUID(1)))
		}
		expectNoDifference(try Data(contentsOf: path), truncated)
		expectNoDifference(
			BrowserProfileRetirementStore.permitsOrdinaryBrowsingAfterInitializationFailure(root: directory),
			true
		)
		try FileManager.default.removeItem(at: path)
		let store = try BrowserProfileRetirementStore(root: directory, legacyProfileID: .init(rawValue: UUID(1)))
		try FileManager.default.removeItem(
			at: directory.appendingPathComponent(".arx-profile-retirement-intents-v1")
		)
		let journal = directory.appendingPathComponent(".arx-profile-erasure-v1")
		try Data("owned fixture ledger".utf8).write(to: journal)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
		#expect(throws: (any Error).self) {
			try BrowserProfileRetirementStore(root: directory, legacyProfileID: store.legacyProfileID)
		}
		#expect(throws: (any Error).self) { try store.load() }
		expectNoDifference(
			BrowserProfileRetirementStore.permitsOrdinaryBrowsingAfterInitializationFailure(root: directory),
			false
		)
	}

	@Test
	internal func rootReplacementAndFailedPersistencePreservePriorIntent() async throws {
		let outer = try retirementTemporaryRoot()
		defer { try? FileManager.default.removeItem(at: outer) }
		let directory = outer.appendingPathComponent("Browser")
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		let store = try BrowserProfileRetirementStore(root: directory, legacyProfileID: .init(rawValue: UUID(1)))
		let intent = ProfileRetirementIntent(
			profileID: .init(rawValue: UUID(1)),
			profileName: "Default",
			requestID: UUID(2),
			expectedRevision: 12
		)
		try store.record(intent)
		try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
		#expect(throws: (any Error).self) { try store.acknowledge(intent.requestID) }
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
		expectNoDifference(try store.load(), [intent])
		try FileManager.default.moveItem(at: directory, to: outer.appendingPathComponent("old"))
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		#expect(throws: (any Error).self) { try store.record(intent) }
	}

	@Test
	internal func acknowledgedRetirementOverridesBackupAndCannotReuseProfileID() async throws {
		var organization = fixture()
		let target = Profile.ID(rawValue: UUID(9))
		organization.profiles.append(.init(id: target, name: "Retired"))
		let retired = try organization.excludingRetiredProfiles([target])
		expectNoDifference(retired.retiredProfileIDs, [target])
		#expect(throws: (any Error).self) {
			try retired.applying(.createProfile(target, name: "Restored"), uuid: { UUID(10) })
		}
		let recovered = try organization.excludingRetiredProfiles(retired.retiredProfileIDs)
		expectNoDifference(recovered.profiles.ids.contains(target), false)
		#expect(throws: (any Error).self) {
			try organization.excludingRetiredProfiles(Set(organization.profiles.map(\.id)))
		}
	}

	@Test
	internal func renumberedDeviceMigratesVersionOneIdentityButReplacedRootDoesNot() async throws {
		let directory = try retirementTemporaryRoot()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = Profile.ID(rawValue: UUID(1))
		let intent = ProfileRetirementIntent(
			profileID: legacy,
			profileName: "Default",
			requestID: UUID(2),
			expectedRevision: 12
		)
		let first = try BrowserProfileRetirementStore(root: directory, legacyProfileID: legacy, uuid: { UUID(99) })
		try first.record(intent)
		let identityFile = directory.appendingPathComponent(".arx-installation-v1")
		let current = try #require(
			JSONSerialization.jsonObject(with: Data(contentsOf: identityFile)) as? [String: Any]
		)
		expectNoDifference(current["version"] as? Int, 2)
		#expect(current["device"] == nil)
		#expect(current["volume"] is String)

		// Version 1 stored st_dev, which macOS renumbers across reboots.
		func writeVersionOne(inode: Any) throws {
			var stale = current
			stale["version"] = 1
			stale["volume"] = nil
			stale["device"] = 16_777_231
			stale["inode"] = inode
			try JSONSerialization.data(withJSONObject: stale, options: [.sortedKeys]).write(to: identityFile)
			try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityFile.path)
		}
		try writeVersionOne(inode: current["inode"]!)
		let migrated = try BrowserProfileRetirementStore(root: directory, legacyProfileID: legacy, uuid: { UUID(3) })
		expectNoDifference(migrated.installationID, UUID(99))
		expectNoDifference(try migrated.load(), [intent])
		let rewritten = try #require(
			JSONSerialization.jsonObject(with: Data(contentsOf: identityFile)) as? [String: Any]
		)
		expectNoDifference(rewritten["version"] as? Int, 2)
		expectNoDifference(rewritten["volume"] as? String, current["volume"] as? String)
		#expect(rewritten["device"] == nil)

		try writeVersionOne(inode: ((current["inode"] as? NSNumber)?.uint64Value ?? 0) + 1)
		#expect(throws: BrowserProfileRetirementStore.Failure.ownershipChanged) {
			try BrowserProfileRetirementStore(root: directory, legacyProfileID: legacy)
		}
	}

	private func retirementTemporaryRoot() throws -> URL {
		let directory = URL.temporaryDirectory.appendingPathComponent("arx-retirement-owned-" + UUID().uuidString)
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		return directory.resolvingSymlinksInPath()
	}
}
