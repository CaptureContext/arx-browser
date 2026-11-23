import Foundation

/// An immutable inventory. Its revision belongs to this runtime and profile;
/// callers cannot construct a replacement authority from an extension ID alone.
public struct ChromiumExtensionInventory: Equatable, Sendable {
	internal let runtimeID: UUID
	public let profileID: UUID?
	public let revision: UInt64
	public let extensions: [ChromiumExtension]

	internal init(
		runtimeID: UUID,
		profileID: UUID?,
		revision: UInt64,
		extensions: [ChromiumExtension]
	) {
		self.runtimeID = runtimeID
		self.profileID = profileID
		self.revision = revision
		self.extensions = extensions
	}
}

public struct ChromiumExtension: Decodable, Equatable, Sendable, Identifiable {
	public let id: String
	public let name: String
	public let version: String
	public let manifestVersion: Int
	public let location: ChromiumExtensionLocation
	public let fromWebStore: Bool
	public let state: ChromiumExtensionState
	public let disableReasons: [ChromiumExtensionDisableReason]
	public let permissionsIncreased: Bool
	public let isFixture: Bool
	public let canEnable: Bool
	public let canDisable: Bool
	public let canRemove: Bool
	public let canOpenOptions: Bool?

	/// ABI20. Only a developer-loaded folder can be reread from disk.
	public let canReload: Bool?

	/// ABI20. The developer-selected folder of an unpacked extension.
	public let sourcePath: String?

	/// DEV-824. The manifest icon nearest 32px, inside the extension's folder.
	/// Older engines leave it out; readers fall back to a letter tile.
	public let iconPath: String?

	/// The manifest's icons by their size in pixels, and the action's default icons. Engines
	/// before the DEV-824 follow-up leave both out; readers fall back to `iconPath`.
	public let icons: [String: String]?
	public let actionIcons: [String: String]?

	/// A component extension's manifest icon as base64 PNG bytes: its files live in the
	/// engine's resources, so its icon paths name nothing on disk.
	public let componentIcon: String?

	/// DEV-889. Chromium's per-extension incognito switch; older engines leave both out.
	public let allowedInPrivate: Bool?
	public let canAllowInPrivate: Bool?

	/// DEV-956. Whether it can run in private windows at all; older engines leave it out.
	public let canRunInPrivate: Bool?
	public let requiredPermissions: ChromiumExtensionPermissions
	public let optionalPermissions: ChromiumExtensionPermissions
	public let activePermissions: ChromiumExtensionPermissions
	public let withheldPermissions: ChromiumExtensionPermissions

	internal init(
		id: String,
		name: String,
		version: String,
		manifestVersion: Int,
		location: ChromiumExtensionLocation,
		fromWebStore: Bool,
		state: ChromiumExtensionState,
		disableReasons: [ChromiumExtensionDisableReason],
		permissionsIncreased: Bool,
		isFixture: Bool,
		canEnable: Bool,
		canDisable: Bool,
		canRemove: Bool,
		canOpenOptions: Bool? = nil,
		canReload: Bool? = nil,
		sourcePath: String? = nil,
		iconPath: String? = nil,
		icons: [String: String]? = nil,
		actionIcons: [String: String]? = nil,
		componentIcon: String? = nil,
		allowedInPrivate: Bool? = nil,
		canAllowInPrivate: Bool? = nil,
		canRunInPrivate: Bool? = nil,
		requiredPermissions: ChromiumExtensionPermissions,
		optionalPermissions: ChromiumExtensionPermissions,
		activePermissions: ChromiumExtensionPermissions,
		withheldPermissions: ChromiumExtensionPermissions
	) {
		self.id = id
		self.name = name
		self.version = version
		self.manifestVersion = manifestVersion
		self.location = location
		self.fromWebStore = fromWebStore
		self.state = state
		self.disableReasons = disableReasons
		self.permissionsIncreased = permissionsIncreased
		self.isFixture = isFixture
		self.canEnable = canEnable
		self.canDisable = canDisable
		self.canRemove = canRemove
		self.canOpenOptions = canOpenOptions
		self.canReload = canReload
		self.sourcePath = sourcePath
		self.iconPath = iconPath
		self.icons = icons
		self.actionIcons = actionIcons
		self.componentIcon = componentIcon
		self.allowedInPrivate = allowedInPrivate
		self.canAllowInPrivate = canAllowInPrivate
		self.canRunInPrivate = canRunInPrivate
		self.requiredPermissions = requiredPermissions
		self.optionalPermissions = optionalPermissions
		self.activePermissions = activePermissions
		self.withheldPermissions = withheldPermissions
	}

	internal var isValid: Bool {
		Self.validID(id)
		&& name.utf8.count <= 4096
		&& version.utf8.count <= 4096
		&& manifestVersion > 0
		&& disableReasons.count <= 64
		&& Set(disableReasons).count == disableReasons.count
		&& disableReasons.allSatisfy { $0.rawValue > 0 }
		&& requiredPermissions.isValid
		&& optionalPermissions.isValid
		&& activePermissions.isValid
		&& withheldPermissions.isValid
		&& (!(canEnable || canDisable || canRemove) || (1...10).contains(location.rawValue))
		&& (
			canOpenOptions != true
			|| (state == .enabled && (manifestVersion == 3 || isContentBlocker) && !permissionsIncreased)
		)
		&& (canReload != true || location == .unpacked)
		&& (canAllowInPrivate != true || (1...10).contains(location.rawValue))
		&& (sourcePath.map { location == .unpacked && Self.validSourcePath($0) } ?? true)
		&& (iconPath.map(Self.validIconPath) ?? true)
		&& (icons.map(Self.validIconSizes) ?? true)
		&& (actionIcons.map(Self.validIconSizes) ?? true)
		&& (componentIcon == nil || (isComponent && componentIconData != nil))
		&& (
			!canEnable
			|| (
				state == .disabled
				&& manifestVersion == 3
				&& disableReasons == [.userAction]
				&& !permissionsIncreased
			)
		)
	}

	internal static let maximumSourcePathBytes: Int = 4096

	internal static func validSourcePath(_ path: String) -> Bool {
		path.hasPrefix("/")
		&& path.utf8.count <= maximumSourcePathBytes
		&& !path.utf8.contains { $0 < 32 || $0 == 127 }
	}

	internal static func validIconPath(_ path: String) -> Bool {
		validSourcePath(path)
		&& !path.split(separator: "/").contains("..")
	}

	/// At most as many sizes as the engine reports, each a size of 1 to 4096 pixels written as
	/// a plain number, with a path inside the extension's folder.
	internal static func validIconSizes(_ icons: [String: String]) -> Bool {
		icons.count <= maximumIconSizes
		&& icons.allSatisfy { size, path in iconSize(size) != nil && validIconPath(path) }
	}

	internal static let maximumIconSizes: Int = 16

	/// The pixels a size key names: digits only, no sign or leading zero.
	internal static func iconSize(_ key: String) -> Int? {
		guard
			let first = key.utf8.first,
			first != UInt8(ascii: "0"),
			key.utf8.count <= 4,
			key.utf8.allSatisfy({ (48...57).contains($0) }),
			let size = Int(key),
			(1...4096).contains(size)
		else { return nil }

		return size
	}

	/// The bytes of `componentIcon`, at most 16 KiB as the engine sends them.
	public var componentIconData: Data? {
		guard
			let componentIcon,
			componentIcon.utf8.count <= Self.maximumComponentIconCharacters,
			let data = Data(base64Encoded: componentIcon),
			(1...Self.maximumComponentIconBytes).contains(data.count)
		else { return nil }

		return data
	}

	internal static let maximumComponentIconBytes: Int = 16 * 1024

	/// Base64 of ``maximumComponentIconBytes``, checked before decoding.
	internal static let maximumComponentIconCharacters: Int = (maximumComponentIconBytes + 2) / 3 * 4

	internal var isComponent: Bool {
		location == .component || location == .externalComponent
	}

	/// The icons by pixels, for icons `isValid` accepted.
	public static func iconSizes(_ icons: [String: String]?) -> [Int: String] {
		var sizes: [Int: String] = [:]
		for (key, path) in icons ?? [:] {
			if let size = iconSize(key) { sizes[size] = path }
		}
		return sizes
	}

	/// DEV-884. Helium's uBlock Origin component, Arx's content blocking: its options page,
	/// uBlock's dashboard, opens although it's Manifest V2.
	public static let contentBlockerID: String = "blockjmkbacgjkknlgpkjjiijinjdanf"

	internal var isContentBlocker: Bool {
		id == Self.contentBlockerID && location == .component
	}

	internal static func validID(_ id: String) -> Bool {
		id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
	}
}

public struct ChromiumExtensionPermissions: Decodable, Equatable, Sendable {
	public let apis: [String]
	public let hosts: [String]

	internal init(
		apis: [String],
		hosts: [String]
	) {
		self.apis = apis
		self.hosts = hosts
	}

	internal var isValid: Bool {
		apis.count <= 512
		&& hosts.count <= 512
		&& apis.allSatisfy { $0.utf8.count <= 4096 }
		&& hosts.allSatisfy { $0.utf8.count <= 4096 }
	}
}

public enum ChromiumExtensionState: String, Decodable, Sendable {
	case enabled
	case disabled
	case terminated
	case blocklisted
	case blocked
}

/// Preserve unknown native reasons as their exact integer. A newer Chromium
/// reason must never turn into permission to enable an extension.
public struct ChromiumExtensionDisableReason: RawRepresentable, Decodable, Hashable, Sendable {
	public let rawValue: Int

	public init(rawValue: Int) {
		self.rawValue = rawValue
	}

	public init(from decoder: any Decoder) throws {
		self.rawValue = try decoder.singleValueContainer().decode(Int.self)
	}

	public static let userAction: Self = .init(rawValue: 1 << 0)
	public static let permissionsIncrease: Self = .init(rawValue: 1 << 1)
	public static let reload: Self = .init(rawValue: 1 << 2)
	public static let unsupportedRequirement: Self = .init(rawValue: 1 << 3)
	public static let notVerified: Self = .init(rawValue: 1 << 8)
	public static let corrupted: Self = .init(rawValue: 1 << 10)
	public static let blockedByPolicy: Self = .init(rawValue: 1 << 16)
	public static let unsupportedManifest: Self = .init(rawValue: 1 << 23)
	public static let unsupportedDeveloperExtension: Self = .init(rawValue: 1 << 24)
	public static let unknown: Self = .init(rawValue: 1 << 25)
}

/// Chromium's persisted manifest location. Unrecognized values remain visible
/// and cannot grant management capabilities on the Swift side.
public struct ChromiumExtensionLocation: RawRepresentable, Decodable, Hashable, Sendable {
	public let rawValue: Int

	public init(rawValue: Int) {
		self.rawValue = rawValue
	}

	public init(from decoder: any Decoder) throws {
		self.rawValue = try decoder.singleValueContainer().decode(Int.self)
	}

	public static let internalInstall: Self = .init(rawValue: 1)
	public static let externalPreference: Self = .init(rawValue: 2)
	public static let externalRegistry: Self = .init(rawValue: 3)
	public static let unpacked: Self = .init(rawValue: 4)
	public static let component: Self = .init(rawValue: 5)
	public static let externalPreferenceDownload: Self = .init(rawValue: 6)
	public static let externalPolicyDownload: Self = .init(rawValue: 7)
	public static let commandLine: Self = .init(rawValue: 8)
	public static let externalPolicy: Self = .init(rawValue: 9)
	public static let externalComponent: Self = .init(rawValue: 10)
}

public enum ChromiumExtensionAction: Sendable {
	case enable
	case disable
	case remove

	/// ABI20. Rereads an unpacked extension from its folder.
	case reload

	/// DEV-889. Lets the extension run in private windows, or stops it.
	case allowInPrivate
	case disallowInPrivate
}

public enum ChromiumExtensionFailure: Error, Equatable, Sendable {
	case unavailable
	case staleInventory
	case blockedByPolicy
	case reviewRequired
	case invalidRequest
	case failed
	case limitExceeded
	case timeout
	case busy
	case invalidResponse
	case cancelled
	case invalidPackage

	/// ABI20 unpacked loading: the chosen folder does not exist.
	case directoryMissing

	/// ABI20 unpacked loading: the folder or its manifest cannot be read.
	case directoryUnreadable

	/// ABI20 unpacked loading: Chromium's bounded reason, such as a JSON position.
	case invalidManifest(String)

	/// ABI45 (DEV-776). The store has no newer version of the extension.
	case upToDate
}
