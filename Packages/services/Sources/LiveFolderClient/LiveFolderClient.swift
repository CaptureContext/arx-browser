import BrowserCore
import Foundation
import _Dependencies

/// Fetches a live folder's items from its source (DEV-926).
///
/// Every source needs an account with its service, and signing in is the user's decision,
/// so the client takes accounts through `LiveFolderAccounts`, a seam that holds none until
/// the app supplies them. Without one, a fetch fails with `notSignedIn` and nothing leaves
/// the Mac.
public struct LiveFolderClient: Sendable {
	/// Whether the source's service has an account, so a refresh would ask it.
	public var isAvailable: @Sendable (LiveFolderSource) async -> Bool

	/// The source's items, in the order the service gives them.
	public var fetch: @Sendable (LiveFolderSource) async throws(LiveFolderFailure) -> [LiveFolderItem]

	public init(
		isAvailable: @escaping @Sendable (LiveFolderSource) async -> Bool,
		fetch: @escaping @Sendable (LiveFolderSource) async throws(LiveFolderFailure) -> [LiveFolderItem]
	) {
		self.isAvailable = isAvailable
		self.fetch = fetch
	}
}

/// The accounts live folders use, by service: a token the service accepts, or nil.
///
/// This is where an account decision plugs in: a token the user pastes and Arx keeps in its
/// own Keychain item, a GitHub app's sign-in, or none. Arx ships with `none` until that's
/// decided (DEV-926).
public struct LiveFolderAccounts: Sendable {
	public var token: @Sendable (LiveFolderService) async -> String?

	public init(token: @escaping @Sendable (LiveFolderService) async -> String?) {
		self.token = token
	}

	public static let none: Self = .init { _ in nil }
}

/// One HTTP exchange, so tests answer without a network.
public typealias LiveFolderTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

extension LiveFolderClient {
	/// Fetches from each source's service with the account `accounts` gives for it.
	public static func running(
		accounts: LiveFolderAccounts,
		transport: @escaping LiveFolderTransport
	) -> Self {
		.init(
			isAvailable: { source in await accounts.token(source.service) != nil },
			fetch: { source throws(LiveFolderFailure) in
				guard let token = await accounts.token(source.service), !token.isEmpty
				else { throw .notSignedIn }

				switch source {
				case let .gitHubPullRequests(filter):
					let (data, response): (Data, URLResponse)
					do {
						(data, response) = try await transport(GitHubPullRequests.request(filter, token: token))
					} catch {
						throw .unreachable
					}
					return try GitHubPullRequests.items(data, response: response)
				}
			}
		)
	}

	/// A transport without cookies, caches or stored credentials: only the token a request
	/// carries authenticates it.
	public static var ephemeralTransport: LiveFolderTransport {
		let configuration: URLSessionConfiguration = .ephemeral
		configuration.httpCookieStorage = nil
		configuration.httpShouldSetCookies = false
		configuration.urlCredentialStorage = nil
		configuration.urlCache = nil
		let session = URLSession(configuration: configuration)
		return { request in try await session.data(for: request) }
	}
}

extension LiveFolderClient: DependencyKey {
	/// No accounts yet: every live folder reports `notSignedIn` (DEV-926).
	public static var liveValue: Self {
		.running(accounts: .none, transport: ephemeralTransport)
	}

	public static var testValue: Self {
		.init(
			isAvailable: { _ in false },
			fetch: { _ throws(LiveFolderFailure) in throw .notSignedIn }
		)
	}

	public static var previewValue: Self { testValue }
}

extension DependencyValues {
	public var liveFolders: LiveFolderClient {
		get { self[LiveFolderClient.self] }
		set { self[LiveFolderClient.self] = newValue }
	}
}
