import Foundation

/// The immutable bytes selected for verification. A native prompt, never this
/// value or its metadata, authorizes installing the package.
public struct BrowserExtensionPackage: Equatable, Sendable {
	public static let maximumBytes: Int = 32 * 1024 * 1024

	public let data: Data
	public let sourceBasename: String

	public init(
		data: Data,
		sourceBasename: String
	) {
		self.data = data
		self.sourceBasename = sourceBasename
	}
}

public struct BrowserExtensionInstallRequest: Equatable, Sendable {
	public let inventoryID: UUID
	public let profileID: Profile.ID
	public let revision: UInt64
	public let expectedExtensionID: String?
	public let selectedFile: URL

	public init(
		inventory: BrowserExtensionInventory,
		selectedFile: URL,
		expectedExtensionID: String? = nil
	) {
		self.inventoryID = inventory.id
		self.profileID = inventory.profileID
		self.revision = inventory.revision
		self.expectedExtensionID = expectedExtensionID
		self.selectedFile = selectedFile
	}
}

/// Adapter-issued transient authority. The adapter retains the opaque native
/// prompt; a feature cannot reconstruct authority from candidate metadata.
public struct BrowserExtensionInstallPrompt: Equatable, Sendable, Identifiable {
	public let id: UUID
	public let profileID: Profile.ID
	public let inventoryID: UUID
	public let revision: UInt64
	public let candidate: Candidate

	public init(
		id: UUID,
		profileID: Profile.ID,
		inventoryID: UUID,
		revision: UInt64,
		candidate: Candidate
	) {
		self.id = id
		self.profileID = profileID
		self.inventoryID = inventoryID
		self.revision = revision
		self.candidate = candidate
	}

	public struct Candidate: Equatable, Sendable {
		public let extensionID: String
		public let name: String
		public let version: String
		public let packageSHA256: String
		public let sourceBasename: String
		public let isUpdate: Bool
		public let requiredPermissions: BrowserExtension.Permissions
		public let optionalPermissions: BrowserExtension.Permissions
		public let warnings: [Warning]

		/// DEV-776. An update that asks for permissions the installed extension
		/// wasn't granted. Always false for a new install.
		public let permissionIncrease: Bool

		/// Who publishes it, from the package's manifest; nil when it names no one (DEV-968).
		public let publisher: String?

		public init(
			extensionID: String,
			name: String,
			version: String,
			packageSHA256: String,
			sourceBasename: String,
			isUpdate: Bool,
			requiredPermissions: BrowserExtension.Permissions,
			optionalPermissions: BrowserExtension.Permissions,
			warnings: [Warning],
			permissionIncrease: Bool = false,
			publisher: String? = nil
		) {
			self.extensionID = extensionID
			self.name = name
			self.version = version
			self.packageSHA256 = packageSHA256
			self.sourceBasename = sourceBasename
			self.isUpdate = isUpdate
			self.requiredPermissions = requiredPermissions
			self.optionalPermissions = optionalPermissions
			self.warnings = warnings
			self.permissionIncrease = permissionIncrease
			self.publisher = publisher
		}
	}

	public struct Warning: Equatable, Sendable {
		public let message: String
		public let details: [String]

		public init(
			message: String,
			details: [String]
		) {
			self.message = message
			self.details = details
		}
	}
}

/// DEV-776. Check the Chrome Web Store for a newer version of one installed store
/// extension, bound to the inventory the user is looking at. Preparing it yields a
/// normal ``BrowserExtensionInstallPrompt`` for the update, or fails with
/// ``BrowserExtensionsClient/Failure/upToDate``.
public struct BrowserWebstoreUpdateRequest: Equatable, Sendable {
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

/// DEV-845. Install a Chrome Web Store item by ID that isn't installed in the profile, with
/// no store page: an extension brought over from another browser. Preparing it downloads
/// and verifies the store's package and yields a normal ``BrowserExtensionInstallPrompt``.
public struct BrowserWebstoreImportRequest: Equatable, Sendable {
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

/// DEV-765. The Chrome Web Store's Add to Chrome asked to install an item in one
/// ordinary profile. Adapter-issued; the native authority stays in the adapter.
/// Preparing it downloads and verifies the store's package and yields a normal
/// ``BrowserExtensionInstallPrompt``; declining tells the store the user cancelled.
public struct BrowserWebstoreInstallRequest: Equatable, Sendable, Identifiable {
	/// The store's home page, opened in a profile to browse and add extensions.
	public static let storeURL: URL = URL(string: "https://chromewebstore.google.com/")!

	public let id: UUID
	public let profileID: Profile.ID
	public let extensionID: String

	public init(
		id: UUID,
		profileID: Profile.ID,
		extensionID: String
	) {
		self.id = id
		self.profileID = profileID
		self.extensionID = extensionID
	}
}

extension BrowserExtension {
	/// Chromium's extension ID: 32 letters from a to p.
	public static func isValidID(_ id: String) -> Bool {
		id.utf8.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
	}
}

extension BrowserWebstoreInstallRequest {
	/// The item ID in a Chrome Web Store reference: the ID itself, or an item page such as
	/// `https://chromewebstore.google.com/detail/name/<id>` or the old
	/// `https://chrome.google.com/webstore/detail/name/<id>`. Nil for anything else (DEV-951).
	public static func extensionID(fromStoreReference text: String) -> String? {
		let reference = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard reference.utf8.count <= 2048 else { return nil }
		if BrowserExtension.isValidID(reference) { return reference }

		guard
			let components = URLComponents(string: reference),
			components.scheme?.lowercased() == "https",
			components.user == nil,
			components.password == nil,
			components.port == nil,
			let host = components.host?.lowercased()
		else { return nil }

		let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
		let detail: ArraySlice<String>
		switch host {
		case "chromewebstore.google.com":
			guard path.first == "detail" else { return nil }
			detail = path.dropFirst()
		case "chrome.google.com":
			guard path.starts(with: ["webstore", "detail"]) else { return nil }
			detail = path.dropFirst(2)
		default:
			return nil
		}

		// `detail/<id>` or `detail/<name>/<id>`, as the store links them.
		guard (1...2).contains(detail.count), let id = detail.last, BrowserExtension.isValidID(id)
		else { return nil }
		return id
	}
}
