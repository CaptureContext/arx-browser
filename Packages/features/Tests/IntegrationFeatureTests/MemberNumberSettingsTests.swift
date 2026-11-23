import BrowserCore
import Foundation
import MemberNumberClient
import SettingsFeature
import Testing
import _ComposableArchitecture

/// The identity card's member number (DEV-701): each state the Member number section shows, and
/// the number coming back after a relaunch. A fake client stands in for Apple and the server.
@Suite(.dependencies)
@MainActor
internal struct MemberNumberSettingsTests {
	private let number: MemberNumber = .init(index: 42, registeredOn: "2026-11-18", provider: .apple)

	@Test
	internal func notClaimedOffersTheBuildsSignIns() async {
		let store = TestStore(initialState: MemberNumberFeature.State()) {
			MemberNumberFeature()
		} withDependencies: {
			$0.memberNumber = .fake(providers: [.apple])
		}

		await store.send(.ui(.appeared)) {
			$0.isLoaded = true
			$0.providers = [.apple]
		}
		#expect(store.state.status == .notClaimed)

		// Appearing again reads nothing more.
		await store.send(.ui(.appeared))
	}

	@Test
	internal func claimingSignsInSendsTheTokenOnceAndKeepsTheNumber() async {
		let world: FakeWorld = .init()
		let number = number
		let store = TestStore(initialState: MemberNumberFeature.State()) {
			MemberNumberFeature()
		} withDependencies: {
			$0.memberNumber = .fake(providers: [.apple], world: world, claim: { _, _, _ in number })
		}

		await store.send(.ui(.appeared)) {
			$0.isLoaded = true
			$0.providers = [.apple]
		}
		await store.send(.ui(.claim(.apple))) {
			$0.status = .signingIn(.apple)
		}
		await store.receive(\.event.claimFinished) {
			$0.status = .claimed(number)
		}

		#expect(world.signIns.value == [.apple])
		#expect(world.sentTokens.value == ["token-apple"])
		#expect(world.saved.value == number)
		#expect(store.state.number == number)

		// Claimed: another tap sends nothing.
		await store.send(.ui(.claim(.apple)))
		#expect(world.sentTokens.value.count == 1)
	}

	@Test
	internal func aSecondTapWhileSigningInStartsNothing() async {
		let world: FakeWorld = .init()
		let number = number
		let gate: AsyncStream<Void>.Makeable = .init()
		let store = TestStore(initialState: MemberNumberFeature.State(providers: [.apple], isLoaded: true)) {
			MemberNumberFeature()
		} withDependencies: {
			$0.memberNumber = .fake(providers: [.apple], world: world, claim: { _, _, _ in
				await gate.stream.first { _ in true }
				return number
			})
		}

		await store.send(.ui(.claim(.apple))) {
			$0.status = .signingIn(.apple)
		}
		await store.send(.ui(.claim(.apple)))
		gate.continuation.yield()
		await store.receive(\.event.claimFinished) {
			$0.status = .claimed(number)
		}
		#expect(world.signIns.value == [.apple])
	}

	@Test(arguments: [
		MemberNumberFailure.offline,
		.refused,
	])
	internal func aServerFailureIsShownAndTryAgainWorks(failure: MemberNumberFailure) async {
		let world: FakeWorld = .init()
		let number = number
		let attempts: LockIsolated<Int> = .init(0)
		let store = TestStore(initialState: MemberNumberFeature.State(providers: [.apple], isLoaded: true)) {
			MemberNumberFeature()
		} withDependencies: {
			$0.memberNumber = .fake(providers: [.apple], world: world, claim: { _, _, _ throws(MemberNumberFailure) in
				let attempt = attempts.withValue { $0 += 1; return $0 }
				if attempt == 1 { throw failure }
				return number
			})
		}

		await store.send(.ui(.claim(.apple))) {
			$0.status = .signingIn(.apple)
		}
		await store.receive(\.event.claimFinished) {
			$0.status = .failed(failure)
		}
		#expect(world.saved.value == nil)

		// Try Again.
		await store.send(.ui(.claim(.apple))) {
			$0.status = .signingIn(.apple)
		}
		await store.receive(\.event.claimFinished) {
			$0.status = .claimed(number)
		}
	}

	@Test
	internal func aCancelledSignInSendsNothing() async {
		let world: FakeWorld = .init()
		let store = TestStore(initialState: MemberNumberFeature.State(providers: [.apple], isLoaded: true)) {
			MemberNumberFeature()
		} withDependencies: {
			$0.memberNumber = .fake(providers: [.apple], world: world, signInFailure: .cancelled)
		}

		await store.send(.ui(.claim(.apple))) {
			$0.status = .signingIn(.apple)
		}
		await store.receive(\.event.claimFinished) {
			$0.status = .failed(.cancelled)
		}
		#expect(world.sentTokens.value.isEmpty)
		#expect(world.saved.value == nil)
	}

	@Test
	internal func aProviderThisBuildDoesntOfferIsIgnored() async {
		let store = TestStore(initialState: MemberNumberFeature.State(providers: [], isLoaded: true)) {
			MemberNumberFeature()
		} withDependencies: {
			$0.memberNumber = .fake(providers: [])
		}

		await store.send(.ui(.claim(.apple)))
	}

	@Test
	internal func theNumberComesBackAfterARelaunchWithoutAsking() async throws {
		let suite = "MemberNumberSettingsTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let number = number

		// The first launch claims and saves into the real store.
		let first = TestStore(initialState: MemberNumberFeature.State(providers: [.apple], isLoaded: true)) {
			MemberNumberFeature()
		} withDependencies: {
			var live: MemberNumberClient = .live(defaults: defaults)
			live.signIn = { _ throws(MemberNumberFailure) in "token" }
			live.claim = { _, _, _ throws(MemberNumberFailure) in number }
			$0.memberNumber = live
		}
		await first.send(.ui(.claim(.apple))) {
			$0.status = .signingIn(.apple)
		}
		await first.receive(\.event.claimFinished) {
			$0.status = .claimed(number)
		}

		// A relaunch: fresh state, the same defaults, and no sign-in allowed.
		let second = TestStore(initialState: SettingsFeature.State().memberNumber) {
			MemberNumberFeature()
		} withDependencies: {
			var live: MemberNumberClient = .live(defaults: defaults)
			live.availableProviders = { [.apple] }
			live.signIn = { _ throws(MemberNumberFailure) in
				Issue.record("A relaunch must not sign in")
				throw .unavailable
			}
			live.claim = { _, _, _ throws(MemberNumberFailure) in
				Issue.record("A relaunch must not call the server")
				throw .unavailable
			}
			$0.memberNumber = live
		}
		await second.send(.ui(.appeared)) {
			$0.isLoaded = true
			$0.providers = [.apple]
			$0.status = .claimed(number)
		}
	}
}

// MARK: - Fake

private final class FakeWorld: Sendable {
	internal let signIns: LockIsolated<[MemberSignInProvider]> = .init([])
	internal let sentTokens: LockIsolated<[String]> = .init([])
	internal let sentDays: LockIsolated<[String?]> = .init([])
	internal let saved: LockIsolated<MemberNumber?> = .init(nil)
}

extension AsyncStream {
	fileprivate struct Makeable: Sendable where Element: Sendable {
		internal let stream: AsyncStream<Element>
		internal let continuation: AsyncStream<Element>.Continuation

		internal init() {
			(stream, continuation) = AsyncStream.makeStream()
		}
	}
}

extension MemberNumberClient {
	fileprivate static func fake(
		providers: [MemberSignInProvider],
		world: FakeWorld = .init(),
		signInFailure: MemberNumberFailure? = nil,
		claim: @escaping @Sendable (MemberSignInProvider, String, String?) async throws(MemberNumberFailure) -> MemberNumber = { _, _, _ throws(MemberNumberFailure) in
			throw .refused
		}
	) -> Self {
		.init(
			availableProviders: { providers },
			signIn: { provider throws(MemberNumberFailure) in
				world.signIns.withValue { $0.append(provider) }
				if let signInFailure { throw signInFailure }
				return "token-\(provider.rawValue)"
			},
			claim: { provider, token, memberSince throws(MemberNumberFailure) in
				world.sentTokens.withValue { $0.append(token) }
				world.sentDays.withValue { $0.append(memberSince) }
				return try await claim(provider, token, memberSince)
			},
			load: { world.saved.value },
			save: { number in world.saved.setValue(number) }
		)
	}
}
