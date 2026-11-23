import AppKit
import AppUI
import BrowserCore
import BrowserExtensionsClient
import BrowserHistoryClient
import Foundation
import MigrationAssistant
import _ComposableArchitecture

public enum BrowserDataExportFormat: Equatable, Sendable {
	case archive
	case bookmarks
}

/// The export's choices, and its progress while it runs.
///
/// History and the Tab Archive are left out unless the user includes them; they
/// aren't remembered, so every export starts without them. Installed extensions
/// are always listed.
public struct BrowserDataExportState: Equatable, Sendable {
	public var includesHistory: Bool
	public var includesArchivedTabs: Bool
	public var progress: BrowserDataExportProgress?

	public init(
		includesHistory: Bool = false,
		includesArchivedTabs: Bool = false,
		progress: BrowserDataExportProgress? = nil
	) {
		self.includesHistory = includesHistory
		self.includesArchivedTabs = includesArchivedTabs
		self.progress = progress
	}
}

public struct BrowserDataExportProgress: Equatable, Sendable {
	public var format: BrowserDataExportFormat
	public var step: Step
	public var completed: Int
	public var total: Int

	public init(
		format: BrowserDataExportFormat,
		step: Step,
		completed: Int = 0,
		total: Int = 0
	) {
		self.format = format
		self.step = step
		self.completed = completed
		self.total = total
	}

	/// Rough, by step: reading history and extensions, then writing the file.
	public var fractionCompleted: Double {
		let within: Double = total == 0 ? 0 : Double(completed) / Double(total)
		return switch step {
		case .choosingDestination: 0
		case .readingHistory: within * 0.4
		case .readingExtensions: 0.4 + within * 0.3
		case .writing: 0.7 + within * 0.3
		}
	}

	public enum Step: Equatable, Sendable {
		case choosingDestination
		case readingHistory
		case readingExtensions
		case writing
	}
}

/// What an export wrote, and what it left out.
public enum BrowserDataExportOutcome: Equatable, Sendable {
	case archive(MigrationExportSummary)
	case bookmarks(MigrationExportSummary)
	case failed(String)
}

@CasePathable
public enum BrowserDataExportAction: Sendable {
	case includesHistoryChanged(Bool)
	case includesArchivedTabsChanged(Bool)
	case cancelTapped
	case destinationChosen(URL?)
	case progressed(BrowserDataExportProgress)
	case finished(BrowserDataExportOutcome)
}

/// Asks where to save, then reads, encodes and writes the export off the main actor.
///
/// Progress reaches the store at most once per `progressInterval`, apart from the
/// step changes, and the export can be cancelled until its file is written.
@Reducer
internal struct BrowserDataExporting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	/// Ten updates a second at most.
	internal static let progressInterval: Duration = .milliseconds(100)

	@Dependency(\.browserDataExportClient)
	private var client

	@Dependency(\.browserExtensions)
	private var extensions

	@Dependency(\.browserHistory)
	private var history

	@Dependency(\.date.now)
	private var now

	private enum Cancellation: Hashable {
		case export
	}

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.exportBrowserData) { state, format in
			guard state.browserDataExport.progress == nil else { return .none }

			state.browserDataExport.progress = .init(format: format, step: .choosingDestination)
			return .run { [client] send in
				let url = await client.chooseDestination(format)
				await send(.browserDataExport(.destinationChosen(url)))
			}
			.cancellable(id: Cancellation.export, cancelInFlight: true)
		}

		Pullback(\.browserDataExport.includesHistoryChanged) { state, value in
			state.browserDataExport.includesHistory = value
			return .none
		}

		Pullback(\.browserDataExport.includesArchivedTabsChanged) { state, value in
			state.browserDataExport.includesArchivedTabs = value
			return .none
		}

		Pullback(\.browserDataExport.cancelTapped) { state in
			state.browserDataExport.progress = nil
			return .cancel(id: Cancellation.export)
		}

		Pullback(\.browserDataExport.destinationChosen) { state, url in
			guard let progress = state.browserDataExport.progress else { return .none }
			guard let url else {
				state.browserDataExport.progress = nil
				return .none
			}

			return export(progress.format, to: url, state: state)
		}

		Pullback(\.browserDataExport.progressed) { state, progress in
			guard state.browserDataExport.progress != nil else { return .none }

			state.browserDataExport.progress = progress
			return .none
		}

		Pullback(\.browserDataExport.finished) { state, outcome in
			guard state.browserDataExport.progress != nil else { return .none }

			state.browserDataExport.progress = nil
			return .send(.delegate(.browserDataExported(outcome)))
		}
	}

	private func export(
		_ format: BrowserDataExportFormat,
		to url: URL,
		state: State
	) -> Effect<Action> {
		let organization = state.workspace
		let preferences = state.persistedPreferences
		let options = state.browserDataExport
		let createdAt = now
		let profiles = organization.profiles.map(\.id)
		return .run { [client, extensions, history] send in
			var reporter: BrowserDataExportProgressReporter = .init(interval: Self.progressInterval)
			func report(_ progress: BrowserDataExportProgress) async {
				guard reporter.allows(progress) else { return }
				await send(.browserDataExport(.progressed(progress)))
			}

			do {
				let outcome: BrowserDataExportOutcome
				switch format {
				case .bookmarks:
					await report(.init(format: format, step: .writing, total: 1))
					let (html, summary) = BookmarksHTML.export(organization)
					try Task.checkCancellation()
					try await client.write(Data(html.utf8), url)
					outcome = .bookmarks(summary)

				case .archive:
					var snapshots: [BrowsingHistorySnapshot]?
					if options.includesHistory {
						var loaded: [BrowsingHistorySnapshot] = []
						for (index, profile) in profiles.enumerated() {
							await report(.init(format: format, step: .readingHistory, completed: index, total: profiles.count))
							loaded.append(try await history.load(profile).snapshot)
						}
						snapshots = loaded
					}

					var installed: [Profile.ID: [BrowserExtension]] = [:]
					if await extensions.isAvailable {
						for (index, profile) in profiles.enumerated() {
							await report(.init(format: format, step: .readingExtensions, completed: index, total: profiles.count))

							// A profile whose extensions can't be read is exported without them.
							installed[profile] = (try? await extensions.inspect(profile))?.extensions
						}
					}

					await report(.init(format: format, step: .writing, total: 1))
					try Task.checkCancellation()
					let archive = ArxTransferArchive(
						organization: organization,
						preferences: preferences,
						createdAt: createdAt,
						appVersion: client.appVersion(),
						history: snapshots,
						includesArchivedTabs: options.includesArchivedTabs,
						extensions: installed
					)
					let data = try archive.encoded()
					try Task.checkCancellation()
					try await client.write(data, url)
					outcome = .archive(archive.summary)
				}
				await send(.browserDataExport(.finished(outcome)))
			} catch is CancellationError {
				return
			} catch {
				await send(.browserDataExport(.finished(.failed(error.localizedDescription))))
			}
		}
		.cancellable(id: Cancellation.export, cancelInFlight: true)
	}
}

/// Lets a step change through at once and holds other updates to one per interval.
internal struct BrowserDataExportProgressReporter {
	private let interval: Duration
	private let now: () -> ContinuousClock.Instant
	private var last: (step: BrowserDataExportProgress.Step, at: ContinuousClock.Instant)?

	internal init(
		interval: Duration,
		now: @escaping () -> ContinuousClock.Instant = { .now }
	) {
		self.interval = interval
		self.now = now
		self.last = nil
	}

	internal mutating func allows(_ progress: BrowserDataExportProgress) -> Bool {
		let instant = now()
		if let last, last.step == progress.step, last.at.duration(to: instant) < interval {
			return false
		}
		last = (progress.step, instant)
		return true
	}
}

/// Where an export goes. Live, it asks with a save panel and writes atomically.
public struct BrowserDataExportClient: Sendable {
	/// Nil when the user cancels.
	public var chooseDestination: @Sendable (BrowserDataExportFormat) async -> URL?

	/// Replaces the file only once the whole export is written.
	public var write: @Sendable (Data, URL) async throws -> Void
	public var appVersion: @Sendable () -> String?

	public init(
		chooseDestination: @escaping @Sendable (BrowserDataExportFormat) async -> URL?,
		write: @escaping @Sendable (Data, URL) async throws -> Void,
		appVersion: @escaping @Sendable () -> String? = { nil }
	) {
		self.chooseDestination = chooseDestination
		self.write = write
		self.appVersion = appVersion
	}
}

extension BrowserDataExportClient: DependencyKey {
	public static var liveValue: Self {
		.init(
			chooseDestination: { format in
				await MainActor.run {
					let panel = NSSavePanel()
					switch format {
					case .archive: panel.nameFieldStringValue = "Arx Archive.json"
					case .bookmarks: panel.nameFieldStringValue = "Arx Bookmarks.html"
					}
					return panel.runModal() == .OK ? panel.url : nil
				}
			},
			write: { data, url in try data.write(to: url, options: .atomic) },
			appVersion: { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
		)
	}

	public static var testValue: Self {
		.init(
			chooseDestination: unimplemented("BrowserDataExportClient.chooseDestination", placeholder: nil),
			write: unimplemented("BrowserDataExportClient.write"),
			appVersion: unimplemented("BrowserDataExportClient.appVersion", placeholder: nil)
		)
	}
}

extension DependencyValues {
	public var browserDataExportClient: BrowserDataExportClient {
		get { self[BrowserDataExportClient.self] }
		set { self[BrowserDataExportClient.self] = newValue }
	}
}

extension BrowserDataExportOutcome {
	/// The alert's title and text.
	internal var message: (title: String, detail: String) {
		switch self {
		case let .archive(summary):
			let exported: String = [
				String.localized(.appUI.export.count.profiles(summary.profiles)),
				String.localized(.appUI.export.count.spaces(summary.spaces)),
				String.localized(.appUI.export.count.folders(summary.folders)),
				String.localized(.appUI.export.count.tabs(summary.tabs)),
			].formatted(.list(type: .and))
			var lines: [String] = [String.localized(.appUI.export.archiveSummary(exported))]
			let extras: [String] = [
				summary.historyEntries > 0 ? String.localized(.appUI.export.count.historyEntries(summary.historyEntries)) : nil,
				summary.archivedTabs > 0 ? String.localized(.appUI.export.count.archivedTabs(summary.archivedTabs)) : nil,
			].compactMap(\.self)
			if !extras.isEmpty {
				lines.append(String.localized(.appUI.export.archiveExtras(extras.formatted(.list(type: .and)))))
			}
			if summary.extensions > 0 {
				lines.append(String.localized(.appUI.export.extensionsListed(summary.extensions)))
			}
			return (String.localized(.appUI.export.title), lines.joined(separator: "\n"))

		case let .bookmarks(summary):
			let exported: String = [
				String.localized(.appUI.export.count.bookmarks(summary.tabs)),
				String.localized(.appUI.export.count.folders(summary.folders)),
			].formatted(.list(type: .and))
			var detail: String = String.localized(.appUI.export.bookmarksSummary(exported))
			if summary.omittedRegularTabs > 0 {
				// A line of its own: languages separate sentences differently (Japanese and Chinese
				// with no space).
				detail += "\n" + String.localized(.appUI.export.omittedRegularTabs(summary.omittedRegularTabs))
			}
			return (String.localized(.appUI.export.title), detail)

		case let .failed(message):
			return (String.localized(.appUI.export.failed), message)
		}
	}
}
