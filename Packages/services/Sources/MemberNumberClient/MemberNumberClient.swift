import BrowserCore
import Foundation
import _Dependencies

/// Claims the identity card's member number (DEV-701): signs in with Apple, sends the ID
/// token once to Arx's server (`POST /v1/accounts`) and keeps the answer on this Mac.
///
/// Sign-in asks for no scopes beyond confirming the account: no name, no email. The server keeps
/// only a hash of the provider's account ID. Nothing from the sign-in is kept here: the token is
/// sent and dropped, and only the number, the days and the provider are saved. The sign-in sends
/// one thing besides the token: the day Arx was installed on this Mac (DEV-1323).
public struct MemberNumberClient: Sendable {
	/// The providers this build can sign in with: Apple when Info.plist names a Services ID.
	public var availableProviders: @Sendable () -> [MemberSignInProvider]

	/// Shows the provider's sign-in and returns its ID token.
	public var signIn: @MainActor @Sendable (MemberSignInProvider) async throws(Failure) -> String

	/// Sends the ID token to Arx's server, with the `yyyy-MM-dd` day Arx was installed on this Mac
	/// when there is one (DEV-1323), and returns the account's number and its member-since day.
	public var claim: @Sendable (MemberSignInProvider, String, String?) async throws(Failure) -> MemberNumber

	/// The number this Mac claimed before, if any.
	public var load: @Sendable () -> MemberNumber?

	/// Keeps the number on this Mac, or forgets it with `nil`.
	public var save: @Sendable (MemberNumber?) -> Void

	public init(
		availableProviders: @escaping @Sendable () -> [MemberSignInProvider],
		signIn: @escaping @MainActor @Sendable (MemberSignInProvider) async throws(Failure) -> String,
		claim: @escaping @Sendable (MemberSignInProvider, String, String?) async throws(Failure) -> MemberNumber,
		load: @escaping @Sendable () -> MemberNumber?,
		save: @escaping @Sendable (MemberNumber?) -> Void
	) {
		self.availableProviders = availableProviders
		self.signIn = signIn
		self.claim = claim
		self.load = load
		self.save = save
	}
}

// MARK: - Failure

extension MemberNumberClient {
	/// Why a claim didn't finish, in the words the card shows.
	public typealias Failure = MemberNumberFailure
}

// MARK: - Dependency

extension MemberNumberClient: DependencyKey {
	public static var liveValue: Self { .live() }

	/// Tests supply their own client, so an unexpected call fails the test.
	public static var testValue: Self {
		.init(
			availableProviders: unimplemented("MemberNumberClient.availableProviders", placeholder: []),
			signIn: { _ throws(Failure) in
				reportIssue("Unimplemented: MemberNumberClient.signIn")
				throw .unavailable
			},
			claim: { _, _, _ throws(Failure) in
				reportIssue("Unimplemented: MemberNumberClient.claim")
				throw .unavailable
			},
			load: unimplemented("MemberNumberClient.load", placeholder: nil),
			save: unimplemented("MemberNumberClient.save")
		)
	}

	/// Previews offer both providers and answer #42 without a network.
	public static var previewValue: Self {
		.init(
			availableProviders: { MemberSignInProvider.allCases },
			signIn: { _ throws(Failure) in "preview-token" },
			claim: { provider, _, memberSince throws(Failure) in
				.init(index: 42, registeredOn: "2026-11-18", provider: provider, memberSince: memberSince ?? "2026-11-18")
			},
			load: { nil },
			save: { _ in }
		)
	}
}

extension DependencyValues {
	public var memberNumber: MemberNumberClient {
		get { self[MemberNumberClient.self] }
		set { self[MemberNumberClient.self] = newValue }
	}
}
