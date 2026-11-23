import BrowserCore
import Foundation

/// Arx's own folder of crash reports (DEV-887), reduced by ``SystemCrashReport`` and ``Minidump``.
///
/// Collecting reads new `.ips` reports for Arx's processes from macOS's folder and new minidumps
/// from Chromium's crash database, and keeps each as one JSON file. Raw files are only read,
/// never moved or changed. Reports older than ``retention`` and those past ``limit`` are removed.
public struct CrashReportStore: Sendable {
	public struct Locations: Equatable, Sendable {
		/// Where reduced reports are kept.
		public var reports: URL

		/// macOS's crash reports.
		public var systemReports: URL

		/// Chromium's Crashpad database.
		public var engineDatabase: URL

		/// Where Report a Problem saves report files for the person to attach to an issue; by
		/// default `Problem Reports` next to `reports`.
		public var problemReports: URL

		/// The stall log and MetricKit's hang reports (DEV-1010); by default `Hangs` next to
		/// `reports`.
		public var hangs: URL

		/// The clean-quit markers and the unclean exits (DEV-1018); by default `Sessions` next
		/// to `reports`.
		public var sessions: URL

		public init(
			reports: URL,
			systemReports: URL,
			engineDatabase: URL,
			problemReports: URL? = nil,
			hangs: URL? = nil,
			sessions: URL? = nil
		) {
			self.reports = reports
			self.systemReports = systemReports
			self.engineDatabase = engineDatabase
			self.problemReports = problemReports
				?? reports.deletingLastPathComponent().appendingPathComponent("Problem Reports")
			self.hangs = hangs
				?? reports.deletingLastPathComponent().appendingPathComponent("Hangs")
			self.sessions = sessions
				?? reports.deletingLastPathComponent().appendingPathComponent("Sessions")
		}

		/// `~/Library/Application Support/<bundle identifier>/Diagnostics/Crash Reports` and
		/// `…/Diagnostics/Problem Reports`, `~/Library/Logs/DiagnosticReports`, and Chromium's
		/// `…/<bundle identifier>/Crashpad`, for this edition of Arx (DEV-1013).
		public static var standard: Self {
			let support: URL = ArxEdition.current.applicationSupport(home: .homeDirectory)
			return .init(
				reports: support.appendingPathComponent("Diagnostics/Crash Reports"),
				systemReports: URL.libraryDirectory.appendingPathComponent("Logs/DiagnosticReports"),
				engineDatabase: support.appendingPathComponent("Crashpad")
			)
		}
	}

	/// A kept report and the raw file it was read from.
	public struct Entry: Codable, Equatable, Sendable {
		public var report: CrashReport
		public var source: String

		public init(
			report: CrashReport,
			source: String
		) {
			self.report = report
			self.source = source
		}
	}

	public static let retention: TimeInterval = 30 * 24 * 3600
	public static let limit: Int = 50

	/// Report files kept for attaching; older ones are removed.
	public static let problemReportLimit: Int = 10

	public var locations: Locations
	public var now: @Sendable () -> Date

	public init(
		locations: Locations,
		now: @escaping @Sendable () -> Date = Date.init
	) {
		self.locations = locations
		self.now = now
	}

	// MARK: - Reading

	public func entries() -> [Entry] {
		let files: [URL] = (try? FileManager.default.contentsOfDirectory(
			at: locations.reports,
			includingPropertiesForKeys: nil
		)) ?? []
		return files
			.filter { $0.pathExtension == "json" }
			.compactMap { file in
				(try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode(Entry.self, from: $0) }
			}
			.sorted { $0.report.date > $1.report.date }
	}

	public func reports(since date: Date) -> [CrashReport] {
		entries().map(\.report).filter { $0.date >= date }
	}

	// MARK: - Collecting

	/// Keeps every new crash report of an Arx process, then prunes. Returns the entries kept.
	@discardableResult
	public func collect() -> [Entry] {
		let fileManager: FileManager = .default
		try? fileManager.createDirectory(at: locations.reports, withIntermediateDirectories: true)
		let available: [(URL, CrashReport.Source)] = sources()

		// Every raw file read before, kept or not, so a pruned report never comes back.
		var seen: Set<String> = Set(entries().map(\.source)).union(readSeen())
		let oldest: Date = now().addingTimeInterval(-Self.retention)

		for (file, kind) in available where !seen.contains(file.lastPathComponent) {
			seen.insert(file.lastPathComponent)
			let modified: Date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now()
			guard modified >= oldest, let data = try? Data(contentsOf: file)
			else { continue }

			let id: String = file.deletingPathExtension().lastPathComponent
			let report: CrashReport? = switch kind {
			case .system: SystemCrashReport.parse(data, fallbackID: id, fallbackDate: modified)
			case .engine: Minidump.parse(data, id: id, fallbackDate: modified)
			}
			guard let report
			else { continue }

			save(.init(report: report, source: file.lastPathComponent))
		}

		// Names of raw files that are gone can't come back; forgetting them keeps the list short.
		writeSeen(seen.intersection(available.map(\.0.lastPathComponent)))
		prune()
		stalls.prune()
		hangReports.prune()
		uncleanExits.prune()
		return entries()
	}

	/// Removes every kept crash report, every saved problem report file and the hang logs. The raw
	/// files macOS and Chromium wrote stay, and so do the lists of raw files and MetricKit
	/// payloads already read, so a removed report never comes back.
	public func removeAll() {
		StallLog(folder: locations.hangs).removeAll()
		HangReportLog(folder: locations.hangs).removeAll()
		UncleanExitLog(folder: locations.sessions).removeAll()
		for folder in [locations.reports, locations.problemReports] {
			let files: [URL] = (try? FileManager.default.contentsOfDirectory(
				at: folder,
				includingPropertiesForKeys: nil
			)) ?? []
			for file in files where file.pathExtension == "json" {
				try? FileManager.default.removeItem(at: file)
			}
		}
	}

	// MARK: - Problem reports

	/// Saves a problem report in ``Locations/problemReports`` for the person to attach to an
	/// issue, named by the time, and keeps only the newest ``problemReportLimit``.
	@discardableResult
	public func keep(_ report: ProblemReport) throws -> URL {
		try FileManager.default.createDirectory(at: locations.problemReports, withIntermediateDirectories: true)
		let formatter: DateFormatter = .init()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
		var file: URL = locations.problemReports
			.appendingPathComponent("Arx Problem Report \(formatter.string(from: now())).json")
		var copy: Int = 2
		while FileManager.default.fileExists(atPath: file.path) {
			file = locations.problemReports
				.appendingPathComponent("Arx Problem Report \(formatter.string(from: now())) \(copy).json")
			copy += 1
		}
		try Self.reportEncoder.encode(report).write(to: file, options: .atomic)
		pruneProblemReports()
		return file
	}

	/// The saved problem report files, newest first (their names start with the time).
	public func problemReportFiles() -> [URL] {
		let files: [URL] = (try? FileManager.default.contentsOfDirectory(
			at: locations.problemReports,
			includingPropertiesForKeys: nil
		)) ?? []
		return files
			.filter { $0.pathExtension == "json" }
			.sorted { $0.lastPathComponent > $1.lastPathComponent }
	}

	private func pruneProblemReports() {
		for file in problemReportFiles().dropFirst(Self.problemReportLimit) {
			try? FileManager.default.removeItem(at: file)
		}
	}

	// MARK: - Sources

	private func sources() -> [(URL, CrashReport.Source)] {
		let fileManager: FileManager = .default
		let system: [URL] = ((try? fileManager.contentsOfDirectory(at: locations.systemReports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
			.filter { $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix("Arx") }
		let engine: [URL] = ["pending", "completed"].flatMap { folder in
			((try? fileManager.contentsOfDirectory(
				at: locations.engineDatabase.appendingPathComponent(folder),
				includingPropertiesForKeys: [.contentModificationDateKey]
			)) ?? []).filter { $0.pathExtension == "dmp" }
		}
		return system.map { ($0, .system) } + engine.map { ($0, .engine) }
	}

	// MARK: - Files

	private func file(for id: CrashReport.ID) -> URL {
		let safe: String = id.unicodeScalars
			.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }
			.joined()
		return locations.reports.appendingPathComponent(safe).appendingPathExtension("json")
	}

	private func save(_ entry: Entry) {
		guard let data = try? Self.encoder.encode(entry)
		else { return }

		try? data.write(to: file(for: entry.report.id), options: .atomic)
	}

	private var seenFile: URL {
		locations.reports.appendingPathComponent("seen.list")
	}

	private func readSeen() -> Set<String> {
		guard let text = try? String(contentsOf: seenFile, encoding: .utf8)
		else { return [] }

		return Set(text.split(separator: "\n").map(String.init))
	}

	private func writeSeen(_ names: Set<String>) {
		try? names.sorted().joined(separator: "\n").write(to: seenFile, atomically: true, encoding: .utf8)
	}

	private func prune() {
		let oldest: Date = now().addingTimeInterval(-Self.retention)
		for (index, entry) in entries().enumerated() where index >= Self.limit || entry.report.date < oldest {
			try? FileManager.default.removeItem(at: file(for: entry.report.id))
		}
	}

	// MARK: - Hangs

	public var stalls: StallLog {
		.init(file: StallLog(folder: locations.hangs).file, now: now)
	}

	public var hangReports: HangReportLog {
		.init(file: HangReportLog(folder: locations.hangs).file, now: now)
	}

	public var uncleanExits: UncleanExitLog {
		.init(file: UncleanExitLog(folder: locations.sessions).file, now: now)
	}

	internal static var encoder: JSONEncoder {
		let encoder: JSONEncoder = .init()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.sortedKeys]
		return encoder
	}

	/// Problem report files are read by people, so they're indented.
	public static var reportEncoder: JSONEncoder {
		let encoder: JSONEncoder = .init()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
		return encoder
	}

	internal static var decoder: JSONDecoder {
		let decoder: JSONDecoder = .init()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}
}
