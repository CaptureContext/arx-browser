#if DEBUG
import BrowserCore
import Foundation
import MemberNumberClient
import _ComposableArchitecture

/// The app smoke's `member-sign-in` phase (DEV-1323). Needs an ABI50 engine
/// (`external_link_requested`).
///
/// The member number's sign-in opens `member-sign-in.html` on `localhost` in its private Little
/// Arx. The page posts a form at once, without a click, to `127.0.0.1`, another site, which
/// answers 303 to `dev.capturecontext.arx.auth:` as Arx's server answers Apple. The sign-in must
/// get exactly that address back, the window must close and its profile go, and no prompt for
/// another app may appear.
@MainActor
internal enum MemberSignInSmoke {
	internal static let callback: String = "dev.capturecontext.arx.auth:/apple?error=cancelled&state=arx-smoke"

	internal static func run(
		store: StoreOf<AppFeature>,
		baseURL: URL
	) async throws {
		guard
			var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.host == "127.0.0.1"
		else { throw Failure.invalidFixture }

		parts.host = "localhost"
		parts.path = "/member-sign-in.html"
		parts.query = nil
		guard let page = parts.url else { throw Failure.invalidFixture }

		@Dependency(\.memberSignInWindow)
		var window

		let windowsBefore = Set(store.littleWindows.ids)
		let signIn: Task<URL, any Error> = Task {
			try await window.callback(from: page, scheme: "dev.capturecontext.arx.auth")
		}

		// The window opens as a private Little Arx of its own.
		var opened: MemberSignInSession?
		for _ in 0..<500 where opened == nil {
			if let session = store.memberSignIn, session.isOpen { opened = session }
			try await Task.sleep(for: .milliseconds(20))
		}
		guard
			let session = opened,
			let profileID = store.privateLittleArxProfiles[session.windowID],
			store.workspace.profiles[id: profileID] == nil,
			store.littleWindows[id: session.windowID]?.isPrivate == true
		else {
			signIn.cancel()
			throw Failure.notOpened
		}

		// Twenty seconds for the post and the 303; then the sign-in is cancelled, which closes
		// its window, and the phase fails.
		let deadline: ContinuousClock.Instant = .now + .seconds(20)
		while store.memberSignIn != nil, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(100))
		}
		if store.memberSignIn != nil { signIn.cancel() }
		let answer: URL
		do {
			answer = try await signIn.value
		} catch {
			FileHandle.standardError.write(Data("ARX_MEMBER_SIGN_IN_SMOKE_NO_ANSWER \(error)\n".utf8))
			throw Failure.noAnswer
		}
		guard answer.absoluteString == callback else { throw Failure.wrongAnswer }

		// Closed, released, and no prompt for another app.
		guard
			store.memberSignIn == nil,
			store.littleWindows[id: session.windowID] == nil,
			store.privateLittleArxProfiles[session.windowID] == nil,
			Set(store.littleWindows.ids) == windowsBefore,
			store.appLinkPrompt == nil
		else { throw Failure.leftOpen }

		print("ARX_MEMBER_SIGN_IN_SMOKE_SUCCESS")
	}

	private enum Failure: Error {
		case invalidFixture
		case notOpened
		case noAnswer
		case wrongAnswer
		case leftOpen
	}
}
#endif
