import Foundation

/// A browser whose passwords or sign-ins the credentials step reads directly (DEV-650,
/// DEV-896), and where they are.
public struct CredentialBrowser: Equatable, Sendable {
	public enum Store: Equatable, Sendable {
		/// Encrypted with a key in the login keychain; reading it shows macOS's prompt.
		case chromium(ChromiumSafeStorage.Browser)

		/// Firefox or Zen: `profiles.ini` in this folder, each profile's `key4.db`,
		/// `logins.json` and `cookies.sqlite`. No prompt unless the profile has a primary
		/// password, which Arx doesn't ask for.
		case mozilla(root: URL)

		/// Safari's `Cookies.binarycookies` in this home folder, read with Full Disk Access.
		/// Safari's passwords are in the Passwords app, which other apps can't read.
		case safari(home: URL)
	}

	public var sourceID: MigrationSource.ID
	public var name: String
	public var store: Store

	public init(
		sourceID: MigrationSource.ID,
		name: String,
		store: Store
	) {
		self.sourceID = sourceID
		self.name = name
		self.store = store
	}

	public init(_ chromium: ChromiumSafeStorage.Browser) {
		self.init(sourceID: chromium.sourceID, name: chromium.name, store: .chromium(chromium))
	}

	/// Every browser the step can read on this Mac: the Chromium ones, Firefox, Zen and Safari.
	public static func all(
		home: URL = FileManager.default.homeDirectoryForCurrentUser
	) -> [Self] {
		let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
		let mozilla: [Self] = MigrationBrowserSources.MozillaBrowser.allCases.map { browser in
			.init(
				sourceID: .init(rawValue: browser.rawValue),
				name: browser.name,
				store: .mozilla(root: support.appending(path: browser.folder, directoryHint: .isDirectory))
			)
		}
		let safari: Self = .init(sourceID: .safari, name: "Safari", store: .safari(home: home))
		return ChromiumSafeStorage.browsers(home: home).map(Self.init) + mozilla + [safari]
	}

	internal var access: CredentialSource.Access {
		switch store {
		case let .chromium(browser): .keychain(service: browser.item.service, isVerified: browser.item.isVerified)
		case .mozilla: .profileFiles
		case .safari: .fullDiskAccess
		}
	}

	/// The source profiles whose credentials can be read.
	internal func profiles() -> [MigrationSourceProfile] {
		switch store {
		case let .chromium(browser):
			return browser.profiles()

		case let .mozilla(root):
			return mozillaProfiles(root: root).compactMap { profile in
				let hasLogins = ["logins.json", "cookies.sqlite"].contains { name in
					FileManager.default.fileExists(atPath: profile.directory.appending(path: name).path(percentEncoded: false))
				}
				return hasLogins ? .init(id: profile.id, name: profile.name) : nil
			}

		case let .safari(home):
			let hasCookies = SafariCookies.files(home: home).contains {
				FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
			}
			return hasCookies ? [SafariData.defaultProfile] : []
		}
	}

	/// A listed Firefox or Zen profile's folder.
	internal func mozillaDirectory(
		profile id: String,
		root: URL
	) -> URL? {
		mozillaProfiles(root: root).first { $0.id == id }?.directory
	}

	private func mozillaProfiles(root: URL) -> [FirefoxPlaces.Profile] {
		guard let ini = try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8)
		else { return [] }

		return FirefoxPlaces.profiles(ini: ini, root: root)
	}
}
