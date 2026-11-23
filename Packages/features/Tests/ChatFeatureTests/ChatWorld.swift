import AgentClient
import BrowserCore
import ChatFeature
import Foundation
import _ComposableArchitecture
import _TestSupport

/// Doubles for everything a chat touches: one fake provider, an in-memory store, browser
/// access and time. Nothing reaches a real home folder, Claude account or process.
internal final class ChatWorld: Sendable {
	internal enum Script: Sendable {
		/// The turn reports these events and ends.
		case events([AgentEvent])

		/// The turn reports these events, then fails.
		case failure([AgentEvent], AgentFailure)

		/// The turn runs until it's cancelled.
		case endless
	}

	internal static let profileID: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
	internal static let start: Date = .init(timeIntervalSince1970: 1_800_000_000)

	internal let clock: TestClock<Duration> = .init()
	internal let now: LockIsolated<Date> = .init(ChatWorld.start)
	internal let script: LockIsolated<Script> = .init(.events([]))
	internal let access: LockIsolated<AgentBrowserAccess.Failure?> = .init(.notGranted)

	internal let requests: LockIsolated<[AgentTurnRequest]> = .init([])
	internal let cancelledTurns: LockIsolated<Int> = .init(0)
	internal let discarded: LockIsolated<[String]> = .init([])

	internal let storedSettings: LockIsolated<AgentProfileSettings?> = .init(nil)
	internal let kept: LockIsolated<[AgentConversation]> = .init([])
	internal let saved: LockIsolated<[AgentConversation]> = .init([])
	internal let deleted: LockIsolated<[AgentConversation.ID]> = .init([])
	internal let transcripts: LockIsolated<Set<String>> = .init([])

	internal init() {}

	internal var provider: AgentProviderClient {
		.init(
			provider: .claude,
			account: { .init(provider: .claude, status: .signedIn(.init(id: "test"))) },
			models: { [.init(id: "sonnet", title: "Claude Sonnet", capabilities: [.streaming])] },
			send: { [self] request in
				requests.withValue { $0.append(request) }
				let script: Script = script.value
				return AsyncThrowingStream { continuation in
					switch script {
					case let .events(events):
						events.forEach { continuation.yield($0) }
						continuation.finish()

					case let .failure(events, failure):
						events.forEach { continuation.yield($0) }
						continuation.finish(throwing: failure)

					case .endless:
						continuation.onTermination = { [self] _ in
							cancelledTurns.withValue { $0 += 1 }
						}
					}
				}
			},
			discard: { [self] token in discarded.withValue { $0.append(token) } }
		)
	}

	internal var store: AgentConversationStore {
		.init(
			list: { [self] _ in kept.value },
			save: { [self] conversation in saved.withValue { $0.append(conversation) } },
			delete: { [self] id, _ in deleted.withValue { $0.append(id) } },
			deleteProfile: { _ in },
			settings: { [self] _ in storedSettings.value },
			setSettings: { [self] settings, _ in storedSettings.setValue(settings) },
			rememberTranscript: { [self] token, _ in transcripts.withValue { _ = $0.insert(token) } },
			forgetTranscript: { [self] token, _ in transcripts.withValue { _ = $0.remove(token) } },
			rememberedTranscripts: { [self] _ in transcripts.value.sorted() },
			clearTurns: { _, _ in }
		)
	}

	internal func install(into dependencies: inout DependencyValues) {
		dependencies.agentProviders = .init(clients: [provider], isEnabled: false)
		dependencies.agentConversations = store
		dependencies.chatSaves = .init()
		dependencies.agentBrowserAccess = .init { [self] _ in
			if let failure = access.value { throw failure }
			return .init(
				helper: URL(fileURLWithPath: "/Applications/Arx.app/Contents/Helpers/ArxMCP"),
				credential: .init(socket: "/tmp/arx-test.sock", clientID: UUID(0), token: "test-token")
			)
		}
		dependencies.continuousClock = clock
		dependencies.date = .init { [self] in now.value }
		dependencies.uuid = .incrementing
	}

	/// Moves the clock and the date together.
	internal func advance(by seconds: TimeInterval) async {
		now.withValue { $0 = $0.addingTimeInterval(seconds) }
		await clock.advance(by: .seconds(seconds))
	}

	/// Waits until the provider saw its turn cancelled.
	internal func waitForCancellation() async {
		for _ in 0..<10_000 where cancelledTurns.value == 0 {
			await Task.yield()
		}
	}
}

extension UUID {
	internal init(_ value: Int) {
		self.init(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
	}
}

extension AgentConversation.ID {
	internal init(_ value: Int) {
		self.init(rawValue: UUID(value))
	}
}
