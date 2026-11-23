import CoreGraphics
import Foundation
import _ComposableArchitecture

/// The window server's view of this process's login session (DEV-596).
internal struct LoginSessionClient: Sendable {
	/// What the window server reports for the session this process is in.
	internal struct Session: Equatable, Sendable {
		/// Someone has logged in: a user's desktop, not the login window.
		internal var isLoginDone: Bool

		/// The session has the console, rather than being switched away from.
		internal var isOnConsole: Bool

		internal init(
			isLoginDone: Bool,
			isOnConsole: Bool
		) {
			self.isLoginDone = isLoginDone
			self.isOnConsole = isOnConsole
		}
	}

	/// Nil outside a Quartz GUI session: a plain SSH login with nobody at the console,
	/// a launchd daemon, or a disabled window server.
	internal var current: @Sendable () -> Session?

	internal init(current: @escaping @Sendable () -> Session?) {
		self.current = current
	}
}

extension LoginSessionClient: DependencyKey {
	internal static var liveValue: Self {
		.init(current: {
			guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
			else { return nil }

			// `CGSession.h` defines the keys with `CFSTR`, which Swift doesn't import.
			return .init(
				isLoginDone: dictionary["kCGSessionLoginDoneKey"] as? Bool ?? false,
				isOnConsole: dictionary["kCGSSessionOnConsoleKey"] as? Bool ?? false
			)
		})
	}

	internal static var testValue: Self {
		.init(current: unimplemented("LoginSessionClient.current", placeholder: nil))
	}
}

extension DependencyValues {
	internal var loginSession: LoginSessionClient {
		get { self[LoginSessionClient.self] }
		set { self[LoginSessionClient.self] = newValue }
	}
}

/// A headless run still hosts Chromium's compositor through WindowServer, so it needs
/// the user's logged-in GUI session, with or without a display (DEV-596). Checked
/// before the profile lock and the engine, so a run without one leaves nothing behind.
/// Running without a session is DEV-869.
internal enum HeadlessLoginSession {
	internal static let diagnosticPrefix: String = "ARX_HEADLESS_SESSION"

	/// Reports the session on stderr, then throws `loginSessionUnavailable` unless
	/// a user has logged in to it.
	internal static func check() throws(HeadlessFailure) {
		@Dependency(\.loginSession)
		var loginSession

		let session = loginSession.current()
		FileHandle.standardError.write(Data((diagnostic(session) + "\n").utf8))
		guard let session, session.isLoginDone
		else { throw .loginSessionUnavailable }
	}

	/// `ARX_HEADLESS_SESSION windowServer=… loginDone=… console=…`.
	internal static func diagnostic(_ session: LoginSessionClient.Session?) -> String {
		guard let session
		else { return "\(diagnosticPrefix) windowServer=false" }

		return "\(diagnosticPrefix) windowServer=true loginDone=\(session.isLoginDone) console=\(session.isOnConsole)"
	}
}
