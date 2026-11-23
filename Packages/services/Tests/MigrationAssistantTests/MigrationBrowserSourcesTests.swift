import BrowserCore
import CustomDump
import Foundation
import Testing
import _TestSupport
@testable import MigrationAssistant

/// Fixtures are made up, shaped like the real files. No browser data is committed.
internal struct MigrationBrowserSourcesTests {
	private static let arcSidebar: String = """
	{"sidebar": {"containers": [{"global": {}}, {
		"topAppsContainerIDs": [{"default": true}, "top-default", {"custom": {"_0": {"directoryBasename": "Profile 1", "machineID": "m"}}}, "top-work"],
		"spaces": ["s1", {
			"id": "s1", "title": "Home",
			"profile": {"default": true},
			"customInfo": {"iconType": {"icon": "🏠"}},
			"containerIDs": ["pinned", "s1-pinned", "unpinned", "s1-open"]
		}, "s2", {
			"id": "s2", "title": "Job",
			"profile": {"custom": {"_0": {"directoryBasename": "Profile 1", "machineID": "m"}}},
			"customInfo": {"iconType": {"icon": "briefcase"}},
			"containerIDs": ["pinned", "s2-pinned", "unpinned", "s2-open"]
		}, "s3", {
			"id": "s3", "title": "Empty",
			"profile": {"default": true},
			"containerIDs": ["pinned", "s3-pinned"]
		}],
		"items": [
			"top-default", {"id": "top-default", "data": {"itemContainer": {}}, "childrenIds": ["fav"]},
			"fav", {"id": "fav", "data": {"tab": {"savedTitle": "Mail", "savedURL": "https://mail.example.org"}}, "childrenIds": []},
			"top-work", {"id": "top-work", "data": {"itemContainer": {}}, "childrenIds": []},
			"s1-pinned", {"id": "s1-pinned", "data": {"itemContainer": {}}, "childrenIds": ["folder", "same", "easel", "note", "welcome", "empty"]},
			"folder", {"id": "folder", "title": "Reading", "data": {"list": {}}, "childrenIds": ["inner", "same-again"]},
			"inner", {"id": "inner", "title": "Renamed", "data": {"tab": {"savedTitle": "Swift", "savedURL": "https://swift.org"}}, "childrenIds": []},
			"same", {"id": "same", "data": {"tab": {"savedTitle": "One", "savedURL": "https://repeat.example.org"}}, "childrenIds": []},
			"same-again", {"id": "same-again", "data": {"tab": {"savedTitle": "Two", "savedURL": "https://repeat.example.org"}}, "childrenIds": []},
			"easel", {"id": "easel", "data": {"easel": {}}, "childrenIds": []},
			"note", {"id": "note", "data": {"arcDocument": {}}, "childrenIds": []},
			"welcome", {"id": "welcome", "data": {"welcomeToArc": {}}, "childrenIds": []},
			"empty", {"id": "empty", "title": "Nothing", "data": {"list": {}}, "childrenIds": []},
			"s1-open", {"id": "s1-open", "data": {"itemContainer": {}}, "childrenIds": ["split"]},
			"split", {"id": "split", "data": {"splitView": {}}, "childrenIds": ["left", "right"]},
			"left", {"id": "left", "data": {"tab": {"savedTitle": "Left", "savedURL": "https://left.example.org"}}, "childrenIds": []},
			"right", {"id": "right", "data": {"tab": {"savedTitle": "Right", "savedURL": "https://right.example.org"}}, "childrenIds": []},
			"s2-pinned", {"id": "s2-pinned", "data": {"itemContainer": {}}, "childrenIds": ["job"]},
			"job", {"id": "job", "data": {"tab": {"savedTitle": "Tracker", "savedURL": "https://tracker.example.org"}}, "childrenIds": []},
			"s2-open", {"id": "s2-open", "data": {"itemContainer": {}}, "childrenIds": []},
			"s3-pinned", {"id": "s3-pinned", "data": {"itemContainer": {}}, "childrenIds": []}
		]
	}]}}
	"""

	private static let localState: String = """
	{"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 1": {"name": "Work"}}}}
	"""

	private static let chromeBookmarks: String = """
	{"roots": {
		"bookmark_bar": {"name": "Bookmarks bar", "type": "folder", "children": [
			{"type": "url", "guid": "g1", "name": "Swift", "url": "https://swift.org"},
			{"type": "folder", "guid": "g2", "name": "Docs", "children": [
				{"type": "url", "guid": "g3", "name": "Apple", "url": "https://developer.apple.com"}
			]},
			{"type": "folder", "guid": "g4", "name": "Blank", "children": []}
		]},
		"other": {"name": "Other bookmarks", "type": "folder", "children": [
			{"type": "url", "guid": "g5", "name": "News", "url": "https://news.example.org"}
		]},
		"synced": {"name": "Mobile bookmarks", "type": "folder", "children": []}
	}}
	"""

	@Test
	internal func arcsSystemProfileIsLeftOut() throws {
		// Arc keeps a profile of its own named __ARC_SYSTEM_PROFILE; it isn't the user's.
		let localState = """
		{"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 1": {"name": "__ARC_SYSTEM_PROFILE"}}}}
		"""
		expectNoDifference(
			try MigrationBrowserSources.chromiumProfiles(Data(localState.utf8)).map(\.name),
			["Personal"]
		)
		let snapshot = try ArcSidebar.snapshot(sidebar: Data(Self.arcSidebar.utf8), localState: Data(localState.utf8))
		expectNoDifference(
			snapshot.records.filter { $0.kind == .space }.compactMap { $0.space?.name },
			["Home", "Empty"]
		)
		#expect(!snapshot.records.contains { $0.sourceItemID == "job" })
	}

	private func arcSnapshot() throws -> MigrationSnapshot {
		try ArcSidebar.snapshot(sidebar: Data(Self.arcSidebar.utf8), localState: Data(Self.localState.utf8))
	}

	@Test
	internal func arcKeepsProfilesSpacesFoldersAndCategories() throws {
		let snapshot = try arcSnapshot()

		let tabs = snapshot.records.filter { $0.kind == .tab }
		expectNoDifference(tabs.map(\.sourceItemID), [
			"fav", "inner", "same-again", "same", "left", "right", "job",
		])
		expectNoDifference(tabs.map(\.category), [
			.favorites, .bookmarks, .bookmarks, .bookmarks, .openTabs, .openTabs, .bookmarks,
		])
		expectNoDifference(tabs[0].profile?.name, "Personal")
		let inner = tabs[1]
		expectNoDifference(inner.title, "Renamed")
		expectNoDifference(inner.folders.map(\.name), ["Reading"])
		expectNoDifference(inner.space?.name, "Home")
		expectNoDifference(inner.space?.icon, "🏠")
		expectNoDifference(inner.space?.profile.name, "Personal")
		expectNoDifference(tabs[6].space?.profile.name, "Work")
		expectNoDifference(snapshot.issues.map(\.reason), [
			.unsupported(.easel), .unsupported(.note), .unsupported(.onboardingItem),
		])

		// Empty folders and spaces come through as records of their own.
		expectNoDifference(
			snapshot.records.filter { $0.kind == .folder }.map { $0.folders.last?.name },
			["Nothing"]
		)
		expectNoDifference(
			snapshot.records.filter { $0.kind == .space }.compactMap { $0.space?.name },
			["Home", "Job", "Empty"]
		)
	}

	@Test
	internal func theSnapshotIDFollowsTheContentNotTheFile() throws {
		let first = try arcSnapshot()
		let reformatted = Self.arcSidebar.replacingOccurrences(of: "\n", with: " ")
		let second = try ArcSidebar.snapshot(sidebar: Data(reformatted.utf8), localState: Data(Self.localState.utf8))
		let renamed = Self.arcSidebar.replacingOccurrences(of: "\"Tracker\"", with: "\"Board\"")
		let third = try ArcSidebar.snapshot(sidebar: Data(renamed.utf8), localState: Data(Self.localState.utf8))

		expectNoDifference(first.id, second.id)
		#expect(first.id != third.id)
	}

	@Test
	internal func anUnknownArcFileIsUnreadableRatherThanEmpty() {
		#expect(throws: MigrationFailure.self) {
			try ArcSidebar.snapshot(sidebar: Data("{\"sidebar\": {}}".utf8), localState: nil)
		}
	}

	@Test
	internal func discoveredBrowsersCarryTheirAppAndWhenTheyWereLastUsed() throws {
		let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: home) }

		let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
		let sidebar = support.appending(path: "Arc/StorableSidebar.json")
		let localState = support.appending(path: "Google/Chrome/Local State")
		let arcDate: Date = .init(timeIntervalSince1970: 1_800_000_000)
		let chromeDate: Date = .init(timeIntervalSince1970: 1_700_000_000)
		for (file, date) in [(sidebar, arcDate), (localState, chromeDate)] {
			try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data("{}".utf8).write(to: file)
			try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path(percentEncoded: false))
		}

		let sources = MigrationBrowserSources.adapters(home: home).map(\.source)
		expectNoDifference(sources.map(\.id.rawValue), ["arc", "chrome"])
		expectNoDifference(sources.map(\.applicationIdentifier), ["company.thebrowser.Browser", "com.google.Chrome"])
		expectNoDifference(sources.map(\.lastUsed), [arcDate, chromeDate])
	}

	@Test
	internal func uncheckedSourcesAreOfferedUnlessTheDefaultTurnsThemOff() throws {
		let suite = "MigrationBrowserSourcesTests." + UUID().uuidString
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(MigrationBrowserSources.offersUncheckedSources(in: defaults))
		defaults.set(false, forKey: "MigrationUncheckedSources")
		#expect(!MigrationBrowserSources.offersUncheckedSources(in: defaults))
		defaults.set(true, forKey: "MigrationUncheckedSources")
		#expect(MigrationBrowserSources.offersUncheckedSources(in: defaults))
	}

	@Test
	internal func safariIsAlwaysListedAsUnsupportedAndFirefoxOnlyWhenItsFolderExists() throws {
		let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: home) }

		expectNoDifference(MigrationBrowserSources.unsupportedBrowsers(home: home).map(\.id), ["safari"])

		let firefox = home.appending(path: "Library/Application Support/Firefox", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: firefox, withIntermediateDirectories: true)
		expectNoDifference(MigrationBrowserSources.unsupportedBrowsers(home: home).map(\.id), ["safari", "firefox"])
	}

	@Test
	internal func chromiumReadsEachProfilesBookmarks() throws {
		let snapshot = try ChromiumBookmarks.snapshot(browser: "chrome", localState: Data(Self.localState.utf8)) { directory in
			directory == "Default" ? Data(Self.chromeBookmarks.utf8) : nil
		}

		let tabs = snapshot.records.filter { $0.kind == .tab }
		expectNoDifference(tabs.map(\.title), ["Swift", "Apple", "News"])
		expectNoDifference(tabs.map { $0.folders.map(\.name) }, [[], ["Docs"], ["Other bookmarks"]])
		expectNoDifference(Set(tabs.compactMap { $0.space?.name }), ["Personal"])
		expectNoDifference(snapshot.records.filter { $0.kind == .folder }.map { $0.folders.last?.name }, ["Blank"])
	}

	@Test
	internal func newProfilesRecreateTheOrganizationAndARetryAddsNothing() async throws {
		let destination = FixtureDestination()
		let snapshot = try arcSnapshot()
		let adapter = MigrationSourceAdapter(source: Self.arc) { snapshot }
		let client = MigrationAssistantClient.running(adapters: [adapter], writer: destination.writer)
		var target = MigrationFixtures.destination
		target.defaultRoute = .newProfile

		let preview = try await client.inspect(Self.arc.id, [.favorites, .bookmarks, .openTabs], target)
		expectNoDifference(preview.spaces.map(\.name), ["Home", "Job", "Empty"])
		let plan = MigrationPlan(id: .init(rawValue: UUID()), preview: preview)
		let report = try await finished(client.execute(plan))
		expectNoDifference(report.outcome, .completed)

		let organization = destination.organization.value
		try organization.validate()
		expectNoDifference(organization.profiles.map(\.name), ["Default", "Personal", "Work"])
		expectNoDifference(organization.spaces.map(\.name), ["Home", "Home", "Job", "Empty"])
		let home = organization.spaces[1]
		expectNoDifference(home.icon?.rawValue, "🏠")
		expectNoDifference(organization.spaces[2].icon, nil)
		expectNoDifference(home.profileID, organization.profiles[1].id)
		expectNoDifference(home.unpinnedTabs.count, 2)
		expectNoDifference(organization.profiles[1].favorites.count, 1)

		// The space holds the folders and the tab directly, with no wrapper folder.
		expectNoDifference(home.savedItems.count, 3)
		expectNoDifference(organization.folders.map(\.name), ["Reading", "Nothing"])

		// The URL repeated in two places stays in both.
		expectNoDifference(
			organization.tabs.filter { $0.reopeningURL.absoluteString == "https://repeat.example.org" }.count,
			2
		)

		let before = destination.organization.value
		let again = try await finished(client.execute(plan))
		expectNoDifference(again.importedCount, 0)
		expectNoDifference(destination.organization.value, before)
	}

	@Test
	internal func routesSendSpacesToChosenPlacesAndKeepThemTogether() async throws {
		let destination = FixtureDestination()
		let snapshot = try arcSnapshot()
		let adapter = MigrationSourceAdapter(source: Self.arc) { snapshot }
		let client = MigrationAssistantClient.running(adapters: [adapter], writer: destination.writer)
		var target = MigrationFixtures.destination
		target.routes = [
			"Default/s1": .existingSpace(MigrationFixtures.profileID, MigrationFixtures.spaceID),
			"Profile 1/s2": .newSpace(MigrationFixtures.profileID),
		]
		target.defaultRoute = .newProfile

		let preview = try await client.inspect(Self.arc.id, [.favorites, .bookmarks, .openTabs], target)
		let report = try await finished(client.execute(.init(id: .init(rawValue: UUID()), preview: preview)))
		expectNoDifference(report.outcome, .completed)

		let organization = destination.organization.value
		try organization.validate()
		expectNoDifference(organization.profiles.map(\.name), ["Default", "Personal"])
		expectNoDifference(organization.spaces.map(\.name), ["Home", "Job", "Empty"])
		let existing = organization.spaces[0]
		let wrapper = try #require(organization.folders.first { $0.name == "Home" })
		expectNoDifference(existing.savedItems, [.folder(wrapper.id)])

		// Favorites follow the explicit route of their profile's space.
		expectNoDifference(organization.profiles[0].favorites.count, 1)
	}

	@Test
	internal func eachSourceProfileGoesWhereItsMappingSays() async throws {
		let destination = FixtureDestination()
		let snapshot = try arcSnapshot()
		let client = MigrationAssistantClient.running(
			adapters: [.init(source: Self.arc) { snapshot }],
			writer: destination.writer
		)
		var target = MigrationFixtures.destination
		target.defaultRoute = .newProfile
		target.profileRoutes = [
			"Default": .newProfile(name: "  Home Life "),
			"Profile 1": .existingProfile(MigrationFixtures.profileID),
		]

		let preview = try await client.inspect(Self.arc.id, [.favorites, .bookmarks, .openTabs], target)
		expectNoDifference(preview.profiles.map(\.id), ["Default", "Profile 1"])
		expectNoDifference(preview.profiles.map(\.name), ["Personal", "Work"])
		let report = try await finished(client.execute(.init(id: .init(rawValue: UUID()), preview: preview)))
		expectNoDifference(report.outcome, .completed)

		let organization = destination.organization.value
		try organization.validate()

		// The new profile takes the name the user gave it; Work joins the existing profile.
		expectNoDifference(organization.profiles.map(\.name), ["Default", "Home Life"])
		let homeLife = organization.profiles[1].id
		let job = try #require(organization.spaces.first { $0.name == "Job" })
		expectNoDifference(job.profileID, MigrationFixtures.profileID)
		let home = try #require(organization.spaces.last { $0.name == "Home" })
		expectNoDifference(home.profileID, homeLife)
		expectNoDifference(organization.profiles[1].favorites.count, 1)

		// Passwords follow the same mapping.
		let personal = await client.receivingProfile("Default", target)
		let work = await client.receivingProfile("Profile 1", target)
		expectNoDifference(personal?.id, homeLife)
		expectNoDifference(work?.id, MigrationFixtures.profileID)

		// A rename after the profile exists doesn't rename it or make another.
		target.profileRoutes["Default"] = .newProfile(name: "Elsewhere")
		let again = try await client.inspect(Self.arc.id, [.favorites, .bookmarks, .openTabs], target)
		_ = try await finished(client.execute(.init(id: .init(rawValue: UUID()), preview: again)))
		expectNoDifference(destination.organization.value.profiles.map(\.name), ["Default", "Home Life"])
	}

	@Test
	internal func aPasswordsOnlyRunStillMakesTheMappedProfiles() async throws {
		let destination = FixtureDestination()
		let snapshot = try arcSnapshot()
		let client = MigrationAssistantClient.running(
			adapters: [.init(source: Self.arc) { snapshot }],
			writer: destination.writer
		)
		var target = MigrationFixtures.destination
		target.defaultRoute = .newProfile
		target.profileRoutes = [
			"Default": .newProfile(name: "Home Life"),
			"Profile 1": .existingProfile(MigrationFixtures.profileID),
		]

		let preview = try await client.inspect(Self.arc.id, [], target)
		var plan = MigrationPlan(id: .init(rawValue: UUID()), preview: preview)
		expectNoDifference(plan.categories, [])
		plan.profiles = preview.profiles
		let report = try await finished(client.execute(plan))
		expectNoDifference(report.outcome, .completed)

		// Only the profile mapped to a new one is made, with its name and nothing in it.
		let organization = destination.organization.value
		try organization.validate()
		expectNoDifference(organization.profiles.map(\.name), ["Default", "Home Life"])
		expectNoDifference(organization.spaces.count, 1)
		let personal = await client.receivingProfile("Default", target)
		expectNoDifference(personal?.id, organization.profiles[1].id)

		// Running it again reuses it.
		_ = try await finished(client.execute(plan))
		expectNoDifference(destination.organization.value.profiles.count, 2)
	}

	@Test
	internal func aCancelWhileTheProfilesAreMadeCancelsAPasswordsOnlyRun() async throws {
		let destination = FixtureDestination()
		let snapshot = try arcSnapshot()
		let client: LockIsolated<MigrationAssistantClient?> = .init(nil)
		let planID: MigrationPlan.ID = .init(rawValue: UUID())
		let fixture = destination.writer
		let writer = MigrationDestinationWriter(
			state: fixture.state,
			commit: { batch in

				// The user cancels while the profile batch commits.
				await client.value?.cancel(planID)
				try await fixture.commit(batch)
			}
		)
		client.setValue(.running(adapters: [.init(source: Self.arc) { snapshot }], writer: writer))
		var target = MigrationFixtures.destination
		target.defaultRoute = .newProfile

		let running = try #require(client.value)
		let preview = try await running.inspect(Self.arc.id, [], target)
		var plan = MigrationPlan(id: planID, preview: preview)
		plan.profiles = preview.profiles
		let report = try await finished(running.execute(plan))
		expectNoDifference(report.outcome, .cancelled)
	}

	@Test
	internal func aCancelBeforeTheProfilesAreMadeWritesNothing() async throws {
		let destination = FixtureDestination()
		let snapshot = try arcSnapshot()
		let client: LockIsolated<MigrationAssistantClient?> = .init(nil)
		let planID: MigrationPlan.ID = .init(rawValue: UUID())
		let fixture = destination.writer
		let commits: LockIsolated<Int> = .init(0)
		let isExecuting: LockIsolated<Bool> = .init(false)
		let writer = MigrationDestinationWriter(
			state: {
				// The user cancels while the run reads the destination, before any write.
				if isExecuting.value { await client.value?.cancel(planID) }
				return try await fixture.state()
			},
			commit: { batch in
				commits.withValue { $0 += 1 }
				try await fixture.commit(batch)
			}
		)
		client.setValue(.running(adapters: [.init(source: Self.arc) { snapshot }], writer: writer))
		var target = MigrationFixtures.destination
		target.defaultRoute = .newProfile

		let running = try #require(client.value)
		let preview = try await running.inspect(Self.arc.id, [], target)
		var plan = MigrationPlan(id: planID, preview: preview)
		plan.profiles = preview.profiles
		isExecuting.setValue(true)
		let report = try await finished(running.execute(plan))
		expectNoDifference(report.outcome, .cancelled)
		expectNoDifference(commits.value, 0)
	}

	@Test
	internal func aMappingToAMissingProfileIsRefused() async throws {
		let destination = FixtureDestination()
		let snapshot = try arcSnapshot()
		let client = MigrationAssistantClient.running(
			adapters: [.init(source: Self.arc) { snapshot }],
			writer: destination.writer
		)
		var target = MigrationFixtures.destination
		target.profileRoutes = ["Default": .existingProfile(.init(rawValue: UUID()))]

		await #expect(throws: MigrationFailure.invalidDestination) {
			try await client.inspect(Self.arc.id, [.bookmarks], target)
		}
	}

	@Test
	internal func aRouteToAMissingSpaceIsRefused() async throws {
		let destination = FixtureDestination()
		let snapshot = try arcSnapshot()
		let client = MigrationAssistantClient.running(
			adapters: [.init(source: Self.arc) { snapshot }],
			writer: destination.writer
		)
		var target = MigrationFixtures.destination
		target.routes = ["Default/s1": .existingSpace(MigrationFixtures.profileID, .init(rawValue: UUID()))]

		await #expect(throws: MigrationFailure.invalidDestination) {
			try await client.inspect(Self.arc.id, [.bookmarks], target)
		}
	}

	/// Reads the real file when asked to, and prints only counts.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_MIGRATION_REAL_ARC"] != nil))
	internal func theRealArcFileParses() throws {
		let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Arc")
		let snapshot = try ArcSidebar.snapshot(
			sidebar: Data(contentsOf: root.appending(path: "StorableSidebar.json")),
			localState: try? Data(contentsOf: root.appending(path: "User Data/Local State"))
		)
		let destination = FixtureDestination()
		var ledger = MigrationLedger()
		let target = MigrationDestination(
			profileID: MigrationFixtures.profileID,
			spaceID: MigrationFixtures.spaceID,
			defaultRoute: .newProfile
		)
		var organization = destination.organization.value
		var ids = 1_000
		for category in MigrationCategory.allCases {
			let items = snapshot.records.filter { $0.category == category }.compactMap {
				try? $0.validated(from: Self.arc.id).get()
			}
			organization = try organization.applyingMigration(
				.init(
					planID: .init(rawValue: UUID()),
					destination: target,
					sourceName: "Arc",
					category: category,
					items: items
				),
				ledger: &ledger
			) {
				ids += 1
				return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ids))!
			}
			let recordCount = snapshot.records.filter { $0.category == category }.count
			print("ARX_REAL_ARC \(category.rawValue) records=\(recordCount) valid=\(items.count)")
		}
		print(
			"ARX_REAL_ARC profiles=\(organization.profiles.count - 1)"
			+ " spaces=\(organization.spaces.count - 1)"
			+ " folders=\(organization.folders.count)"
			+ " issues=\(snapshot.issues.count)"
		)
		#expect(!snapshot.records.isEmpty)
	}

	private static let arc: MigrationSource = .init(
		id: .init(rawValue: "arc"),
		kind: .externalBrowser,
		name: "Arc",
		categories: [.favorites, .bookmarks, .openTabs],
		preservesOrganization: true
	)

	private func finished(
		_ stream: AsyncThrowingStream<MigrationEvent, any Error>
	) async throws -> MigrationReport {
		var report: MigrationReport?
		for try await event in stream {
			if case let .finished(value) = event { report = value }
		}
		return try #require(report)
	}
}
