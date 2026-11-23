import BrowserCore
import BrowserEngineClient
import Foundation
import MemberNumberClient
import Testing
import _ComposableArchitecture

@testable import AppFeature
@testable import LittleArxFeature

/// DEV-1323: Apple's sign-in for the member number in a private Little Arx. The window gets a
/// private profile of its own, only it can deliver the sign-in scheme, its answer goes back to
/// the client, and closing it, a timeout or a second sign-in fail the way the card words them.
@Suite(.dependencies)
@MainActor
internal struct MemberSignInWindowTests {
	private static let authorize: URL = URL(string: "https://appleid.apple.com/auth/authorize?state=s")!
	private static let scheme: String = "dev.capturecontext.arx.auth"

	@Test
	internal func theSignInOpensInAPrivateLittleArxAndItsAnswerGoesBack() async throws {
		let world: World = .init()
		let store = Self.store(world: world)
		let request: MemberSignInWindow.Request = .init(id: UUID(), url: Self.authorize, scheme: Self.scheme)
		let answer: Task<Result<URL, MemberNumberFailure>, Never> = world.waitForAnswer(request)

		await store.send(.memberSignIn(.requested(request)))
		await store.receive(\.privateLittleArx.delegate.opened)

		let session: MemberSignInSession = try #require(store.state.memberSignIn)
		let tab: BrowserCore.Tab? = store.state.littleWindows[id: session.windowID]?.tab
		#expect(session.isOpen)
		let little: LittleArxFeature.State = try #require(store.state.littleWindows[id: session.windowID])
		let profileID: Profile.ID = little.tab.profileID
		#expect(world.prepared.value == [profileID])
		#expect(little.isPrivate)
		#expect(store.state.privateLittleArxProfiles[session.windowID] == profileID)
		#expect(little.tab.restoration.url == Self.authorize)
		#expect(little.commandContext.isPrivate)
		// The private profile never joins the workspace.
		#expect(store.state.workspace.profiles[id: profileID] == nil)
		#expect(store.state.focusedWindowID == session.windowID)

		let callback: URL = URL(string: "dev.capturecontext.arx.auth:/apple?state=s&id_token=t")!
		await store.send(.memberSignIn(.answered(callback)))
		await store.receive(\.privateLittleArx.close)
		#expect(await answer.value == .success(callback))
		#expect(store.state.memberSignIn == nil)
		#expect(store.state.littleWindows[id: session.windowID] == nil)
		#expect(store.state.privateLittleArxProfiles.isEmpty)
		await store.finish()
		#expect(world.closed.value == [little.tab.id])
		#expect(world.released.value == [profileID])
	}

	@Test
	internal func closingTheWindowIsACancel() async throws {
		let world: World = .init()
		let store = Self.store(world: world)
		let request: MemberSignInWindow.Request = .init(id: UUID(), url: Self.authorize, scheme: Self.scheme)
		let answer: Task<Result<URL, MemberNumberFailure>, Never> = world.waitForAnswer(request)

		await store.send(.memberSignIn(.requested(request)))
		await store.receive(\.privateLittleArx.delegate.opened)
		let session: MemberSignInSession = try #require(store.state.memberSignIn)
		let tab: BrowserCore.Tab? = store.state.littleWindows[id: session.windowID]?.tab
		let little: LittleArxFeature.State = try #require(store.state.littleWindows[id: session.windowID])
		let closing: LittleArxFeature.CloseRequest = .init(id: UUID(), window: little)

		await store.send(.littleWindows(.element(id: session.windowID, action: .delegate(.closeApproved(closing)))))
		#expect(await answer.value == .failure(.cancelled))
		#expect(store.state.memberSignIn == nil)
		await store.finish()
		#expect(world.released.value == [tab!.profileID])
	}

	@Test
	internal func aSignInTheClientGaveUpOnClosesItsWindow() async throws {
		let world: World = .init()
		let store = Self.store(world: world)
		let request: MemberSignInWindow.Request = .init(id: UUID(), url: Self.authorize, scheme: Self.scheme)
		_ = world.waitForAnswer(request)

		await store.send(.memberSignIn(.requested(request)))
		await store.receive(\.privateLittleArx.delegate.opened)
		let session: MemberSignInSession = try #require(store.state.memberSignIn)
		let tab: BrowserCore.Tab? = store.state.littleWindows[id: session.windowID]?.tab

		await store.send(.memberSignIn(.abandoned(request.id)))
		await store.receive(\.privateLittleArx.close)
		#expect(store.state.memberSignIn == nil)
		#expect(store.state.littleWindows[id: session.windowID] == nil)
		await store.finish()
		#expect(world.closed.value == [tab!.id])
		#expect(world.released.value == [tab!.profileID])
	}

	@Test
	internal func aProfileReadyAfterTheSignInWasAbandonedIsReleased() async {
		let world: World = .init()
		let store = Self.store(world: world)
		let late: Profile.ID = .init(rawValue: UUID())

		await store.send(.privateLittleArx(.profileReady(UUID(), late)))
		await store.finish()
		#expect(world.released.value == [late])
		#expect(store.state.littleWindows.isEmpty)
	}

	@Test
	internal func tenMinutesWithoutAnAnswerIsAFailedSignIn() async throws {
		let world: World = .init()
		let clock: TestClock<Duration> = .init()
		let store = Self.store(world: world, clock: clock)
		let request: MemberSignInWindow.Request = .init(id: UUID(), url: Self.authorize, scheme: Self.scheme)
		let answer: Task<Result<URL, MemberNumberFailure>, Never> = world.waitForAnswer(request)

		await store.send(.memberSignIn(.requested(request)))
		await store.receive(\.privateLittleArx.delegate.opened)
		let session: MemberSignInSession = try #require(store.state.memberSignIn)
		let tab: BrowserCore.Tab? = store.state.littleWindows[id: session.windowID]?.tab

		await clock.advance(by: MemberSignInWindows.timeout)
		await store.receive(\.memberSignIn.timedOut)
		await store.receive(\.privateLittleArx.close)
		#expect(await answer.value == .failure(.signInFailed))
		#expect(store.state.littleWindows[id: session.windowID] == nil)
		await store.finish()
		#expect(world.released.value == [tab!.profileID])
	}

	@Test
	internal func aSecondSignInWhileOneIsOpenFails() async throws {
		let world: World = .init()
		let store = Self.store(world: world)
		let first: MemberSignInWindow.Request = .init(id: UUID(), url: Self.authorize, scheme: Self.scheme)
		let second: MemberSignInWindow.Request = .init(id: UUID(), url: Self.authorize, scheme: Self.scheme)
		_ = world.waitForAnswer(first)
		let answer: Task<Result<URL, MemberNumberFailure>, Never> = world.waitForAnswer(second)

		await store.send(.memberSignIn(.requested(first)))
		await store.receive(\.privateLittleArx.delegate.opened)
		await store.send(.memberSignIn(.requested(second)))
		#expect(await answer.value == .failure(.signInFailed))
		#expect(store.state.memberSignIn?.requestID == first.id)
		#expect(store.state.littleWindows.count == 1)
		await store.send(.memberSignIn(.answered(URL(string: "dev.capturecontext.arx.auth:/apple")!)))
		await store.finish()
	}

	@Test
	internal func aProfileThatCantBePreparedFails() async {
		let world: World = .init()
		let store = Self.store(world: world, preparing: false)
		let request: MemberSignInWindow.Request = .init(id: UUID(), url: Self.authorize, scheme: Self.scheme)
		let answer: Task<Result<URL, MemberNumberFailure>, Never> = world.waitForAnswer(request)

		await store.send(.memberSignIn(.requested(request)))
		await store.receive(\.privateLittleArx.delegate.failed)
		#expect(await answer.value == .failure(.signInFailed))
		#expect(store.state.memberSignIn == nil)
		#expect(store.state.littleWindows.isEmpty)
	}

	@Test
	internal func onlyTheSignInWindowDeliversItsScheme() async throws {
		let world: World = .init()
		let store = Self.store(world: world)
		let request: MemberSignInWindow.Request = .init(id: UUID(), url: Self.authorize, scheme: Self.scheme)
		_ = world.waitForAnswer(request)
		let callback: String = "dev.capturecontext.arx.auth:/apple?error=cancelled&state=s"

		// Before the window is open, nothing is taken.
		await store.send(.memberSignIn(.requested(request)))
		#expect(store.state.memberSignIn?.isOpen == false)
		#expect(store.state.memberSignInLink(Self.link(callback, tab: .init(rawValue: UUID()), profile: .init(rawValue: UUID()))) == nil)

		await store.receive(\.privateLittleArx.delegate.opened)
		let session: MemberSignInSession = try #require(store.state.memberSignIn)
		let tab: BrowserCore.Tab? = store.state.littleWindows[id: session.windowID]?.tab
		let state: AppFeature.State = store.state

		// The window's own page, in its own profile, with the sign-in scheme in any case.
		let taken = state.memberSignInLink(Self.link(callback, tab: tab!.id, profile: tab!.profileID))
		#expect(taken == .answer(URL(string: callback)!))
		let upper = state.memberSignInLink(Self.link("DEV.CaptureContext.Arx.Auth:/apple", tab: tab!.id, profile: tab!.profileID))
		#expect(upper == .answer(URL(string: "DEV.CaptureContext.Arx.Auth:/apple")!))

		// Another app's link from the window is dropped, never offered.
		#expect(state.memberSignInLink(Self.link("zoommtg://join", tab: tab!.id, profile: tab!.profileID)) == .drop)
		#expect(state.memberSignInLink(Self.link("not a link", tab: tab!.id, profile: tab!.profileID)) == .drop)

		// Any other window, or a page in another profile, can't deliver it.
		let otherTab: BrowserCore.Tab.ID = .init(rawValue: UUID())
		#expect(state.memberSignInLink(Self.link(callback, tab: otherTab, profile: tab!.profileID)) == nil)
		let otherProfile: Profile.ID = .init(rawValue: UUID())
		#expect(state.memberSignInLink(Self.link(callback, tab: tab!.id, profile: otherProfile)) == nil)

		await store.send(.memberSignIn(.answered(URL(string: callback)!)))
		await store.finish()
	}

	@Test
	internal func theSignInWindowKeepsNothingAndMovesNowhere() {
		let tab: BrowserCore.Tab = .init(
			id: .init(rawValue: UUID()),
			profileID: .init(rawValue: UUID()),
			restoration: .init(title: "Apple", url: Self.authorize)
		)
		var little: LittleArxFeature.State = .init(
			id: UUID(),
			spaceID: .init(rawValue: UUID()),
			tab: tab,
			isCommandOnly: false,
			bangs: .empty,
			captureAvailable: true,
			downloadsAvailable: true,
			mediaAvailable: true,
			launcherSuggestions: []
		)
		#expect(!little.commandContext.isPrivate)
		little.isPrivate = true
		// No command that keeps or moves a private page.
		#expect(little.commandContext.isPrivate)
		#expect(!BrowserCommand.routeCurrentURL.isEnabled(in: little.commandContext))
	}

	// MARK: - Helpers

	private static func link(
		_ text: String,
		tab: BrowserCore.Tab.ID,
		profile: Profile.ID
	) -> BrowserExternalLink {
		BrowserExternalLink(
			sourceTabID: tab,
			profileID: profile,
			isPrivate: true,
			sourceDocumentRevision: 1,
			link: text,
			sourceOrigin: "https://api.arxbrowser.net",
			hasUserGesture: false,
			isRedirect: true
		)
	}

	private static func store(
		world: World,
		clock: TestClock<Duration> = .init(),
		preparing: Bool = true
	) -> TestStore<AppFeature.State, AppFeature.Action> {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let initial: AppFeature.State = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: initial) {
			CombineReducers {
				PrivateLittleArx()
				MemberSignInWindows()
			}
		} withDependencies: {
			$0.uuid = UUIDGenerator { UUID() }
			$0.continuousClock = clock
			$0.memberSignInWindow = world.window
			$0.browserEngine.preparePrivateProfile = { profile, opener in
				guard preparing else { throw CancellationError() }
				#expect(opener == nil)
				world.prepared.withValue { $0.append(profile) }
			}
			$0.browserEngine.releasePrivateProfile = { profile in world.released.withValue { $0.append(profile) } }
			$0.browserEngine.close = { tab in world.closed.withValue { $0.append(tab) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}

/// The engine and the client's side of the broker, recorded.
private final class World: Sendable {
	internal let window: MemberSignInWindow = .init()
	internal let prepared: LockIsolated<[Profile.ID]> = .init([])
	internal let released: LockIsolated<[Profile.ID]> = .init([])
	internal let closed: LockIsolated<[BrowserCore.Tab.ID]> = .init([])

	/// What the client would get for `request`, whose answer the reducer gives by its ID.
	internal func waitForAnswer(_ request: MemberSignInWindow.Request) -> Task<Result<URL, MemberNumberFailure>, Never> {
		return Task { [window] in await window.answer(to: request) }
	}
}
