import BrowserCore
import Foundation
import Testing

/// DEV-1323: when this Arx was first installed on this Mac, for the identity card's Member since.
internal struct InstallDateTests {
	private let now: Date = .init(timeIntervalSince1970: 1_795_000_000)

	@Test
	internal func aRecordedDateNeverChanges() {
		let recorded: Date = now.addingTimeInterval(-86_400 * 30)
		let resolved: Date = InstallDate.resolved(
			recorded: recorded,
			evidence: [now.addingTimeInterval(-86_400 * 90)],
			now: now
		)
		#expect(resolved == recorded)
	}

	@Test
	internal func aNewInstallIsToday() {
		#expect(InstallDate.resolved(recorded: nil, evidence: [], now: now) == now)
	}

	@Test
	internal func anExistingInstallTakesItsEarliestFolder() {
		let dataFolder: Date = now.addingTimeInterval(-86_400 * 11)
		let profileFolder: Date = now.addingTimeInterval(-86_400 * 10)
		let resolved: Date = InstallDate.resolved(
			recorded: nil,
			evidence: [profileFolder, dataFolder],
			now: now
		)
		#expect(resolved == dataFolder)
	}

	@Test
	internal func evidenceFromTheFutureIsIgnored() {
		let past: Date = now.addingTimeInterval(-60)
		#expect(InstallDate.resolved(recorded: nil, evidence: [now.addingTimeInterval(3_600)], now: now) == now)
		#expect(InstallDate.resolved(recorded: nil, evidence: [now.addingTimeInterval(3_600), past], now: now) == past)
	}

	@Test
	internal func theEvidenceIsTheEditionsOwnDataFolder() {
		let home: URL = .init(filePath: "/Users/someone", directoryHint: .isDirectory)
		let folders: [String] = InstallDate.evidenceFolders(edition: .development, home: home)
			.map { $0.path(percentEncoded: false) }
		#expect(folders == [
			"/Users/someone/Library/Application Support/dev.capturecontext.arx.dev/",
			"/Users/someone/Library/Application Support/dev.capturecontext.arx.dev/Browser/",
		])

		// Arx Preview names its own data folder, so its date is its own too.
		let preview: ArxEdition = ArxEdition.release.naming(from: [ArxEdition.InfoKey.dataFolder: "dev.capturecontext.arx.preview"])
		#expect(InstallDate.evidenceFolders(edition: preview, home: home).first?.lastPathComponent == "dev.capturecontext.arx.preview")
	}

	@Test
	internal func creationDatesReadOnlyFoldersThatExist() throws {
		let folder: URL = .temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }

		let created: Date = .init(timeIntervalSince1970: 1_700_000_000)
		try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: folder.path(percentEncoded: false))

		let dates: [Date] = InstallDate.creationDates(of: [folder, folder.appending(path: "missing")])
		#expect(dates == [created])
	}

	@Test
	internal func preferencesKeepTheDateAndOlderSavesHaveNone() throws {
		var preferences = BrowserPreferences()
		preferences.installedAt = now
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		#expect(decoded.installedAt == now)

		var values = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
		#expect(values.removeValue(forKey: "installedAt") != nil)
		let older = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: values))
		#expect(older.installedAt == nil)

		values["installedAt"] = "not a date"
		let damaged = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: values))
		#expect(damaged.installedAt == nil)
	}

	// MARK: - The server's day (DEV-1323)

	@Test
	internal func theCardShowsTheAccountsDayOnceItHasOne() throws {
		let installed: Date = now
		#expect(InstallDate.shown(member: nil, installedAt: installed) == installed)
		#expect(InstallDate.shown(member: nil, installedAt: nil) == nil)

		// A server or a saved number from before DEV-1323: this Mac's date.
		let older: MemberNumber = .init(index: 42, registeredOn: "2026-11-18", provider: .apple)
		#expect(InstallDate.shown(member: older, installedAt: installed) == installed)

		let synced: MemberNumber = .init(index: 42, registeredOn: "2026-11-18", provider: .apple, memberSince: "2026-11-02")
		let shown = try #require(InstallDate.shown(member: synced, installedAt: installed))
		let parts = Calendar.current.dateComponents([.year, .month, .day], from: shown)
		#expect(parts == DateComponents(year: 2026, month: 11, day: 2))
	}

	@Test
	internal func aMalformedServerDayIsNoDay() {
		for text in ["2026-11-1", "2026-02-30", "11/02/2026", "", "2026-11-02T00:00:00Z"] {
			let number: MemberNumber = .init(index: 1, registeredOn: "2026-11-18", provider: .apple, memberSince: text)
			#expect(number.memberSinceDate == nil, "\(text)")
		}
	}

	@Test
	internal func theInstallDayIsTheDayOnThisMac() throws {
		// 23:30 on 10 November in Los Angeles is already the 11th in UTC.
		let date: Date = .init(timeIntervalSince1970: 1_794_382_200)
		#expect(InstallDate.dayText(date, timeZone: try #require(TimeZone(identifier: "America/Los_Angeles"))) == "2026-11-10")
		#expect(InstallDate.dayText(date, timeZone: .gmt) == "2026-11-11")
	}

	@Test
	internal func aSavedNumberFromBeforeHasNoDay() throws {
		let older = Data(#"{"idx":42,"registeredOn":"2026-11-18","provider":"apple"}"#.utf8)
		let number = try JSONDecoder().decode(MemberNumber.self, from: older)
		#expect(number.memberSince == nil)

		let synced: MemberNumber = .init(index: 42, registeredOn: "2026-11-18", provider: .apple, memberSince: "2026-11-02")
		#expect(try JSONDecoder().decode(MemberNumber.self, from: JSONEncoder().encode(synced)) == synced)
	}
}
