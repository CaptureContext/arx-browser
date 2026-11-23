import Foundation

/// Profile-owned metadata. These values describe permissions; they never grant them.
public struct BrowserExtension: Equatable, Sendable, Identifiable {
	public var id: String
	public var name: String
	public var version: String
	public var manifestVersion: Int
	public var location: Int
	public var fromWebStore: Bool
	public var state: State
	public var disableReasons: [DisableReason]
	public var permissionsIncreased: Bool
	public var canEnable: Bool
	public var canDisable: Bool
	public var canRemove: Bool
	public var canOpenOptions: Bool

	/// A developer-loaded folder that Chromium can reread.
	public var canReload: Bool

	/// The developer-selected folder of an unpacked extension.
	public var sourcePath: String?

	/// The manifest icon nearest 32px, read with `BrowserExtensionsClient.icon`.
	public var iconPath: String?

	/// The manifest's icons by their size in pixels; empty with engines that report only
	/// `iconPath`.
	public var icons: [Int: String]

	/// The action's default icons by their size in pixels, which the toolbar would draw.
	public var actionIcons: [Int: String]

	/// The PNG of a component extension's icon, whose files live in the engine's resources
	/// rather than on disk; nil for the rest and with older engines.
	public var bundledIcon: Data?

	/// Whether the extension may run in private windows. Off by default.
	public var allowedInPrivate: Bool

	/// Whether the person can change `allowedInPrivate`; false on engines without the switch.
	public var canAllowInPrivate: Bool

	/// It can run in private windows at all (DEV-956): a split-mode extension with an event
	/// page or service worker can't, whatever `allowedInPrivate` says.
	public var canRunInPrivate: Bool
	public var requiredPermissions: Permissions
	public var optionalPermissions: Permissions
	public var activePermissions: Permissions
	public var withheldPermissions: Permissions

	public init(
		id: String,
		name: String,
		version: String,
		manifestVersion: Int = 3,
		location: Int = 1,
		fromWebStore: Bool = false,
		state: State,
		disableReasons: [DisableReason] = [],
		permissionsIncreased: Bool = false,
		canEnable: Bool = false,
		canDisable: Bool = false,
		canRemove: Bool = false,
		canOpenOptions: Bool = false,
		canReload: Bool = false,
		sourcePath: String? = nil,
		iconPath: String? = nil,
		icons: [Int: String] = [:],
		actionIcons: [Int: String] = [:],
		bundledIcon: Data? = nil,
		allowedInPrivate: Bool = false,
		canAllowInPrivate: Bool = false,
		canRunInPrivate: Bool = true,
		requiredPermissions: Permissions = .init(),
		optionalPermissions: Permissions = .init(),
		activePermissions: Permissions = .init(),
		withheldPermissions: Permissions = .init()
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
		self.canEnable = canEnable
		self.canDisable = canDisable
		self.canRemove = canRemove
		self.canOpenOptions = canOpenOptions
		self.canReload = canReload
		self.sourcePath = sourcePath
		self.iconPath = iconPath
		self.icons = icons
		self.actionIcons = actionIcons
		self.bundledIcon = bundledIcon
		self.allowedInPrivate = allowedInPrivate
		self.canAllowInPrivate = canAllowInPrivate
		self.canRunInPrivate = canRunInPrivate
		self.requiredPermissions = requiredPermissions
		self.optionalPermissions = optionalPermissions
		self.activePermissions = activePermissions
		self.withheldPermissions = withheldPermissions
	}

	/// The icon file to draw `pixels` wide. The action's default icon, as the toolbar shows it,
	/// when one covers `pixels`, else the manifest's; each the smallest that covers it. When none
	/// does, the largest of either, and `iconPath` when the engine reports neither.
	public func iconPath(pixels: Int) -> String? {
		if let covering = Self.covering(actionIcons, pixels: pixels) ?? Self.covering(icons, pixels: pixels) {
			return covering
		}

		let largest = [actionIcons, icons]
			.compactMap { icons in icons.max { $0.key < $1.key } }
			.max { $0.key < $1.key }
		return largest?.value ?? iconPath
	}

	private static func covering(
		_ icons: [Int: String],
		pixels: Int
	) -> String? {
		icons
			.filter { $0.key >= pixels }
			.min { $0.key < $1.key }?
			.value
	}

	public func allows(_ action: BrowserExtensionAction) -> Bool {
		switch action {
		case .enable:
			canEnable
			&& state == .disabled
			&& manifestVersion == 3
			&& disableReasons == [.userAction]
			&& !permissionsIncreased

		case .disable: canDisable && state == .enabled

		case .remove: canRemove

		case .reload: canReload

		case .allowInPrivate: canAllowInPrivate && !allowedInPrivate

		case .disallowInPrivate: canAllowInPrivate && allowedInPrivate
		}
	}

	public enum State: String, Equatable, Sendable {
		case enabled, disabled, terminated, blocklisted, blocked
	}

	public struct Permissions: Equatable, Sendable {
		public var apis: [String]
		public var hosts: [String]

		public init(
			apis: [String] = [],
			hosts: [String] = []
		) {
			self.apis = apis
			self.hosts = hosts
		}
	}

	/// Preserve unrecognized Chromium reasons; an unknown reason cannot authorize enable.
	public struct DisableReason: RawRepresentable, Equatable, Hashable, Sendable {
		public static let userAction: Self = .init(rawValue: 1)
		public static let permissionsIncrease: Self = .init(rawValue: 1 << 1)

		public let rawValue: Int

		public init(rawValue: Int) {
			self.rawValue = rawValue
		}
	}
}

extension BrowserExtension {
	/// Helium's uBlock Origin component, which Arx's content blocking is (DEV-884).
	public static let contentBlockingID: String = "blockjmkbacgjkknlgpkjjiijinjdanf"
}

public enum BrowserExtensionAction: Equatable, Sendable {
	case enable, disable, remove, reload

	/// Lets the extension run in private windows, or stops it.
	case allowInPrivate, disallowInPrivate
}

/// A short-lived adapter-issued authority, never persisted or reconstructed from row metadata.
public struct BrowserExtensionInventory: Equatable, Sendable {
	public let id: UUID
	public let profileID: Profile.ID
	public let revision: UInt64
	public let extensions: [BrowserExtension]

	public init(
		id: UUID,
		profileID: Profile.ID,
		revision: UInt64,
		extensions: [BrowserExtension]
	) {
		self.id = id
		self.profileID = profileID
		self.revision = revision
		self.extensions = extensions
	}
}

public struct BrowserExtensionRequest: Equatable, Sendable {
	public let inventoryID: UUID
	public let profileID: Profile.ID
	public let revision: UInt64
	public let extensionID: String
	public let action: BrowserExtensionAction

	public init(
		inventory: BrowserExtensionInventory,
		extensionID: String,
		action: BrowserExtensionAction
	) {
		self.inventoryID = inventory.id
		self.profileID = inventory.profileID
		self.revision = inventory.revision
		self.extensionID = extensionID
		self.action = action
	}
}

/// A developer-chosen folder bound to the exact displayed profile inventory.
public struct BrowserExtensionUnpackedRequest: Equatable, Sendable {
	public let inventoryID: UUID
	public let profileID: Profile.ID
	public let revision: UInt64
	public let directory: URL

	public init(
		inventory: BrowserExtensionInventory,
		directory: URL
	) {
		self.inventoryID = inventory.id
		self.profileID = inventory.profileID
		self.revision = inventory.revision
		self.directory = directory
	}
}

/// Exact inventory authority for a manifest-defined options view, never a URL.
public struct BrowserExtensionViewRequest: Equatable, Sendable {
	public let inventoryID: UUID
	public let profileID: Profile.ID
	public let revision: UInt64
	public let extensionID: String

	public init(
		inventory: BrowserExtensionInventory,
		extensionID: String
	) {
		self.inventoryID = inventory.id
		self.profileID = inventory.profileID
		self.revision = inventory.revision
		self.extensionID = extensionID
	}
}
