import BrowserCore
import Foundation
import Synchronization
import _Dependencies

/// Where Apple's web sign-in runs (DEV-1323): a private Little Arx window that AppFeature opens
/// and watches. `ASWebAuthenticationSession` can't be used, because with Arx as the default
/// browser macOS hands the sheet back to Arx at once.
///
/// The client asks with ``callback(from:scheme:)``. AppFeature reads ``events``, opens the
/// address in a window of its own, catches the navigation to `scheme` in that window only, and
/// answers with ``finish(_:with:)``: the address it caught, or why the sign-in ended without one.
/// The scheme is never registered with macOS, so no other app or window can deliver it.
public final class MemberSignInWindow: Sendable {
	/// One sign-in to open.
	public struct Request: Equatable, Sendable {
		public let id: UUID
		/// Apple's authorize address.
		public let url: URL
		/// The scheme Arx's server redirects to with Apple's answer, `dev.capturecontext.arx.auth`.
		public let scheme: String

		public init(
			id: UUID,
			url: URL,
			scheme: String
		) {
			self.id = id
			self.url = url
			self.scheme = scheme
		}
	}

	/// What AppFeature hears: a sign-in to open, or one the client stopped waiting for, whose
	/// window closes.
	public enum Event: Equatable, Sendable {
		case open(Request)
		case cancelled(UUID)
	}

	/// The sign-ins asked for and given up, in order. AppFeature reads it for the whole run.
	public let events: AsyncStream<Event>

	private let continuation: AsyncStream<Event>.Continuation
	private let state: Mutex<Waiting> = .init(.init())

	private struct Waiting: ~Copyable {
		var answers: [UUID: CheckedContinuation<Result<URL, MemberNumberFailure>, Never>] = [:]
		/// Answers that came before anyone waited for them.
		var early: [UUID: Result<URL, MemberNumberFailure>] = [:]
	}

	public init() {
		(events, continuation) = AsyncStream.makeStream()
	}

	/// Opens `url` in a sign-in window and returns the address the window reached with `scheme`.
	/// Throws `.cancelled` when the person closes the window, `.signInFailed` when it times out or
	/// another sign-in is open.
	public func callback(
		from url: URL,
		scheme: String
	) async throws(MemberNumberFailure) -> URL {
		try await answer(to: .init(id: UUID(), url: url, scheme: scheme)).get()
	}

	/// Asks for `request` and waits for its answer. Cancelling the wait is a cancel, and closes the
	/// window. Both events are sent under the same lock as the registration, so a cancel never
	/// reaches AppFeature before its open, and a request cancelled before it opened never opens.
	public func answer(to request: Request) async -> Result<URL, MemberNumberFailure> {
		await withTaskCancellationHandler {
			await withCheckedContinuation { waiting in
				let early: Result<URL, MemberNumberFailure>? = state.withLock { state in
					if let result = state.early.removeValue(forKey: request.id) { return result }
					state.answers[request.id] = waiting
					continuation.yield(.open(request))
					return nil
				}
				if let early { waiting.resume(returning: early) }
			}
		} onCancel: {
			let waiting = state.withLock { state in
				guard let waiting = state.answers.removeValue(forKey: request.id) else {
					if state.early[request.id] == nil { state.early[request.id] = .failure(.cancelled) }
					return nil as CheckedContinuation<Result<URL, MemberNumberFailure>, Never>?
				}
				continuation.yield(.cancelled(request.id))
				return waiting
			}
			waiting?.resume(returning: .failure(.cancelled))
		}
	}

	/// Ends the sign-in `id`. Only the first answer counts.
	public func finish(
		_ id: UUID,
		with result: Result<URL, MemberNumberFailure>
	) {
		let waiting = state.withLock { state in
			guard let waiting = state.answers.removeValue(forKey: id) else {
				if state.early[id] == nil { state.early[id] = result }
				return nil as CheckedContinuation<Result<URL, MemberNumberFailure>, Never>?
			}
			return waiting
		}
		waiting?.resume(returning: result)
	}
}

extension MemberSignInWindow: DependencyKey {
	/// One for the whole app: the client asks it and AppFeature answers.
	public static let liveValue: MemberSignInWindow = .init()

	public static var testValue: MemberSignInWindow { .init() }
}

extension DependencyValues {
	public var memberSignInWindow: MemberSignInWindow {
		get { self[MemberSignInWindow.self] }
		set { self[MemberSignInWindow.self] = newValue }
	}
}
