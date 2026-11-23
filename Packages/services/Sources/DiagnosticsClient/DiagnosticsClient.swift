#if canImport(AppKit)
import AppKit
#endif
import Foundation
import _Dependencies

/// Crash reports and Report a Problem (DEV-887).
///
/// Crashes of Arx and its engine helpers are kept on this Mac, reduced to ``CrashReport``s, and
/// never sent anywhere. Report a Problem opens a GitHub issue (``GitHubIssue``) prefilled with
/// the description and the versions; with Include diagnostics on, it first saves a report file
/// with the Mac's model and the recent crash reports for the person to attach.
public struct DiagnosticsClient: Sendable {
	/// How many crash reports and problem report files are kept.
	public var status: @Sendable () async -> Status

	/// Keeps new crash reports.
	public var collect: @Sendable () async -> Status

	/// The versions a report names.
	public var environment: @Sendable () async -> DiagnosticsEnvironment

	/// What Include diagnostics adds: the Mac's model and memory, and recent crash reports,
	/// collecting new ones first.
	public var diagnostics: @Sendable () async -> ProblemReport.Diagnostics

	/// Saves a problem report in Arx's Problem Reports folder for the person to attach to the
	/// issue, and returns the file.
	public var keep: @Sendable (ProblemReport) async throws -> URL

	/// Writes a problem report as JSON where the person picked.
	public var save: @Sendable (ProblemReport, URL) async throws -> Void

	/// Selects a file in Finder.
	public var reveal: @Sendable (URL) async -> Void

	/// Removes the crash reports and problem report files Arx kept.
	public var removeCrashReports: @Sendable () async -> Status

	public init(
		status: @escaping @Sendable () async -> Status,
		collect: @escaping @Sendable () async -> Status,
		environment: @escaping @Sendable () async -> DiagnosticsEnvironment,
		diagnostics: @escaping @Sendable () async -> ProblemReport.Diagnostics,
		keep: @escaping @Sendable (ProblemReport) async throws -> URL,
		save: @escaping @Sendable (ProblemReport, URL) async throws -> Void,
		reveal: @escaping @Sendable (URL) async -> Void,
		removeCrashReports: @escaping @Sendable () async -> Status
	) {
		self.status = status
		self.collect = collect
		self.environment = environment
		self.diagnostics = diagnostics
		self.keep = keep
		self.save = save
		self.reveal = reveal
		self.removeCrashReports = removeCrashReports
	}
}

// MARK: - Types

extension DiagnosticsClient {
	public struct Status: Equatable, Sendable {
		/// Crash reports kept on this Mac.
		public var crashReports: Int

		/// Problem report files Report a Problem saved for attaching.
		public var problemReports: Int

		/// Stalls and MetricKit hang reports kept on this Mac (DEV-1010).
		public var hangs: Int

		/// Runs that ended without Arx quitting (DEV-1018).
		public var uncleanExits: Int

		public init(
			crashReports: Int = 0,
			problemReports: Int = 0,
			hangs: Int = 0,
			uncleanExits: Int = 0
		) {
			self.crashReports = crashReports
			self.problemReports = problemReports
			self.hangs = hangs
			self.uncleanExits = uncleanExits
		}

		/// Whether Remove has anything to delete.
		public var hasReports: Bool {
			crashReports > 0 || problemReports > 0 || hangs > 0 || uncleanExits > 0
		}
	}
}

// MARK: - Live

extension DiagnosticsClient {
	/// The app's crash folders and Problem Reports folder.
	public static func live(store: CrashReportStore = .init(locations: .standard)) -> Self {
		let service: LiveDiagnostics = .init(store: store)
		return .init(
			status: { await service.status() },
			collect: { await service.collect() },
			environment: { DiagnosticsEnvironment.current() },
			diagnostics: { await service.diagnostics() },
			keep: { try await service.keep($0) },
			save: { report, url in
				try CrashReportStore.reportEncoder.encode(report).write(to: url, options: .atomic)
			},
			reveal: { url in
				#if canImport(AppKit)
				await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
				#endif
			},
			removeCrashReports: { await service.removeCrashReports() }
		)
	}
}

/// Serializes collecting, keeping and removing.
private actor LiveDiagnostics {
	private let store: CrashReportStore

	internal init(store: CrashReportStore) {
		self.store = store
	}

	internal func status() -> DiagnosticsClient.Status {
		.init(
			crashReports: store.entries().count,
			problemReports: store.problemReportFiles().count,
			hangs: store.stalls.records().count + store.hangReports.reports().count,
			uncleanExits: store.uncleanExits.exits().count
		)
	}

	internal func collect() -> DiagnosticsClient.Status {
		store.collect()
		return status()
	}

	/// Reads crash reports kept on this Mac, collecting new ones first.
	internal func diagnostics() -> ProblemReport.Diagnostics {
		store.collect()
		let since: Date = Date().addingTimeInterval(-ProblemReport.crashReportWindow)
		return .init(
			hardwareModel: Self.hardwareModel(),
			memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
			crashReports: store.reports(since: since),
			stalls: Array(store.stalls.records(since: since).prefix(ProblemReport.hangLimit)),
			hangReports: Array(store.hangReports.reports(since: since).prefix(ProblemReport.hangLimit)),
			uncleanExits: Array(store.uncleanExits.exits(since: since).prefix(ProblemReport.hangLimit))
		)
	}

	internal func keep(_ report: ProblemReport) throws -> URL {
		try store.keep(report)
	}

	internal func removeCrashReports() -> DiagnosticsClient.Status {
		store.removeAll()
		return status()
	}

	private static func hardwareModel() -> String? {
		var size: Int = 0
		guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0
		else { return nil }

		var buffer: [CChar] = .init(repeating: 0, count: size)
		guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0
		else { return nil }

		return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
	}
}

// MARK: - Dependency

extension DiagnosticsClient: DependencyKey {
	public static var liveValue: Self { .live() }

	public static var testValue: Self {
		.init(
			status: unimplemented("DiagnosticsClient.status", placeholder: .init()),
			collect: unimplemented("DiagnosticsClient.collect", placeholder: .init()),
			environment: unimplemented("DiagnosticsClient.environment", placeholder: .preview),
			diagnostics: unimplemented("DiagnosticsClient.diagnostics", placeholder: .init(hardwareModel: nil, memoryGB: 0, crashReports: [])),
			keep: unimplemented("DiagnosticsClient.keep", placeholder: URL(fileURLWithPath: "/dev/null")),
			save: unimplemented("DiagnosticsClient.save"),
			reveal: unimplemented("DiagnosticsClient.reveal"),
			removeCrashReports: unimplemented("DiagnosticsClient.removeCrashReports", placeholder: .init())
		)
	}

	/// Previews: one crash report kept; files go nowhere.
	public static var previewValue: Self {
		.init(
			status: { .init(crashReports: 1) },
			collect: { .init(crashReports: 1) },
			environment: { .preview },
			diagnostics: { .init(hardwareModel: "Mac16,10", memoryGB: 24, crashReports: []) },
			keep: { _ in URL(fileURLWithPath: "/tmp/Arx Problem Report.json") },
			save: { _, _ in },
			reveal: { _ in },
			removeCrashReports: { .init() }
		)
	}
}

extension DiagnosticsEnvironment {
	public static var preview: Self {
		.init(
			appVersion: "0.3.0",
			appBuild: "12",
			engineVersion: "0.20.1.1",
			chromiumVersion: "147.0.7727.55",
			macOSVersion: "macOS 27.0 (26A425)",
			architecture: "arm64"
		)
	}
}

extension DependencyValues {
	public var diagnostics: DiagnosticsClient {
		get { self[DiagnosticsClient.self] }
		set { self[DiagnosticsClient.self] = newValue }
	}
}
