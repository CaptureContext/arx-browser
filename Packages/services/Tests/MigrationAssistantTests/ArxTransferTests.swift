import BrowserCore
import CustomDump
import Foundation
import Testing
import _TestSupport
@testable import MigrationAssistant

internal struct ArxTransferTests {
	private static func id(_ value: Int) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
	}

	/// Nested and empty folders, an empty space, Unicode, repeated URLs, a pinned tab that has
	/// moved away from its saved URL, and icons chosen for a Favorite, a pin and an open tab
	/// (DEV-1251).
	private static func source() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: id(1))
		let second = Profile.ID(rawValue: id(2))
		let space = Space.ID(rawValue: id(3))
		func tab(
			_ number: Int,
			_ title: String,
			_ url: String,
			saved: Bool = true,
			current: String? = nil,
			custom: String? = nil,
			icon: SpaceIcon? = nil,
			profile owner: Profile.ID = profile
		) -> BrowserCore.Tab {
			let address = URL(string: url)!
			return .init(
				id: .init(rawValue: id(number)),
				profileID: owner,
				savedDestination: saved ? .init(title: title, url: address) : nil,
				restoration: .init(title: current == nil ? title : "Moved", url: current.flatMap(URL.init(string:)) ?? address),
				customTitle: custom,
				icon: icon
			)
		}
		let inner = Folder.ID(rawValue: id(10))
		let outer = Folder.ID(rawValue: id(11))
		let empty = Folder.ID(rawValue: id(12))
		return .init(
			profiles: [
				.init(id: profile, name: "Žluťoučký 🦊", favorites: [.init(rawValue: id(20))], searchEngine: .duckDuckGo),
				.init(id: second, name: "Empty profile"),
			],
			spaces: [
				.init(
					id: space,
					profileID: profile,
					name: "家",
					icon: .house,
					appearance: .init(theme: .dark),
					savedItems: [.tab(.init(rawValue: id(21))), .folder(outer), .folder(empty), .tab(.init(rawValue: id(22)))],
					unpinnedTabs: [.init(rawValue: id(23)), .init(rawValue: id(24))]
				),
				.init(id: .init(rawValue: id(4)), profileID: profile, name: "Nothing here"),
			],
			folders: [
				.init(id: outer, spaceID: space, name: "Outer", children: [.folder(inner)], isExpanded: false),
				.init(id: inner, spaceID: space, name: "Inner", children: [.tab(.init(rawValue: id(25)))]),
				.init(id: empty, spaceID: space, name: "Empty"),
			],
			tabs: [
				tab(20, "Mail", "https://mail.example.org", icon: .init(emoji: "📬")),
				tab(21, "Saved", "https://saved.example.org", current: "https://moved.example.org/page", custom: "My name", icon: .star),
				tab(22, "Twice", "https://repeat.example.org"),
				tab(23, "Regular", "https://regular.example.org", saved: false, icon: .leaf),
				tab(24, "Regular twice", "https://repeat.example.org", saved: false),
				tab(25, "Deep ✨ & <odd>", "https://repeat.example.org"),
			]
		)
	}

	private static func clean() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: id(90))
		return .init(
			profiles: [.init(id: profile, name: "Fresh")],
			spaces: [.init(id: .init(rawValue: id(91)), profileID: profile, name: "Start")]
		)
	}

	private static let destination: MigrationDestination = .init(
		profileID: .init(rawValue: id(90)),
		spaceID: .init(rawValue: id(91)),
		defaultRoute: .newProfile
	)

	private func file(
		_ data: Data,
		name: String = "Archive.json"
	) throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appending(path: name)
		try data.write(to: url)
		return url
	}

	private func archiveFile(
		_ organization: BrowserOrganization = source(),
		preferences: BrowserPreferences = .init()
	) throws -> URL {
		let archive = ArxTransferArchive(
			organization: organization,
			preferences: preferences,
			createdAt: Date(timeIntervalSince1970: 1_000),
			appVersion: "1.0"
		)
		return try file(try archive.encoded())
	}

	private func run(
		_ url: URL,
		into destination: FixtureDestination,
		target: MigrationDestination = destination
	) async throws -> MigrationReport {
		let client = MigrationAssistantClient.running(adapters: [], writer: destination.writer)
		let source = try await client.addFile(url)
		let preview = try await client.inspect(source.id, source.categories, target)
		var report: MigrationReport?
		for try await event in client.execute(.init(id: .init(rawValue: UUID()), preview: preview)) {
			if case let .finished(value) = event { report = value }
		}
		return try #require(report)
	}

	/// A comparable outline, since IDs differ between the two browsers.
	private func outline(of organization: BrowserOrganization) -> [String] {
		func title(_ id: BrowserCore.Tab.ID) -> String {
			let tab = organization.tabs[id: id]!
			return [
				tab.customTitle ?? "-",
				tab.icon.map { String(describing: $0) } ?? "-",
				tab.savedDestination?.title ?? "-",
				tab.savedDestination?.url.absoluteString ?? "-",
				tab.restoration.title,
				tab.restoration.url.absoluteString,
			].joined(separator: "|")
		}

		func lines(
			_ items: [SavedItem],
			_ prefix: String
		) -> [String] {
			items.flatMap { item -> [String] in
				switch item {
				case let .tab(id):
					return [prefix + title(id)]

				case let .folder(id):
					let folder = organization.folders[id: id]!
					return ["\(prefix)[\(folder.name) \(folder.isExpanded)]"] + lines(folder.children, prefix + "  ")
				}
			}
		}
		return organization.profiles.flatMap { profile -> [String] in
			["P \(profile.name) \(String(describing: profile.searchEngine)) \(String(describing: profile.appearance))"]
			+ profile.favorites.map { "F " + title($0) }
			+ organization.spaces.filter { $0.profileID == profile.id }.flatMap { space -> [String] in
				["S \(space.name) \(space.icon?.rawValue ?? "-") \(String(describing: space.appearance))"]
				+ lines(space.savedItems, "  ")
				+ space.unpinnedTabs.map { "R " + title($0) }
			}
		}
	}

	@Test
	internal func anArchiveRoundTripsIntoACleanBrowser() async throws {
		let destination = FixtureDestination(Self.clean())
		let report = try await run(try archiveFile(), into: destination)

		expectNoDifference(report.outcome, .completed)
		let imported = destination.organization.value
		try imported.validate()
		expectNoDifference(
			Array(outline(of: imported).dropFirst(2)),
			outline(of: Self.source())
		)
	}

	@Test
	internal func importingTheSameOrANewerArchiveAddsOnlyWhatsNew() async throws {
		let destination = FixtureDestination(Self.clean())
		_ = try await run(try archiveFile(), into: destination)
		let before = destination.organization.value

		let again = try await run(try archiveFile(), into: destination)
		expectNoDifference(again.importedCount, 0)
		expectNoDifference(destination.organization.value, before)

		var newer = Self.source()
		let added = BrowserCore.Tab(
			id: .init(rawValue: Self.id(30)),
			profileID: newer.profiles[0].id,
			restoration: .init(title: "New", url: URL(string: "https://new.example.org")!)
		)
		newer.tabs.append(added)
		newer.spaces[0].unpinnedTabs.append(added.id)
		let more = try await run(try archiveFile(newer), into: destination)
		expectNoDifference(more.importedCount, 1)
		expectNoDifference(destination.organization.value.tabs.count, before.tabs.count + 1)
	}

	@Test
	internal func aFailedCategoryChangesNothingAndCanBeRetried() async throws {
		let destination = FixtureDestination(Self.clean())
		destination.failures.setValue([.openTabs: 1])
		let url = try archiveFile()

		let first = try await run(url, into: destination)
		expectNoDifference(first.outcome, .partiallyCompleted)
		expectNoDifference(first.retryableCategories, [.openTabs])
		#expect(destination.organization.value.spaces.allSatisfy { $0.unpinnedTabs.isEmpty })

		let retry = try await run(url, into: destination)
		expectNoDifference(retry.outcome, .completed)
		expectNoDifference(
			Array(outline(of: destination.organization.value).dropFirst(2)),
			outline(of: Self.source())
		)
	}

	@Test
	internal func theArchiveCanGoIntoAnExistingSpace() async throws {
		let destination = FixtureDestination(Self.clean())
		var target = Self.destination
		target.defaultRoute = nil

		let report = try await run(try archiveFile(), into: destination, target: target)

		expectNoDifference(report.outcome, .completed)
		let organization = destination.organization.value
		try organization.validate()
		expectNoDifference(organization.spaces.map(\.name), ["Start"])
		expectNoDifference(organization.profiles.map(\.name), ["Fresh"])
		expectNoDifference(organization.folders.first?.name, "家")
	}

	@Test
	internal func preferencesMergeOnceAndKeepWhatsHere() throws {
		var exported = BrowserPreferences()
		exported.grainIntensity = 0.5
		let added = SearchShortcut(name: "Other", keyword: "other", template: "https://example.org/?q={query}")
		exported.searchShortcuts.append(added)
		var local = BrowserPreferences()
		let mine = SearchShortcut(name: "Mine", keyword: "mine", template: "https://example.com/?q={query}")
		local.searchShortcuts.append(mine)

		let merged = try local.applyingMigration(.init(exported))

		expectNoDifference(merged.grainIntensity, 0.5)
		#expect(merged.searchShortcuts.contains { $0.keyword == "mine" })
		#expect(merged.searchShortcuts.contains { $0.keyword == "other" })
		expectNoDifference(
			merged.searchShortcuts.filter { $0.keyword == "other" }.count,
			1
		)
	}

	@Test
	internal func preferencesAreOfferedOnceAndRecorded() async throws {
		let destination = FixtureDestination(Self.clean())
		var preferences = BrowserPreferences()
		preferences.grainIntensity = 0.5
		let url = try archiveFile(preferences: preferences)

		let first = try await run(url, into: destination)
		expectNoDifference(first.categories.last?.category, .preferences)
		expectNoDifference(first.categories.last?.imported.count, 1)
		expectNoDifference(destination.commits.value.last?.preferences?.grainIntensity, 0.5)

		let again = try await run(url, into: destination)
		expectNoDifference(again.importedCount, 0)
	}

	@Test
	internal func unsupportedAndDamagedFilesAreRefusedBeforeAnythingChanges() async throws {
		let destination = FixtureDestination(Self.clean())
		let client = MigrationAssistantClient.running(adapters: [], writer: destination.writer)

		let newer = #"{"format": "dev.capturecontext.arx.transfer", "version": 3}"#
		await #expect(throws: MigrationFailure.unsupportedVersion(3)) {
			try await client.addFile(try file(Data(newer.utf8)))
		}
		let damaged = #"{"format": "dev.capturecontext.arx.transfer", "version": 1, "profiles": 3}"#
		await #expect(throws: MigrationFailure.invalidFile) {
			try await client.addFile(try file(Data(damaged.utf8)))
		}
		await #expect(throws: MigrationFailure.invalidFile) {
			try await client.addFile(try file(Data("{\"other\": true}".utf8)))
		}
		await #expect(throws: MigrationFailure.fileTooLarge) {
			let url = try file(Data())
			let handle = try FileHandle(forWritingTo: url)
			try handle.truncate(atOffset: UInt64(ArxTransferArchive.maximumSize + 1))
			try handle.close()
			return try await client.addFile(url)
		}
		expectNoDifference(destination.organization.value, Self.clean())
	}

	@Test
	internal func theArchiveHoldsNoSecretsOrLocalState() throws {
		var preferences = BrowserPreferences()
		preferences.automation = .init(isEnabled: true, clients: [.init(
			id: Self.id(70),
			name: "Agent",
			credentialDigest: "DIGEST",
			grantRevision: Self.id(71)
		)])
		preferences.windowPresentations = [.init(id: Self.id(72), activeSpaceID: .init(rawValue: Self.id(3)), spaces: [])]
		let archive = ArxTransferArchive(
			organization: Self.source(),
			preferences: preferences,
			createdAt: .now,
			appVersion: nil
		)
		let text = String(decoding: try archive.encoded(), as: UTF8.self)

		#expect(!text.contains("DIGEST"))
		#expect(!text.contains("credential"))
		#expect(!text.contains("windowPresentations"))
		#expect(!text.contains("migrationLedger"))
	}

	// MARK: - Bookmarks HTML

	/// Shaped like Chromium's export: a toolbar folder and uppercase tags.
	private static let chromeStyle: String = """
	<!DOCTYPE NETSCAPE-Bookmark-file-1>
	<!-- This is an automatically generated file.
	     It will be read and overwritten.
	     DO NOT EDIT! -->
	<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
	<TITLE>Bookmarks</TITLE>
	<H1>Bookmarks</H1>
	<DL><p>
	    <DT><H3 ADD_DATE="1" LAST_MODIFIED="2" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
	    <DL><p>
	        <DT><A HREF="https://swift.org/" ADD_DATE="1" ICON="data:image/png;base64,AAAA">Swift &amp; friends</A>
	        <DT><H3 ADD_DATE="1">Docs</H3>
	        <DL><p>
	            <DT><A HREF="https://developer.apple.com/?a=1&amp;b=2" ADD_DATE="1">Apple</A>
	            <DT><A HREF="https://developer.apple.com/?a=1&amp;b=2" ADD_DATE="1">Apple again</A>
	        </DL><p>
	        <DT><H3>Nothing</H3>
	        <DL><p>
	        </DL><p>
	    </DL><p>
	    <DT><A HREF="javascript:alert(1)">Script</A>
	</DL><p>
	"""

	/// Shaped like Firefox's export: lowercase, descriptions and separators.
	private static let firefoxStyle: String = """
	<!DOCTYPE NETSCAPE-Bookmark-file-1>
	<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
	<title>Bookmarks</title>
	<h1>Bookmarks Menu</h1>
	<dl><p>
	    <dt><h3 add_date="1">Reading 📚</h3>
	    <dd>A description
	    <dl><p>
	        <dt><a href='https://example.org/caf%C3%A9' add_date="1">Caf&#233; &#x1F980;</a>
	        <hr>
	        <dt><a href="place:type=6&amp;sort=14">Recent</a>
	    </dl><p>
	</dl>
	"""

	private func bookmarks(_ html: String) throws -> MigrationSnapshot {
		let profile = MigrationSourceProfile(id: "html", name: "Bookmarks")
		return try BookmarksHTML.snapshot(
			html: html,
			space: .init(id: "html/x", name: "Bookmarks", profile: profile)
		)
	}

	@Test
	internal func chromeStyleBookmarksKeepFoldersRepeatsAndEmptyFolders() throws {
		let snapshot = try bookmarks(Self.chromeStyle)
		let tabs = snapshot.records.filter { $0.kind == .tab }

		expectNoDifference(tabs.map(\.title), ["Swift & friends", "Apple", "Apple again", "Script"])
		expectNoDifference(tabs[1].url, "https://developer.apple.com/?a=1&b=2")
		expectNoDifference(tabs[1].folders.map(\.name), ["Bookmarks bar", "Docs"])
		#expect(tabs[1].sourceItemID != tabs[2].sourceItemID)
		expectNoDifference(tabs[3].folders, [])
		expectNoDifference(snapshot.records.filter { $0.kind == .folder }.map { $0.folders.map(\.name) }, [["Bookmarks bar", "Nothing"]])
		if case .failure = tabs[3].validated(from: .init(rawValue: "x")) {} else {
			Issue.record("A javascript: link must not import.")
		}
	}

	@Test
	internal func firefoxStyleBookmarksDecodeEntitiesAndSkipNonWebLinks() throws {
		let tabs = try bookmarks(Self.firefoxStyle).records.filter { $0.kind == .tab }

		expectNoDifference(tabs.map(\.title), ["Café 🦀", "Recent"])
		expectNoDifference(tabs[0].folders.map(\.name), ["Reading 📚"])
		if case .failure = tabs[1].validated(from: .init(rawValue: "x")) {} else {
			Issue.record("A place: link must not import.")
		}
	}

	@Test
	internal func aFileThatIsntBookmarksIsRefused() {
		#expect(throws: MigrationFailure.invalidFile) {
			try bookmarks("<html><a href='https://example.org'>x</a></html>")
		}
	}

	@Test
	internal func exportedBookmarksReadBackAndSayWhatWasLeftOut() async throws {
		let (html, summary) = BookmarksHTML.export(Self.source())
		expectNoDifference(summary.omittedRegularTabs, 2)
		expectNoDifference(summary.tabs, 4)
		#expect(html.contains("Deep ✨ &amp; &lt;odd&gt;"))

		let tabs = try bookmarks(html).records.filter { $0.kind == .tab }
		expectNoDifference(tabs.map(\.title), ["Mail", "My name", "Deep ✨ & <odd>", "Twice"])
		expectNoDifference(tabs[1].url, "https://saved.example.org")
		expectNoDifference(tabs[2].folders.map(\.name), ["Žluťoučký 🦊", "家", "Outer", "Inner"])

		let destination = FixtureDestination(Self.clean())
		let report = try await run(try file(Data(html.utf8), name: "Exported.html"), into: destination, target: {
			var target = Self.destination
			target.defaultRoute = nil
			return target
		}())
		expectNoDifference(report.outcome, .completed)
		try destination.organization.value.validate()
		expectNoDifference(destination.organization.value.tabs.count, 4)
		expectNoDifference(destination.organization.value.folders.first?.name, "Exported")
	}
}
