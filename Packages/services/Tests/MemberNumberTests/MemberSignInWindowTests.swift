import BrowserCore
import Foundation
import MemberNumberClient
import Testing

/// DEV-1323: the broker between the member number's sign-in and the window AppFeature opens.
internal struct MemberSignInWindowTests {
	private static let authorize: URL = URL(string: "https://appleid.apple.com/auth/authorize")!
	private static let callback: URL = URL(string: "dev.capturecontext.arx.auth:/apple?state=s")!

	@Test
	internal func theWindowsAnswerReachesTheSignIn() async throws {
		let window: MemberSignInWindow = .init()
		let signIn: Task<URL, any Error> = Task {
			try await window.callback(from: Self.authorize, scheme: "dev.capturecontext.arx.auth")
		}

		var events = window.events.makeAsyncIterator()
		guard case let .open(request) = try #require(await events.next()) else {
			Issue.record("Expected a sign-in to open")
			return
		}
		#expect(request.url == Self.authorize)
		#expect(request.scheme == "dev.capturecontext.arx.auth")

		window.finish(request.id, with: .success(Self.callback))
		// Only the first answer counts.
		window.finish(request.id, with: .failure(.signInFailed))
		#expect(try await signIn.value == Self.callback)
	}

	@Test(arguments: [MemberNumberFailure.cancelled, .signInFailed])
	internal func aWindowWithoutAnAnswerFailsTheSignIn(failure: MemberNumberFailure) async throws {
		let window: MemberSignInWindow = .init()
		let signIn: Task<URL, any Error> = Task {
			try await window.callback(from: Self.authorize, scheme: "dev.capturecontext.arx.auth")
		}

		var events = window.events.makeAsyncIterator()
		guard case let .open(request) = try #require(await events.next()) else {
			Issue.record("Expected a sign-in to open")
			return
		}
		window.finish(request.id, with: .failure(failure))
		await #expect(throws: failure) { try await signIn.value }
	}

	@Test
	internal func anAnswerBeforeTheWaitIsKept() async {
		let window: MemberSignInWindow = .init()
		let request: MemberSignInWindow.Request = .init(id: UUID(), url: Self.authorize, scheme: "dev.capturecontext.arx.auth")
		window.finish(request.id, with: .success(Self.callback))
		#expect(await window.answer(to: request) == .success(Self.callback))
	}

	@Test
	internal func cancellingTheSignInIsACancel() async throws {
		let window: MemberSignInWindow = .init()
		let signIn: Task<URL, any Error> = Task {
			try await window.callback(from: Self.authorize, scheme: "dev.capturecontext.arx.auth")
		}
		var events = window.events.makeAsyncIterator()
		guard case let .open(request) = try #require(await events.next()) else {
			Issue.record("Expected a sign-in to open")
			return
		}
		signIn.cancel()
		await #expect(throws: MemberNumberFailure.cancelled) { try await signIn.value }
		// Its window hears it, and closes.
		#expect(await events.next() == .cancelled(request.id))
	}
}
