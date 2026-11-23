import BrowserCore
import BrowserWorkspaceClient
import ConcurrencyExtras
import Dependencies
import Foundation
import Sharing
import Testing
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct WorkspacePreferenceKeyTests {
	// MARK: - One snapshot

	@Test
	internal func preferenceKeysAndOrganizationShareOneSnapshot() async throws {
		let world: World = try .init()

		try await withDependencies {
			$0.workspaceDocument = world.document
		} operation: {
			@Shared(.workspacePreference(\.chromeAppearance))
			var appearance

			@Shared(.workspacePreference(\.searchShortcuts))
			var shortcuts

			$appearance.withLock { $0.tint.hue = 120 }
			$shortcuts.withLock { $0.removeAll() }
			var organization = world.organization
			organization.spaces[0].appearance = .init(tintHue: 30)
			world.document.update(organization: organization)

			try await world.document.flush()
		}

		let saved = try world.reload()
		#expect(saved.preferences.chromeTint.hue == 120)
		#expect(saved.preferences.searchShortcuts.isEmpty)
		#expect(saved.organization?.spaces[0].appearance?.tintHue == 30)
	}

	@Test
	internal func editsNeverWriteUntilFlushed() async throws {
		let world: World = try .init()

		try await withDependencies {
			$0.workspaceDocument = world.document
		} operation: {
			@Shared(.workspacePreference(\.chromeAppearance))
			var appearance

			for hue in stride(from: 0.0, to: 50, by: 1) {
				$appearance.withLock { $0.tint.hue = hue }
			}
			#expect(world.writes.value == 0)

			try await $appearance.save()
		}

		#expect(world.writes.value == 1)
		#expect(try world.reload().preferences.chromeTint.hue == 49)
	}

	// MARK: - Save requests

	@Test
	internal func onlyPreferenceEditsThatRequestSavingYieldChanges() async throws {
		let world: World = try .init()
		let document = world.document

		let quiet = document.changes()
		var organization = world.organization
		organization.spaces[0].name = "Renamed"
		document.update(organization: organization)
		document.updatePreferences(requestsSave: false) { $0.grainEnabled = false }
		#expect(await quiet.yields(within: .milliseconds(50)) == false)

		let requested = document.changes()
		withDependencies {
			$0.workspaceDocument = document
		} operation: {
			@Shared(.workspacePreference(\.chromeAppearance))
			var appearance

			$appearance.withLock { $0.tint.hue = 200 }
		}
		#expect(await requested.yields(within: .seconds(5)))
	}

	// MARK: - Observation

	@Test
	internal func keysForOtherDomainsAreNotInvalidated() async throws {
		let world: World = try .init()
		let routingYields: LockIsolated<Int> = .init(0)
		let document = world.document
		let stop = document.observe(origin: nil) { old, new in
			if old.preferences.routing != new.preferences.routing {
				routingYields.withValue { $0 += 1 }
			}
		}
		defer { stop() }

		withDependencies {
			$0.workspaceDocument = document
		} operation: {
			@Shared(.workspacePreference(\.chromeAppearance))
			var appearance

			@SharedReader(.workspacePreference(\.routing))
			var routing

			@SharedReader(.workspacePreference(\.self))
			var everything

			$appearance.withLock { $0.grain.isEnabled = false }

			#expect(everything.grainEnabled == false)
			#expect(routing == RoutingPreferences())
		}
		#expect(routingYields.value == 0)
	}

	@Test
	internal func aCommitChangesTheOrganizationAndPreferencesInOneNotification() async throws {
		let world: World = try .init()
		let seen: LockIsolated<[WorkspaceDocument.Snapshot]> = .init([])
		let stop = world.document.observe(origin: nil) { _, new in seen.withValue { $0.append(new) } }
		defer { stop() }
		let changes = world.document.changes()

		var organization = world.organization
		organization.spaces[0].name = "Imported"
		var preferences = BrowserPreferences()
		preferences.migrationLedger.importedItems["arx-archive"] = ["digest"]
		world.document.update(organization: organization, preferences: preferences)

		// One notification carries both, so no reader sees the ledger without the organization.
		#expect(seen.value == [.init(organization: organization, preferences: preferences)])
		// The commit saves itself.
		#expect(await changes.yields(within: .milliseconds(50)) == false)
	}

	@Test
	internal func documentEditsReachEveryReader() async throws {
		let world: World = try .init()

		withDependencies {
			$0.workspaceDocument = world.document
		} operation: {
			@SharedReader(.workspacePreference(\.chromeAppearance))
			var appearance

			// What an archive import or migration commit does.
			world.document.updatePreferences { $0.chromeTint = .init(hue: 10, intensity: 0.5) }

			#expect(appearance.tint == .init(hue: 10, intensity: 0.5))
		}
	}
}

// MARK: - World

@MainActor
private final class World {
	internal let directory: URL
	internal let client: BrowserWorkspaceClient
	internal let document: WorkspaceDocument
	internal let organization: BrowserOrganization
	internal let writes: LockIsolated<Int> = .init(0)

	internal init() throws {
		self.directory = FileManager.default.temporaryDirectory
			.appending(component: "WorkspacePreferenceKeyTests-\(UUID().uuidString)")
		let profile: Profile = .init(id: .init(rawValue: UUID()), name: "Personal")
		self.organization = .init(
			profiles: [profile],
			spaces: [.init(id: .init(rawValue: UUID()), profileID: profile.id, name: "Home")]
		)
		let writes = writes
		self.client = .init(
			file: directory.appending(component: "workspace.json"),
			write: { data, url in
				if url.lastPathComponent == "workspace.json" { writes.withValue { $0 += 1 } }
				try data.write(to: url, options: .atomic)
			}
		)
		self.document = .init(
			client: client,
			organization: organization,
			preferences: .init()
		)
	}

	deinit {
		try? FileManager.default.removeItem(at: directory)
	}

	internal func reload() throws -> BrowserWorkspaceClient.Recovery {
		try BrowserWorkspaceClient(file: directory.appending(component: "workspace.json")).loadWithRecovery()
	}
}

extension AsyncStream where Element == Void {
	/// Whether an element arrives within `duration`. Consumes the stream.
	fileprivate func yields(within duration: Duration) async -> Bool {
		await withTaskGroup(of: Bool.self) { group in
			group.addTask {
				for await _ in self { return true }
				return false
			}
			group.addTask {
				try? await Task.sleep(for: duration)
				return false
			}
			let first = await group.next() ?? false
			group.cancelAll()
			return first
		}
	}
}
