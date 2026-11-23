import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct TabArchiveTests {
	@Test
	internal func explicitCrossProfileRestoreCreatesFreshDestinationSessions() async throws {
		var organization = fixture()
		let entries = captured(organization)
		try organization.archiveClosedTabs(entries)
		let destination = organization.spaces[2]
		let restored = try organization.restoringArchive(
			entries.map(\.id),
			to: .init(space: destination),
			uuid: UUID.init
		)

		expectNoDifference(
			restored.tabs.map(\.profileID),
			Array(repeating: destination.profileID, count: entries.count)
		)
		expectNoDifference(restored.tabs.map(\.restoration), entries.map(\.tab.restoration))
		expectNoDifference(restored.spaces[2].unpinnedTabs, restored.tabs.map(\.id))
		expectNoDifference(restored.archive, [])
		#expect(Set(restored.tabs.map(\.id)).isDisjoint(with: entries.map(\.tab.id)))
		expectNoDifference(organization.archive, entries)
	}

	@Test
	internal func implicitRestoreRejectsReassignedSpaceAndReusedTabIdentity() async throws {
		var organization = fixture()
		let entries = captured(organization)
		try organization.archiveClosedTabs(entries)
		organization.spaces[0] = .init(
			id: organization.spaces[0].id,
			profileID: organization.profiles[1].id,
			name: organization.spaces[0].name
		)

		#expect(throws: TabArchiveError.profileMismatch) {
			try organization.restoringArchive(entries.map(\.id), uuid: UUID.init)
		}
		#expect(throws: TabArchiveError.invalidEntry) {
			try organization.restoringArchive(
				entries.map(\.id),
				to: .init(space: organization.spaces[0]),
				uuid: { entries[0].tab.id.rawValue }
			)
		}
		expectNoDifference(organization.archive, entries)
	}

	@Test
	internal func legacySnapshotsDecodeWithoutAnArchive() async throws {
		let original = fixture()
		var object = try #require(
			JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
		)
		object.removeValue(forKey: "archive")
		let decoded = try JSONDecoder().decode(
			BrowserOrganization.self,
			from: JSONSerialization.data(withJSONObject: object)
		)
		expectNoDifference(decoded, original)
	}

	@Test
	internal func archivedGroupRestoresOriginalOrderWithFreshSessionIdentities() async throws {
		var organization = fixture()
		let original = organization
		let entries = captured(organization)
		try organization.archiveClosedTabs(entries)
		expectNoDifference(organization.tabs, [])
		expectNoDifference(organization.archive, entries)
		let restored = try organization.restoringArchive(entries.reversed().map(\.id), uuid: UUID.init)
		expectNoDifference(restored.tabs.map(\.restoration), original.tabs.map(\.restoration))
		expectNoDifference(restored.spaces[0].unpinnedTabs, restored.tabs.map(\.id))
		expectNoDifference(restored.archive, [])

		// A completed transaction cannot be repeated using stale archive identities.
		#expect(throws: TabArchiveError.missingEntry) {
			try restored.restoringArchive(entries.map(\.id), uuid: UUID.init)
		}
	}

	@Test
	internal func archiveRoundTripPreservesOriginWithoutTransferringAnExplicitTabGrant() throws {
		var organization = fixture()
		organization.tabs[0].automationClientID = uuid(70)
		let source = organization.tabs[0]
		let client = AutomationClient(
			id: uuid(70),
			name: "Fixture",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.tab(source.id, profileID: source.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: true,
			grantRevision: uuid(71)
		)
		#expect(AutomationAccess.permitsTab(source.id, client: client, organization: organization))
		let entries = captured(organization)
		try organization.archiveClosedTabs(entries)
		let decoded = try JSONDecoder().decode(
			BrowserOrganization.self,
			from: JSONEncoder().encode(organization)
		)
		expectNoDifference(decoded.archive.first?.tab.automationClientID, client.id)
		let restored = try decoded.restoringArchive(entries.map(\.id), uuid: UUID.init)
		expectNoDifference(restored.tabs[0].automationClientID, client.id)
		expectNoDifference(restored.tabs[1].automationClientID, nil)
		#expect(restored.tabs[0].id != source.id)
		#expect(!AutomationAccess.permitsTab(restored.tabs[0].id, client: client, organization: restored))
	}

	@Test
	internal func renamedAndRemovedSpacesKeepProfileOwnership() async throws {
		var organization = fixture()
		let entries = captured(organization)
		try organization.archiveClosedTabs(entries)
		organization.spaces[0].name = "Renamed"
		let renamed = try organization.restoringArchive(entries.map(\.id), uuid: UUID.init)
		expectNoDifference(renamed.spaces[0].name, "Renamed")
		organization.spaces.removeFirst()
		#expect(throws: TabArchiveError.missingDestination) {
			try organization.restoringArchive(entries.map(\.id), uuid: UUID.init)
		}
		let fallback = try organization.restoringArchive(
			entries.map(\.id),
			to: .init(space: organization.spaces[0]),
			uuid: UUID.init
		)
		expectNoDifference(fallback.spaces[0].unpinnedTabs, fallback.tabs.map(\.id))
		#expect(throws: TabArchiveError.profileMismatch) {
			try organization.restoringArchive(
				entries.map(\.id),
				to: .init(spaceID: organization.spaces[1].id, profileID: entries[0].tab.profileID),
				uuid: UUID.init
			)
		}
		expectNoDifference(organization.archive, entries)
	}

	@Test
	internal func savedPinsAndStaleCloseDecisionsAreNeverArchived() async throws {
		var organization = fixture()
		let entries = captured(organization)
		let first = organization.tabs[0]
		organization.spaces[0].unpinnedTabs.removeFirst()
		organization.spaces[0].savedItems = [.tab(first.id)]
		organization.tabs[0].savedDestination = .init(title: "Saved", url: first.restoration.url)
		let second = organization.tabs[1]
		organization.spaces[0].unpinnedTabs.removeFirst()
		organization.spaces[1].unpinnedTabs = [second.id]
		let changed = organization
		try organization.archiveClosedTabs(entries)
		expectNoDifference(organization, changed)
		let staleEntries = organization.archiveEntries(
			for: [first.id],
			closedAt: .distantPast,
			groupID: UUID(),
			uuid: UUID.init
		)
		expectNoDifference(staleEntries, [])
	}

	@Test
	internal func corruptArchiveIsRejectedAndSearchMatchesAllTerms() async throws {
		var organization = fixture()
		let entries = captured(organization)
		#expect(entries[0].matches("EXAMPLE Work"))
		#expect(!entries[0].matches("Example absent"))
		organization.archive = [entries[0], entries[0]]
		#expect(throws: TabArchiveError.invalidEntry) { try organization.validate() }
	}

	/// A closed Little Arx page joins its space's archive without moving any tab, and
	/// Recently Closed reopens it as a new unpinned tab at the end (DEV-728).
	@Test
	internal func detachedPagesArchiveWithoutMovingTabsAndRestoreUnpinned() throws {
		var organization = fixture()
		let space = organization.spaces[0]
		let page = Tab(
			id: .init(rawValue: uuid(40)),
			profileID: space.profileID,
			restoration: .init(title: "Little", url: URL(string: "https://little.example/page")!)
		)
		let archived = try organization.archiveDetachedTab(
			page,
			spaceID: space.id,
			closedAt: Date(timeIntervalSince1970: 200),
			groupID: uuid(41),
			id: .init(rawValue: uuid(42))
		)
		#expect(archived)
		expectNoDifference(organization.tabs, fixture().tabs)
		expectNoDifference(organization.spaces, fixture().spaces)
		let entry = try #require(organization.archive.last)
		expectNoDifference(entry.tab, page)
		expectNoDifference(entry.originalSpaceID, space.id)
		expectNoDifference(entry.originalIndex, space.unpinnedTabs.count)

		let restored = try organization.restoringArchive([entry.id], uuid: { self.uuid(43) })
		expectNoDifference(restored.spaces[0].unpinnedTabs.last, .init(rawValue: uuid(43)))
		expectNoDifference(restored.tabs[id: .init(rawValue: uuid(43))]?.restoration, page.restoration)
		expectNoDifference(restored.archive, [])
	}

	@Test
	internal func detachedPagesSkipOtherProfilesMissingSpacesAndNonWebPages() throws {
		var organization = fixture()
		let page = { (profile: Profile.ID, url: String) in
			Tab(
				id: .init(rawValue: self.uuid(40)),
				profileID: profile,
				restoration: .init(title: "Little", url: URL(string: url)!)
			)
		}
		let profile = organization.profiles[0].id
		for (tab, space) in [
			(page(organization.profiles[1].id, "https://little.example"), organization.spaces[0].id),
			(page(profile, "https://little.example"), Space.ID(rawValue: uuid(99))),
			(page(profile, "about:blank"), organization.spaces[0].id),
			(page(profile, "file:///tmp/page.html"), organization.spaces[0].id),
		] {
			let archived = try organization.archiveDetachedTab(
				tab,
				spaceID: space,
				closedAt: Date(timeIntervalSince1970: 200),
				groupID: uuid(41),
				id: .init(rawValue: uuid(42))
			)
			#expect(!archived)
		}
		expectNoDifference(organization, fixture())
	}

	private func captured(_ organization: BrowserOrganization) -> [ArchivedTab] {
		var next: UInt8 = 20
		return organization.archiveEntries(
			for: organization.tabs.reversed().map(\.id),
			closedAt: Date(timeIntervalSince1970: 100),
			groupID: uuid(19),
			uuid: {
				defer { next += 1 }
				return uuid(next)
			}
		)
	}

	private func fixture() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: uuid(1))
		let other = Profile.ID(rawValue: uuid(2))
		let tabs: [Tab] = [10, 11].map {
			.init(
				id: .init(rawValue: uuid($0)),
				profileID: profile,
				restoration: .init(
					title: "Example \($0)",
					url: URL(string: "https://capturecontext.dev/\($0)")!
				)
			)
		}
		return .init(
			profiles: [.init(id: profile, name: "Default"), .init(id: other, name: "Other")],
			spaces: [
				.init(
					id: .init(rawValue: uuid(3)),
					profileID: profile,
					name: "Work",
					unpinnedTabs: tabs.map(\.id)
				),
				.init(id: .init(rawValue: uuid(4)), profileID: profile, name: "Personal"),
				.init(id: .init(rawValue: uuid(5)), profileID: other, name: "Other"),
			],
			tabs: tabs
		)
	}

	private func uuid(_ value: UInt8) -> UUID {
		UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}
}
