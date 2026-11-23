import Foundation

/// Which Arx a process belongs to (DEV-1013): the installed Arx, or Arx Dev, the Debug build
/// that `make run-dev`, the smokes and Xcode make. Each has its own bundle identifier, so its own
/// defaults, data folders and Keychain items, and the two run side by side.
///
/// `make run` and `make run-preview` build Debug as Arx. `make run-preview` names its own data
/// folder and agents' folder in Info.plist (`ArxDataFolder`, `ArxSupportName`), so it never
/// opens the installed Arx's profiles.
public struct ArxEdition: Equatable, Sendable {
	/// The app's bundle identifier.
	public var bundleIdentifier: String

	/// The app's name, which also names its folder of agent files in
	/// `~/Library/Application Support`.
	public var name: String

	/// The app's folder in `~/Library/Application Support`: its bundle identifier unless its
	/// Info.plist names another.
	public var dataFolder: String

	public init(
		bundleIdentifier: String,
		name: String,
		dataFolder: String? = nil
	) {
		self.bundleIdentifier = bundleIdentifier
		self.name = name
		self.dataFolder = dataFolder ?? bundleIdentifier
	}

	/// Info.plist's names for the data folder and the agents' folder.
	public enum InfoKey {
		public static let dataFolder: String = "ArxDataFolder"
		public static let supportName: String = "ArxSupportName"
	}

	/// The installed Arx: Release builds, `make install` and `make dmg`.
	public static let release: Self = .init(
		bundleIdentifier: "dev.capturecontext.arx",
		name: "Arx"
	)

	/// Arx Dev: Debug builds.
	public static let development: Self = .init(
		bundleIdentifier: "dev.capturecontext.arx.dev",
		name: "Arx Dev"
	)

	/// The edition of the app this process runs in, with the folders its Info.plist names.
	public static let current: Self = .hosting(
		bundleIdentifier: Bundle.main.bundleIdentifier,
		executable: Bundle.main.executableURL
	)
	.naming(from: Bundle.main.bundleIdentifier != nil
	? Bundle.main.infoDictionary
	: enclosingApplication(of: Bundle.main.executableURL).flatMap { Bundle(url: $0)?.infoDictionary })

	public var isDevelopment: Bool { bundleIdentifier == Self.development.bundleIdentifier }

	/// This edition with the data folder and agents' folder `info` names, where it names them.
	/// Empty or missing values keep the edition's own.
	public func naming(from info: [String: Any]?) -> Self {
		var edition = self
		if let folder = info?[InfoKey.dataFolder] as? String, !folder.isEmpty {
			edition.dataFolder = folder
		}
		if let name = info?[InfoKey.supportName] as? String, !name.isEmpty {
			edition.name = name
		}
		return edition
	}

	/// `~/Library/Application Support/<data folder>`, where the app and Chromium keep their
	/// data: the bundle identifier, unless Info.plist names another folder.
	public func applicationSupport(home: URL) -> URL {
		home.appending(path: "Library/Application Support/\(dataFolder)", directoryHint: .isDirectory)
	}

	/// `~/Library/Application Support/<name>`, where the app keeps its agents' files.
	public func namedSupport(home: URL) -> URL {
		home.appending(path: "Library/Application Support/\(name)", directoryHint: .isDirectory)
	}

	/// The app's own edition, or for a tool inside it (`arx` in `Contents/Helpers`) the app's
	/// around it. Anything else, tests among them, is the installed Arx's.
	public static func hosting(
		bundleIdentifier: String?,
		executable: URL?,
		bundleIdentifierAt: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
	) -> Self {
		if let edition = edition(of: bundleIdentifier) {
			return edition
		}

		guard let application = enclosingApplication(of: executable) else { return .release }
		return edition(of: bundleIdentifierAt(application)) ?? .release
	}

	/// The `.app` bundle around `executable`, if it's inside one.
	public static func enclosingApplication(of executable: URL?) -> URL? {
		var folder: URL? = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
		while let current = folder, current.path != "/" {
			if current.pathExtension == "app" { return current }
			folder = current.deletingLastPathComponent()
		}
		return nil
	}

	private static func edition(of bundleIdentifier: String?) -> Self? {
		[Self.release, .development].first { $0.bundleIdentifier == bundleIdentifier }
	}
}
