import Foundation
import Security

/// Where each supported browser keeps its storage key in the login keychain (DEV-650).
///
/// Chromium reads a generic password with service `"<Brand> Safe Storage"` and account
/// `"<Brand>"` from the legacy, file-based keychain (`keychain_password_mac.mm`). Arx asks
/// for exactly one item per read and never probes alternatives, because each request for
/// an existing item can show macOS's access prompt.
public enum ChromiumSafeStorage {
	public struct Item: Equatable, Sendable {
		public var service: String
		public var account: String

		/// Confirmed against the browser's source or binary. Unverified names are still tried
		/// once; a wrong one reads as missing, which leads to the CSV import.
		public var isVerified: Bool

		public init(
			service: String,
			account: String,
			isVerified: Bool
		) {
			self.service = service
			self.account = account
			self.isVerified = isVerified
		}
	}

	/// The browser and where its profiles live, by migration source ID.
	public struct Browser: Equatable, Sendable {
		public var sourceID: MigrationSource.ID
		public var name: String
		public var item: Item

		/// Holds `Local State` and one folder per profile.
		public var userData: URL

		/// Opera keeps its one profile in `userData` itself (DEV-896).
		public var keepsDefaultProfileAtRoot: Bool

		public init(
			sourceID: MigrationSource.ID,
			name: String,
			item: Item,
			userData: URL,
			keepsDefaultProfileAtRoot: Bool = false
		) {
			self.sourceID = sourceID
			self.name = name
			self.item = item
			self.userData = userData
			self.keepsDefaultProfileAtRoot = keepsDefaultProfileAtRoot
		}

		/// The profiles `Local State` lists, or Opera's one profile.
		internal func profiles() -> [MigrationSourceProfile] {
			let localState = try? Data(contentsOf: userData.appending(path: "Local State"))
			let profiles = (try? ChromiumProfileLayout.profiles(
				localState: localState,
				keepsDefaultProfileAtRoot: keepsDefaultProfileAtRoot,
				name: name
			)) ?? []
			return profiles.filter { !$0.id.contains("/") && !$0.id.hasPrefix(".") }
		}

		internal func directory(profile: String) -> URL {
			ChromiumProfileLayout.directory(
				profile: profile,
				userData: userData,
				keepsDefaultProfileAtRoot: keepsDefaultProfileAtRoot
			)
		}
	}

	/// Google Chrome, from Chromium's `GOOGLE_CHROME_BRANDING` constants.
	public static let chrome: Item = .init(
		service: "Chrome Safe Storage",
		account: "Chrome",
		isVerified: true
	)

	/// Arc's item, confirmed on a Mac with Arc installed (DEV-831).
	public static let arc: Item = .init(
		service: "Arc Safe Storage",
		account: "Arc",
		isVerified: true
	)

	/// Brave, from brave-core's branding of Chromium's `keychain_password_mac.mm` constants.
	public static let brave: Item = .init(
		service: "Brave Safe Storage",
		account: "Brave",
		isVerified: true
	)

	/// Microsoft Edge, from Edge's branding of the same constants.
	public static let edge: Item = .init(
		service: "Microsoft Edge Safe Storage",
		account: "Microsoft Edge",
		isVerified: true
	)

	/// UNVERIFIED (DEV-650, DEV-831): Dia's item, assumed from Chromium's naming pattern.
	/// Check on a Mac with Dia installed, from Keychain Access's item list (names only),
	/// never by reading the item.
	public static let diaUnverified: Item = .init(
		service: "Dia Safe Storage",
		account: "Dia",
		isVerified: false
	)

	/// Helium's item, from its `change-keychain-name.patch` (DEV-896).
	public static let helium: Item = .init(
		service: "Helium Storage Key",
		account: "Helium",
		isVerified: true
	)

	/// Unbranded Chromium's item, from `keychain_password_mac.mm`.
	public static let chromium: Item = .init(
		service: "Chromium Safe Storage",
		account: "Chromium",
		isVerified: true
	)

	// The rest are assumed from Chromium's pattern (DEV-896) and checked like Dia's.

	/// UNVERIFIED: Brave's beta and nightly channels, assumed to share Brave's item.
	public static let braveChannelUnverified: Item = .init(
		service: brave.service,
		account: brave.account,
		isVerified: false
	)

	/// UNVERIFIED: Edge's beta, dev and canary channels, assumed to share Edge's item.
	public static let edgeChannelUnverified: Item = .init(
		service: edge.service,
		account: edge.account,
		isVerified: false
	)

	public static let operaUnverified: Item = .init(
		service: "Opera Safe Storage",
		account: "Opera",
		isVerified: false
	)

	public static let operaGXUnverified: Item = .init(
		service: "Opera GX Safe Storage",
		account: "Opera GX",
		isVerified: false
	)

	public static let vivaldiUnverified: Item = .init(
		service: "Vivaldi Safe Storage",
		account: "Vivaldi",
		isVerified: false
	)

	public static let islandUnverified: Item = .init(
		service: "Island Safe Storage",
		account: "Island",
		isVerified: false
	)

	/// Arc, then every browser in `ChromiumBrowser.all`.
	public static func browsers(
		home: URL = FileManager.default.homeDirectoryForCurrentUser
	) -> [Browser] {
		let arc: Browser = .init(
			sourceID: .init(rawValue: "arc"),
			name: "Arc",
			item: arc,
			userData: home.appending(path: "Library/Application Support/Arc/User Data", directoryHint: .isDirectory)
		)
		return [arc] + ChromiumBrowser.all.map { browser in
			.init(
				sourceID: browser.id,
				name: browser.name,
				item: browser.safeStorage,
				userData: browser.userData(home: home),
				keepsDefaultProfileAtRoot: browser.keepsDefaultProfileAtRoot
			)
		}
	}

	/// Why the key couldn't be read.
	public enum KeyFailure: Error, Equatable, Sendable {
		/// Deny or Cancel in macOS's prompt.
		case denied

		/// No such item, or one Arx can't see (the data protection keychain).
		case missing
		case failed(Int32)
	}

	/// Reads one item's secret. This is the call that makes macOS ask the user; only
	/// the credentials step calls it, after explaining the prompt.
	public static func readSecret(_ item: Item) throws(KeyFailure) -> Data {
		// No kSecUseDataProtectionKeychain: Chromium keeps the item in the legacy keychain.
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: item.service,
			kSecAttrAccount as String: item.account,
			kSecMatchLimit as String: kSecMatchLimitOne,
			kSecReturnData as String: true,
		]
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		switch status {
		case errSecSuccess:
			guard let data = result as? Data, !data.isEmpty else { throw .missing }

			return data

		case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
			throw .denied

		case errSecItemNotFound:
			throw .missing

		default:
			throw .failed(status)
		}
	}
}
