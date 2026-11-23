import Foundation

/// A Chromium-based browser described as data, read by the generic Chromium adapter and
/// the passwords and sign-ins step (DEV-896).
///
/// Adding a browser or a channel means adding a row to `ChromiumBrowser.all`: where its
/// user data lives, its app's bundle identifier and its Keychain item.
public struct ChromiumBrowser: Equatable, Sendable {
	public var id: MigrationSource.ID
	public var name: String
	public var applicationIdentifier: String

	/// The user data folder, relative to `~/Library/Application Support`. It holds
	/// `Local State` and, usually, one folder per profile.
	public var userDataPath: String
	public var safeStorage: ChromiumSafeStorage.Item

	/// Whether a hand check against the real browser confirmed the reader (DEV-651).
	/// Unchecked browsers are offered only with the unchecked sources switch.
	public var isChecked: Bool

	/// Opera keeps its one profile in the user data folder itself instead of `Default`.
	public var keepsDefaultProfileAtRoot: Bool

	public init(
		id: MigrationSource.ID,
		name: String,
		applicationIdentifier: String,
		userDataPath: String,
		safeStorage: ChromiumSafeStorage.Item,
		isChecked: Bool = false,
		keepsDefaultProfileAtRoot: Bool = false
	) {
		self.id = id
		self.name = name
		self.applicationIdentifier = applicationIdentifier
		self.userDataPath = userDataPath
		self.safeStorage = safeStorage
		self.isChecked = isChecked
		self.keepsDefaultProfileAtRoot = keepsDefaultProfileAtRoot
	}

	/// The profile Opera keeps at the root of its user data folder.
	internal static let defaultProfileID: String = "Default"

	/// The user data folder in `home`.
	public func userData(home: URL) -> URL {
		home
			.appending(path: "Library/Application Support", directoryHint: .isDirectory)
			.appending(path: userDataPath, directoryHint: .isDirectory)
	}
}

extension ChromiumBrowser {
	/// Every Chromium browser Arx reads except Arc, whose sidebar has an adapter of its own.
	/// Checked ones first, then the rest in the order onboarding lists them.
	public static let all: [Self] = [
		dia,
		chrome,
		chromeBeta,
		chromeDev,
		chromeCanary,
		brave,
		braveBeta,
		braveNightly,
		edge,
		edgeBeta,
		edgeDev,
		edgeCanary,
		helium,
		chromium,
		opera,
		operaGX,
		vivaldi,
		island,
	]

	public static let dia: Self = .init(
		id: .init(rawValue: "dia"),
		name: "Dia",
		applicationIdentifier: "company.thebrowser.dia",
		userDataPath: "Dia/User Data",
		safeStorage: ChromiumSafeStorage.diaUnverified,
		isChecked: true
	)

	// MARK: Google Chrome

	/// Every Chrome channel shares Chrome's Keychain item: `GOOGLE_CHROME_BRANDING` sets
	/// it without a channel. Each channel's folder is its `CrProductDirName`.
	public static let chrome: Self = .init(
		id: .init(rawValue: "chrome"),
		name: "Google Chrome",
		applicationIdentifier: "com.google.Chrome",
		userDataPath: "Google/Chrome",
		safeStorage: ChromiumSafeStorage.chrome,
		isChecked: true
	)

	public static let chromeBeta: Self = .init(
		id: .init(rawValue: "chrome-beta"),
		name: "Google Chrome Beta",
		applicationIdentifier: "com.google.Chrome.beta",
		userDataPath: "Google/Chrome Beta",
		safeStorage: ChromiumSafeStorage.chrome
	)

	public static let chromeDev: Self = .init(
		id: .init(rawValue: "chrome-dev"),
		name: "Google Chrome Dev",
		applicationIdentifier: "com.google.Chrome.dev",
		userDataPath: "Google/Chrome Dev",
		safeStorage: ChromiumSafeStorage.chrome
	)

	public static let chromeCanary: Self = .init(
		id: .init(rawValue: "chrome-canary"),
		name: "Google Chrome Canary",
		applicationIdentifier: "com.google.Chrome.canary",
		userDataPath: "Google/Chrome Canary",
		safeStorage: ChromiumSafeStorage.chrome
	)

	// MARK: Brave

	public static let brave: Self = .init(
		id: .init(rawValue: "brave"),
		name: "Brave",
		applicationIdentifier: "com.brave.Browser",
		userDataPath: "BraveSoftware/Brave-Browser",
		safeStorage: ChromiumSafeStorage.brave
	)

	public static let braveBeta: Self = .init(
		id: .init(rawValue: "brave-beta"),
		name: "Brave Beta",
		applicationIdentifier: "com.brave.Browser.beta",
		userDataPath: "BraveSoftware/Brave-Browser-Beta",
		safeStorage: ChromiumSafeStorage.braveChannelUnverified
	)

	/// Brave's canary channel is called Nightly.
	public static let braveNightly: Self = .init(
		id: .init(rawValue: "brave-nightly"),
		name: "Brave Nightly",
		applicationIdentifier: "com.brave.Browser.nightly",
		userDataPath: "BraveSoftware/Brave-Browser-Nightly",
		safeStorage: ChromiumSafeStorage.braveChannelUnverified
	)

	// MARK: Microsoft Edge

	public static let edge: Self = .init(
		id: .init(rawValue: "edge"),
		name: "Microsoft Edge",
		applicationIdentifier: "com.microsoft.edgemac",
		userDataPath: "Microsoft Edge",
		safeStorage: ChromiumSafeStorage.edge
	)

	public static let edgeBeta: Self = .init(
		id: .init(rawValue: "edge-beta"),
		name: "Microsoft Edge Beta",
		applicationIdentifier: "com.microsoft.edgemac.Beta",
		userDataPath: "Microsoft Edge Beta",
		safeStorage: ChromiumSafeStorage.edgeChannelUnverified
	)

	public static let edgeDev: Self = .init(
		id: .init(rawValue: "edge-dev"),
		name: "Microsoft Edge Dev",
		applicationIdentifier: "com.microsoft.edgemac.Dev",
		userDataPath: "Microsoft Edge Dev",
		safeStorage: ChromiumSafeStorage.edgeChannelUnverified
	)

	public static let edgeCanary: Self = .init(
		id: .init(rawValue: "edge-canary"),
		name: "Microsoft Edge Canary",
		applicationIdentifier: "com.microsoft.edgemac.Canary",
		userDataPath: "Microsoft Edge Canary",
		safeStorage: ChromiumSafeStorage.edgeChannelUnverified
	)

	// MARK: Others

	/// Helium's folder, bundle identifier and Keychain item come from its own patches
	/// (`change-product-dir-name.patch`, `change-keychain-name.patch`), the engine Arx
	/// builds on.
	public static let helium: Self = .init(
		id: .init(rawValue: "helium"),
		name: "Helium",
		applicationIdentifier: "net.imput.helium",
		userDataPath: "net.imput.helium",
		safeStorage: ChromiumSafeStorage.helium
	)

	/// Unbranded Chromium, from the constants Helium's patches replace.
	public static let chromium: Self = .init(
		id: .init(rawValue: "chromium"),
		name: "Chromium",
		applicationIdentifier: "org.chromium.Chromium",
		userDataPath: "Chromium",
		safeStorage: ChromiumSafeStorage.chromium
	)

	public static let opera: Self = .init(
		id: .init(rawValue: "opera"),
		name: "Opera",
		applicationIdentifier: "com.operasoftware.Opera",
		userDataPath: "com.operasoftware.Opera",
		safeStorage: ChromiumSafeStorage.operaUnverified,
		keepsDefaultProfileAtRoot: true
	)

	public static let operaGX: Self = .init(
		id: .init(rawValue: "opera-gx"),
		name: "Opera GX",
		applicationIdentifier: "com.operasoftware.OperaGX",
		userDataPath: "com.operasoftware.OperaGX",
		safeStorage: ChromiumSafeStorage.operaGXUnverified,
		keepsDefaultProfileAtRoot: true
	)

	public static let vivaldi: Self = .init(
		id: .init(rawValue: "vivaldi"),
		name: "Vivaldi",
		applicationIdentifier: "com.vivaldi.Vivaldi",
		userDataPath: "Vivaldi",
		safeStorage: ChromiumSafeStorage.vivaldiUnverified
	)

	public static let island: Self = .init(
		id: .init(rawValue: "island"),
		name: "Island",
		applicationIdentifier: "io.island.Island",
		userDataPath: "Island",
		safeStorage: ChromiumSafeStorage.islandUnverified
	)
}

// MARK: - Profiles

/// Where a Chromium browser keeps each profile (DEV-896).
internal enum ChromiumProfileLayout {
	/// The profiles `Local State` lists, or Opera's one profile at the root when it lists none.
	internal static func profiles(
		localState: Data?,
		keepsDefaultProfileAtRoot: Bool,
		name: String
	) throws -> [MigrationSourceProfile] {
		let listed = try MigrationBrowserSources.chromiumProfiles(localState)
		guard listed.isEmpty, keepsDefaultProfileAtRoot else { return listed }

		return [.init(id: ChromiumBrowser.defaultProfileID, name: name)]
	}

	/// A profile's folder: `<user data>/<profile>`, or the user data folder itself for
	/// Opera's default profile when it has no folder of its own.
	internal static func directory(
		profile: String,
		userData: URL,
		keepsDefaultProfileAtRoot: Bool
	) -> URL {
		let folder = userData.appending(path: profile, directoryHint: .isDirectory)
		guard
			keepsDefaultProfileAtRoot,
			profile == ChromiumBrowser.defaultProfileID
		else { return folder }

		var isDirectory: ObjCBool = false
		let exists = FileManager.default.fileExists(
			atPath: folder.path(percentEncoded: false),
			isDirectory: &isDirectory
		)
		return exists && isDirectory.boolValue ? folder : userData
	}
}
