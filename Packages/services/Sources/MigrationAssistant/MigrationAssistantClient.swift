import BrowserCore
import Foundation
import _Dependencies

/// The migration service boundary used by features.
///
/// The live value reads the browsers on this Mac and writes through
/// `MigrationWorkspaceBridge`, which AppFeature serves.
public struct MigrationAssistantClient: Sendable {
	/// Lists sources that registered adapters can read.
	public var discover: @Sendable () async throws -> [MigrationSource]

	/// Offers a file the user picked, or explains why it can't be read.
	public var addFile: @Sendable (URL) async throws -> MigrationSource

	/// Reads a snapshot and computes a preview without writing anything.
	public var inspect: @Sendable (
		MigrationSource.ID,
		[MigrationCategory],
		MigrationDestination
	) async throws -> MigrationPreview

	/// Runs a plan. The stream reports progress and ends with exactly one
	/// `finished` report, or throws a `MigrationFailure` before any commit.
	public var execute: @Sendable (MigrationPlan) -> AsyncThrowingStream<MigrationEvent, any Error>

	/// Requests cancellation at the next category boundary. The running stream
	/// still ends with a `cancelled` report.
	public var cancel: @Sendable (MigrationPlan.ID) async -> Void

	/// Browsers on this Mac that no adapter reads yet. Nothing in them is read.
	public var unsupportedBrowsers: @Sendable () async -> [MigrationUnsupportedBrowser]

	/// The Arx profile that receives a source profile (by its ID in the source, such as a
	/// Chromium profile folder) under a destination, once it exists.
	public var receivingProfile: @Sendable (String, MigrationDestination) async -> Profile?

	public init(
		discover: @escaping @Sendable () async throws -> [MigrationSource] = { [] },
		addFile: @escaping @Sendable (URL) async throws -> MigrationSource = { _ in
			throw MigrationFailure.unknownSource
		},
		inspect: @escaping @Sendable (
			MigrationSource.ID,
			[MigrationCategory],
			MigrationDestination
		) async throws -> MigrationPreview = { _, _, _ in
			throw MigrationFailure.unknownSource
		},
		execute: @escaping @Sendable (MigrationPlan) -> AsyncThrowingStream<MigrationEvent, any Error> = { _ in
			AsyncThrowingStream { $0.finish(throwing: MigrationFailure.unknownSource) }
		},
		cancel: @escaping @Sendable (MigrationPlan.ID) async -> Void = { _ in },
		unsupportedBrowsers: @escaping @Sendable () async -> [MigrationUnsupportedBrowser] = { [] },
		receivingProfile: @escaping @Sendable (String, MigrationDestination) async -> Profile? = { _, _ in nil }
	) {
		self.discover = discover
		self.addFile = addFile
		self.inspect = inspect
		self.execute = execute
		self.cancel = cancel
		self.unsupportedBrowsers = unsupportedBrowsers
		self.receivingProfile = receivingProfile
	}
}

extension MigrationAssistantClient {
	/// A client that runs imports with the given adapters and destination writer.
	public static func running(
		adapters: [MigrationSourceAdapter],
		writer: MigrationDestinationWriter,
		unsupportedBrowsers: [MigrationUnsupportedBrowser] = []
	) -> Self {
		let runner = MigrationRunner(
			adapters: adapters,
			writer: writer
		)
		return .init(
			discover: { await runner.discover() },
			addFile: { try await runner.addFile($0) },
			inspect: {
				try await runner.inspect(
					source: $0,
					categories: $1,
					destination: $2
				)
			},
			execute: { plan in
				AsyncThrowingStream { continuation in
					let task = Task {
						do {
							try await runner.execute(plan) { _ = continuation.yield($0) }
							continuation.finish()
						} catch {
							continuation.finish(throwing: error)
						}
					}
					continuation.onTermination = { _ in task.cancel() }
				}
			},
			cancel: { await runner.cancel($0) },
			unsupportedBrowsers: { unsupportedBrowsers },
			receivingProfile: { await runner.receivingProfile(sourceProfile: $0, destination: $1) }
		)
	}
}

extension MigrationAssistantClient: DependencyKey {
	public static var liveValue: Self {
		let unchecked = MigrationBrowserSources.offersUncheckedSources
		return .running(
			adapters: MigrationBrowserSources.adapters(includesUnchecked: unchecked),
			writer: MigrationWorkspaceBridge.shared.writer,
			unsupportedBrowsers: MigrationBrowserSources.unsupportedBrowsers(includesUnchecked: unchecked)
		)
	}

	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var migrationAssistant: MigrationAssistantClient {
		get { self[MigrationAssistantClient.self] }
		set { self[MigrationAssistantClient.self] = newValue }
	}
}
