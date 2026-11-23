import CustomDump
import Foundation
import Testing
@testable import MigrationAssistant

/// Session files are written by `SessionFileWriter`, which follows Chromium 156's
/// `SessionCommand::SerializeAsCleartext`, the payload structs in
/// `session_service_commands.cc` and `SerializedNavigationEntry::WriteToPickle`.
/// No real browser's session file is read.
internal struct ChromiumSessionTests {
	@Test
	internal func normalWindowsKeepTheirTabsInVisualOrder() throws {
		var file: SessionFileWriter = .init()

		// Window 1, opened first: two tabs, the second moved before the first.
		file.windowType(1, type: 0)
		file.tab(10, window: 1, index: 1)
		file.navigation(tab: 10, index: 0, url: "https://first.example.org", title: "First")
		file.tab(11, window: 1, index: 0)
		file.navigation(tab: 11, index: 0, url: "https://second.example.org", title: "Second 🙂")
		file.pinned(11)

		// A popup isn't imported.
		file.windowType(2, type: 1)
		file.tab(20, window: 2, index: 0)
		file.navigation(tab: 20, index: 0, url: "https://popup.example.org", title: "Popup")

		// Window 3: a closed tab, and one that went back in its history.
		file.windowType(3, type: 0)
		file.tab(30, window: 3, index: 0)
		file.navigation(tab: 30, index: 0, url: "https://closed.example.org", title: "Closed")
		file.closeTab(30)
		file.tab(31, window: 3, index: 1)
		file.navigation(tab: 31, index: 0, url: "https://back.example.org", title: "Back")
		file.navigation(tab: 31, index: 1, url: "https://forward.example.org", title: "Forward")
		file.selectedNavigation(tab: 31, index: 0)

		// Window 4 was closed with its tab.
		file.windowType(4, type: 0)
		file.tab(40, window: 4, index: 0)
		file.navigation(tab: 40, index: 0, url: "https://gone.example.org", title: "Gone")
		file.closeWindow(4)

		// A window whose type was never set stays "constrained" and isn't restored.
		file.tab(50, window: 5, index: 0)
		file.navigation(tab: 50, index: 0, url: "https://constrained.example.org", title: "Constrained")

		let windows = try ChromiumSession.windows(file.data)

		expectNoDifference(windows, [
			[
				.init(url: "https://second.example.org", title: "Second 🙂", isPinned: true),
				.init(url: "https://first.example.org", title: "First"),
			],
			[.init(url: "https://back.example.org", title: "Back")],
		])
	}

	@Test
	internal func navigationUpdatesReplaceAndPrunedEntriesMoveTheSelection() throws {
		var file: SessionFileWriter = .init()
		file.windowType(1, type: 0)
		file.tab(10, window: 1, index: 0)
		file.navigation(tab: 10, index: 0, url: "https://a.example.org", title: "A")
		file.navigation(tab: 10, index: 1, url: "https://b.example.org", title: "B")
		file.navigation(tab: 10, index: 1, url: "https://b.example.org/updated", title: "B, updated")
		file.navigation(tab: 10, index: 2, url: "https://c.example.org", title: "C")
		file.selectedNavigation(tab: 10, index: 2)

		// Removing entry 2 selects entry 1, as Chromium does.
		file.pruned(tab: 10, index: 2, count: 1)
		file.tab(11, window: 1, index: 1)
		file.navigation(tab: 11, index: 0, url: "https://x.example.org", title: "X")
		file.navigation(tab: 11, index: 1, url: "https://y.example.org", title: "Y")
		file.selectedNavigation(tab: 11, index: 1)
		file.prunedFromBack(tab: 11, index: 1)

		let windows = try ChromiumSession.windows(file.data)

		expectNoDifference(windows.joined().map(\.url), ["https://b.example.org/updated", "https://x.example.org"])
	}

	@Test
	internal func aPrunedRangePastInt32IsIgnored() throws {
		var file: SessionFileWriter = .init()
		file.windowType(1, type: 0)
		file.tab(10, window: 1, index: 0)
		file.navigation(tab: 10, index: 0, url: "https://kept.example.org", title: "Kept")
		file.pruned(tab: 10, index: .max, count: 1)

		expectNoDifference(try ChromiumSession.windows(file.data).joined().map(\.url), ["https://kept.example.org"])
	}

	@Test
	internal func aTruncatedLastCommandIsIgnored() throws {
		var file: SessionFileWriter = .init()
		file.windowType(1, type: 0)
		file.tab(10, window: 1, index: 0)
		file.navigation(tab: 10, index: 0, url: "https://kept.example.org", title: "Kept")
		file.navigation(tab: 10, index: 1, url: "https://lost.example.org", title: "Lost")
		file.selectedNavigation(tab: 10, index: 1)
		expectNoDifference(try ChromiumSession.windows(file.data).joined().map(\.url), ["https://lost.example.org"])

		// Losing the selection, then half of the second navigation, leaves the first page.
		let withoutSelection = try ChromiumSession.windows(Data(file.data.dropLast(3)))
		expectNoDifference(withoutSelection.joined().map(\.url), ["https://kept.example.org"])
		let withoutNavigation = try ChromiumSession.windows(Data(file.data.dropLast(20)))
		expectNoDifference(withoutNavigation.joined().map(\.url), ["https://kept.example.org"])
	}

	@Test
	internal func encryptedAndUnknownFilesAreRefused() {
		var encrypted = SessionFileWriter(version: ChromiumSession.encryptedVersion)
		encrypted.windowType(1, type: 0)
		#expect(throws: MigrationFailure.self) { try ChromiumSession.windows(encrypted.data) }
		#expect(throws: MigrationFailure.self) { try ChromiumSession.windows(Data("not a session".utf8)) }
	}

	@Test
	internal func theNewestCompleteSessionFileIsRead() throws {
		let profile = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		defer { try? FileManager.default.removeItem(at: profile) }

		let sessions = profile.appending(path: "Sessions", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
		func session(
			_ url: String,
			marked: Bool = true
		) -> Data {
			var file: SessionFileWriter = .init()
			file.windowType(1, type: 0)
			file.tab(1, window: 1, index: 0)
			file.navigation(tab: 1, index: 0, url: url, title: url)
			if marked { file.marker() }
			return file.data
		}
		let files: [String: Data] = [
			"Session_13400000000000000": session("https://older.example.org"),
			"Session_13400000000000005": session("https://complete.example.org"),
			// Cut short while Chromium rewrote it: no initial-state marker.
			"Session_13400000000000009": session("https://partial.example.org", marked: false),
			"Tabs_13400000000000010": session("https://tabs.example.org"),
			"Session_x": session("https://unnamed.example.org"),
		]
		for (name, data) in files {
			try data.write(to: sessions.appending(path: name))
		}

		let data = try #require(ChromiumSession.latestSession(in: profile))
		expectNoDifference(try ChromiumSession.windows(data).joined().map(\.url), ["https://complete.example.org"])
	}

	@Test
	internal func pruningMovesLaterEntriesBack() throws {
		var file: SessionFileWriter = .init()
		file.windowType(1, type: 0)
		file.tab(10, window: 1, index: 0)
		for (index, page) in ["a", "b", "c"].enumerated() {
			file.navigation(tab: 10, index: Int32(index), url: "https://\(page).example.org", title: page)
		}
		file.selectedNavigation(tab: 10, index: 2)

		// Removing A leaves B and C at 0 and 1, with C still selected.
		file.pruned(tab: 10, index: 0, count: 1)
		file.tab(11, window: 1, index: 1)
		for (index, page) in ["x", "y", "z"].enumerated() {
			file.navigation(tab: 11, index: Int32(index), url: "https://\(page).example.org", title: page)
		}
		file.selectedNavigation(tab: 11, index: 2)
		file.pruned(tab: 11, index: 1, count: 1)

		// A later update at the new index replaces Z rather than landing after it.
		file.navigation(tab: 11, index: 1, url: "https://z.example.org/updated", title: "z, updated")

		let windows = try ChromiumSession.windows(file.data)

		expectNoDifference(windows.joined().map(\.url), ["https://c.example.org", "https://z.example.org/updated"])
	}

	@Test
	internal func openTabsJoinTheProfilesSpaceAndAreKnownByURLAndOccurrence() throws {
		var file: SessionFileWriter = .init()
		file.windowType(1, type: 0)
		for (tab, url) in [(1, "https://a.example.org"), (2, "https://b.example.org"), (3, "https://a.example.org")] {
			file.tab(Int32(tab), window: 1, index: Int32(tab))
			file.navigation(tab: Int32(tab), index: 0, url: url, title: "Tab \(tab)")
		}
		let localState = Data(#"{"profile": {"info_cache": {"Default": {"name": "Personal"}}}}"#.utf8)

		let snapshot = try ChromiumBookmarks.snapshot(
			browser: "chrome",
			localState: localState,
			bookmarks: { _ in nil },
			session: { _ in file.data }
		)

		let tabs = snapshot.records.filter { $0.kind == .tab }
		expectNoDifference(tabs.map(\.sourceItemID), [
			"Default/open/https://a.example.org#0",
			"Default/open/https://b.example.org#0",
			"Default/open/https://a.example.org#1",
		])
		expectNoDifference(Set(tabs.map(\.category)), [.openTabs])
		expectNoDifference(Set(tabs.compactMap { $0.space?.name }), ["Personal"])
		expectNoDifference(snapshot.records.filter { $0.kind == .space }.count, 1)
	}
}

// MARK: - Writer

/// Writes a cleartext Chromium session file, command by command.
internal struct SessionFileWriter {
	internal private(set) var data: Data = .init()

	internal init(version: Int32 = ChromiumSession.version) {
		append(ChromiumSession.signature)
		append(UInt32(bitPattern: version))
	}

	internal mutating func windowType(
		_ window: Int32,
		type: Int32
	) {
		command(.setWindowType, Self.ints(window, type))
	}

	internal mutating func tab(
		_ tab: Int32,
		window: Int32,
		index: Int32
	) {
		command(.setTabWindow, Self.ints(window, tab))
		command(.setTabIndexInWindow, Self.ints(tab, index))
	}

	internal mutating func selectedNavigation(
		tab: Int32,
		index: Int32
	) {
		command(.setSelectedNavigationIndex, Self.ints(tab, index))
	}

	internal mutating func pinned(_ tab: Int32) {
		// struct { int32 tab_id; bool pinned_state; } with three bytes of padding.
		command(.setPinnedState, Self.ints(tab) + Data([1, 0, 0, 0]))
	}

	internal mutating func closeTab(_ tab: Int32) {
		command(.tabClosed, Self.ints(tab, 0, 0, 0))
	}

	internal mutating func closeWindow(_ window: Int32) {
		command(.windowClosed, Self.ints(window, 0, 0, 0))
	}

	internal mutating func pruned(
		tab: Int32,
		index: Int32,
		count: Int32
	) {
		command(.tabNavigationPathPruned, Self.ints(tab, index, count))
	}

	/// Command 255, which ends the initial state of a complete file.
	internal mutating func marker() {
		var size = UInt16(1).littleEndian
		withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
		data.append(ChromiumSession.initialStateMarker)
	}

	internal mutating func prunedFromBack(
		tab: Int32,
		index: Int32
	) {
		command(.tabNavigationPathPrunedFromBack, Self.ints(tab, index))
	}

	/// `kCommandUpdateTabNavigation`: a pickle of the tab ID and the navigation entry.
	internal mutating func navigation(
		tab: Int32,
		index: Int32,
		url: String,
		title: String
	) {
		var pickle: Data = .init()
		pickle += Self.ints(tab, index)
		pickle += Self.string(Data(url.utf8), count: url.utf8.count)
		pickle += Self.string(
			Data(title.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
			count: title.utf16.count
		)
		pickle += Self.string(Data(), count: 0) // page state
		pickle += Self.ints(0, 0) // transition type, type mask
		pickle += Self.string(Data(), count: 0) // referrer
		pickle += Self.ints(0) // obsolete referrer policy
		command(.updateTabNavigation, Self.ints(Int32(pickle.count)) + pickle)
	}

	private mutating func command(
		_ id: ChromiumSession.Command,
		_ contents: Data
	) {
		var size = UInt16(contents.count + 1).littleEndian
		withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
		data.append(id.rawValue)
		data.append(contents)
	}

	private mutating func append(_ value: UInt32) {
		withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
	}

	private static func ints(_ values: Int32...) -> Data {
		var data: Data = .init()
		for value in values {
			withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
		}
		return data
	}

	private static func string(
		_ bytes: Data,
		count: Int
	) -> Data {
		ints(Int32(count)) + bytes + Data(count: (4 - bytes.count % 4) % 4)
	}
}
