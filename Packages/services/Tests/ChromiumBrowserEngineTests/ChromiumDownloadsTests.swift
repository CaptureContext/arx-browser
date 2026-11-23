import BrowserCore
import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@MainActor
internal struct ChromiumDownloadsTests {
	@Test
	internal func initialOrganizationLabelsNativeReplayBeforeConfiguration() async throws {
		let profileID = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		let tabID = Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
		let spaceID = Space.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
		let directory = FileManager.default.temporaryDirectory.appending(path: "arx-download-origin-tests-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		let organization = BrowserOrganization(
			profiles: [.init(id: profileID, name: "Work")],
			spaces: [.init(id: spaceID, profileID: profileID, name: "Research", unpinnedTabs: [tabID])],
			tabs: [.init(id: tabID, profileID: profileID, restoration: .init(title: "Source", url: URL(string: "https://capturecontext.dev")!))]
		)
		let runtime = ChromiumRuntime(api: Fixture.api)
		var service: ChromiumDownloads?
		_ = try runtime.run(
			executable: directory.appending(path: "Arx.app/Contents/MacOS/Arx"),
			profileDirectory: directory.appending(path: "profile")
		) { runtime in
			service = ChromiumDownloads(
				runtime: runtime,
				legacyProfileID: profileID,
				file: directory.appending(path: "downloads.json"),
				organization: organization,
				sourceTab: { $0 == 42 ? tabID : nil }
			)
		}
		let client = try #require(service).client
		var received: BrowserDownload?
		for await queue in client.events() {
			guard let value = queue.downloads.first else { continue }
			received = value
			break
		}
		expectNoDifference(received, .init(
			id: .init(profileID: profileID, guid: "early-download"),
			profileName: "Work",
			spaceName: "Research",
			url: URL(string: "https://capturecontext.dev/report"),
			filename: "report.txt",
			status: .inProgress,
			receivedBytes: 12,
			totalBytes: 24,
			startedAt: Date(timeIntervalSince1970: 100),
			sourceTabID: tabID
		))
	}

	@Test
	internal func canceledConfigurationCannotReplaceOriginLookupBeforeItsFirstAwait() async throws {
		let profileID = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		let tabID = Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
		let spaceID = Space.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
		let directory = FileManager.default.temporaryDirectory.appending(path: "arx-download-cancellation-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		let current = BrowserOrganization(
			profiles: [.init(id: profileID, name: "Current profile")],
			spaces: [.init(id: spaceID, profileID: profileID, name: "Current space", unpinnedTabs: [tabID])],
			tabs: [.init(id: tabID, profileID: profileID, restoration: .init(title: "Source", url: URL(string: "https://capturecontext.dev")!))]
		)
		var older = current
		older.profiles[0].name = "Obsolete profile"
		older.spaces[0].name = "Obsolete space"
		let runtime = ChromiumRuntime(api: Fixture.api)
		let service = ChromiumDownloads(
			runtime: runtime,
			legacyProfileID: profileID,
			file: directory.appending(path: "downloads.json"),
			organization: current,
			sourceTab: { $0 == 42 ? tabID : nil }
		)
		let client = service.client
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			try await client.configure(older)
		}
		await #expect(throws: CancellationError.self) { try await task.value }
		_ = try runtime.run(
			executable: directory.appending(path: "Arx.app/Contents/MacOS/Arx"),
			profileDirectory: directory.appending(path: "profile")
		) { _ in }
		for await queue in client.events() {
			guard let record = queue.downloads.first else { continue }
			expectNoDifference(record.profileName, "Current profile")
			expectNoDifference(record.spaceName, "Current space")
			break
		}
	}

	/// DEV-880. Configuration loads only a profile with a persisted transfer still in progress,
	/// so Chromium reconciles it; every other profile waits for its first use.
	@Test
	internal func configurationPreparesOnlyProfilesWithPendingTransfers() async throws {
		let shown = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		let pending = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
		let idle = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
		let directory = FileManager.default.temporaryDirectory.appending(path: "arx-download-pending-\(UUID())")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		var previous = DownloadLedger(file: file)
		previous.receive(.init(
			id: .init(profileID: pending, guid: "left-running"),
			profileName: "Pending",
			filename: "report.txt",
			status: .inProgress,
			startedAt: Date(timeIntervalSince1970: 100)
		))
		previous.receive(.init(
			id: .init(profileID: idle, guid: "finished"),
			profileName: "Idle",
			filename: "done.txt",
			status: .complete,
			startedAt: Date(timeIntervalSince1970: 50)
		))
		let organization = BrowserOrganization(
			profiles: [shown, pending, idle].map { .init(id: $0, name: "Profile") },
			legacyProfileID: shown
		)

		PendingFixture.prepared = []
		var api = ArxEngineAPI()
		api.prepare_profile = { key, request in
			MainActor.assumeIsolated { PendingFixture.prepared.append((key.map { String(cString: $0) } ?? "?", request)) }
		}
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		defer { runtime.finish() }
		let service = ChromiumDownloads(
			runtime: runtime,
			legacyProfileID: shown,
			file: file,
			organization: organization,
			sourceTab: { _ in nil }
		)

		let configuration = Task { try await service.client.configure(organization) }
		while PendingFixture.prepared.isEmpty { await Task.yield() }
		runtime.complete(PendingFixture.prepared[0].request, true)
		try await configuration.value
		expectNoDifference(PendingFixture.prepared.map(\.key), ["00000000-0000-0000-0000-000000000002"])
	}
}

@MainActor
private enum PendingFixture {
	internal static var prepared: [(key: String, request: UInt64)] = []
}

private enum Fixture {
	internal static var api: ArxEngineAPI {
		var api = ArxEngineAPI()
		api.run = { _, _, callbacks in
			"".withCString { profile in
				"early-download".withCString { guid in
					"https://capturecontext.dev/report".withCString { url in
						"report.txt".withCString { filename in
							var snapshot = ArxDownloadSnapshot(
								guid: guid,
								url: url,
								target_path: nil,
								filename: filename,
								source_page: 42,
								state: 0,
								interrupt_reason: 0,
								received_bytes: 12,
								total_bytes: 24,
								started_at: 100,
								dangerous: false,
								missing: false,
								private_context: false
							)
							callbacks?.pointee.download_changed(callbacks?.pointee.context, profile, &snapshot)
						}
					}
				}
			}
			callbacks?.pointee.ready(callbacks?.pointee.context)
			callbacks?.pointee.stopping(callbacks?.pointee.context)
			return 0
		}
		return api
	}
}
