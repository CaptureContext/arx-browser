import DiagnosticsClient
import Foundation
import Testing
import _TestSupport

/// Keeping reduced crash reports and problem report files, and the issue page (DEV-887).
internal struct CrashReportStoreTests {
	/// An hour after the fixtures' crash, so they never age past the retention.
	private static let fixtureNow: Date = .init(timeIntervalSince1970: 1_794_560_462 + 3600)

	private static func temporaryStore(now: Date = fixtureNow) throws -> (CrashReportStore, URL) {
		let root: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("arx-diagnostics-\(UUID().uuidString)")
		let locations: CrashReportStore.Locations = .init(
			reports: root.appendingPathComponent("Reports"),
			systemReports: root.appendingPathComponent("DiagnosticReports"),
			engineDatabase: root.appendingPathComponent("Crashpad")
		)
		for folder in [locations.systemReports, locations.engineDatabase.appendingPathComponent("completed")] {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		}
		return (CrashReportStore(locations: locations, now: { now }), root)
	}

	@Test
	internal func collectingKeepsArxCrashesOnceAndLeavesTheRawFiles() throws {
		let (store, root) = try Self.temporaryStore()
		defer { try? FileManager.default.removeItem(at: root) }

		let ips: URL = store.locations.systemReports.appendingPathComponent("Arx-2026-11-13-100102.ips")
		try CrashReportTests.ipsReport().write(to: ips)
		let other: URL = store.locations.systemReports.appendingPathComponent("Safari-2026-11-13-100102.ips")
		try CrashReportTests.ipsReport(bundleID: "com.apple.Safari", name: "Safari").write(to: other)
		let dump: URL = store.locations.engineDatabase.appendingPathComponent("completed/0F3A.dmp")
		try MinidumpFixture.renderer().write(to: dump)

		let entries = store.collect()
		#expect(entries.map(\.report.source).sorted { $0.rawValue < $1.rawValue } == [.engine, .system])
		#expect(FileManager.default.fileExists(atPath: ips.path))
		#expect(FileManager.default.fileExists(atPath: dump.path))

		// Nothing new: nothing added.
		#expect(store.collect().count == 2)

		// Kept reports name no path or URL.
		for file in try FileManager.default.contentsOfDirectory(at: store.locations.reports, includingPropertiesForKeys: nil) {
			let text: String = try String(contentsOf: file, encoding: .utf8)
			#expect(!text.contains("/Users"))
			#expect(!text.contains("bank.example"))
		}
	}

	@Test
	internal func removingLeavesTheRawFilesAndRemovesProblemReports() async throws {
		let (store, root) = try Self.temporaryStore()
		defer { try? FileManager.default.removeItem(at: root) }

		let dump: URL = store.locations.engineDatabase.appendingPathComponent("completed/0F3A.dmp")
		try MinidumpFixture.renderer().write(to: dump)
		#expect(store.collect().count == 1)
		try store.keep(.init(description: "It froze", environment: .preview, diagnostics: nil))
		#expect(store.problemReportFiles().count == 1)
		#expect(await DiagnosticsClient.live(store: store).status() == .init(crashReports: 1, problemReports: 1))

		store.removeAll()
		#expect(store.entries().isEmpty)
		#expect(store.problemReportFiles().isEmpty)
		#expect(FileManager.default.fileExists(atPath: dump.path))
		// The raw file was read before: a removed report doesn't come back.
		#expect(store.collect().isEmpty)
	}

	@Test
	internal func problemReportFilesAreReadableAndOnlyTheNewestStay() throws {
		let clock: LockIsolated<Date> = .init(Self.fixtureNow)
		let (base, root) = try Self.temporaryStore()
		defer { try? FileManager.default.removeItem(at: root) }

		let store: CrashReportStore = .init(locations: base.locations, now: { clock.value })
		#expect(store.locations.problemReports == root.appendingPathComponent("Problem Reports"))
		let report: ProblemReport = .init(
			description: "Tabs vanish",
			environment: .preview,
			diagnostics: .init(hardwareModel: "Mac16,10", memoryGB: 24, crashReports: [])
		)
		let first: URL = try store.keep(report)
		#expect(first.lastPathComponent.hasPrefix("Arx Problem Report "))
		#expect(first.pathExtension == "json")
		let text: String = try String(contentsOf: first, encoding: .utf8)
		#expect(text.contains("\n  \"description\" : \"Tabs vanish\""))
		// Same second: a second file, not a replaced one.
		#expect(try store.keep(report) != first)

		for _ in 0..<CrashReportStore.problemReportLimit + 3 {
			clock.withValue { $0.addTimeInterval(1) }
			try store.keep(report)
		}
		let files: [URL] = store.problemReportFiles()
		#expect(files.count == CrashReportStore.problemReportLimit)
		#expect(!files.contains(first))
	}

	@Test
	internal func oldCrashFilesAreSkipped() throws {
		let now: Date = Self.fixtureNow
		let (store, root) = try Self.temporaryStore(now: now)
		defer { try? FileManager.default.removeItem(at: root) }

		let dump: URL = store.locations.engineDatabase.appendingPathComponent("completed/OLD.dmp")
		try MinidumpFixture.renderer().write(to: dump)
		try FileManager.default.setAttributes(
			[.modificationDate: now.addingTimeInterval(-CrashReportStore.retention - 60)],
			ofItemAtPath: dump.path
		)
		#expect(store.collect().isEmpty)
	}

	@Test
	internal func reportsSinceADate() throws {
		let (store, root) = try Self.temporaryStore(now: Date(timeIntervalSince1970: 1_794_560_462 + 3600))
		defer { try? FileManager.default.removeItem(at: root) }

		try CrashReportTests.ipsReport().write(to: store.locations.systemReports.appendingPathComponent("Arx-1.ips"))
		store.collect()
		#expect(store.reports(since: Date(timeIntervalSince1970: 1_794_560_000)).count == 1)
		#expect(store.reports(since: Date(timeIntervalSince1970: 1_794_561_000)).isEmpty)
	}

	@Test
	internal func descriptionsAreTrimmedAndCapped() {
		#expect(ProblemReport.trimmedDescription("  \n ") == nil)
		#expect(ProblemReport.trimmedDescription("  It froze.\n") == "It froze.")
		#expect(ProblemReport.trimmedDescription(String(repeating: "a", count: 20_000))?.count == ProblemReport.descriptionLimit)
	}
}
