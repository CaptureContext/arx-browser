import Foundation

/// A native-issued candidate authority. Descriptive fields cannot recreate it.
public struct ChromiumExtensionInstallPrompt: Equatable, Sendable {
	public static let maximumPackageBytes: Int = 32 * 1024 * 1024
	internal let runtimeID: UUID
	internal let requestID: UInt64
	internal let token: UInt64
	public let profileID: UUID?
	public let inventoryRevision: UInt64
	public let candidate: Candidate

	internal init(
		runtimeID: UUID,
		requestID: UInt64,
		token: UInt64,
		profileID: UUID?,
		inventoryRevision: UInt64,
		candidate: Candidate
	) {
		self.runtimeID = runtimeID
		self.requestID = requestID
		self.token = token
		self.profileID = profileID
		self.inventoryRevision = inventoryRevision
		self.candidate = candidate
	}

	public struct Candidate: Decodable, Equatable, Sendable {
		public let id: String
		public let name: String
		public let version: String
		public let packageSHA256: String
		public let sourceBasename: String
		public let isUpdate: Bool
		public let requiredPermissions: ChromiumExtensionPermissions
		public let optionalPermissions: ChromiumExtensionPermissions
		public let warnings: [Warning]

		/// ABI45 (DEV-776). Updates only: the candidate asks for permissions the installed
		/// extension wasn't granted. Nil for new installs and on older engines.
		public let permissionIncrease: Bool?

		/// ABI56 (DEV-968). Who publishes it: the manifest's author, when it names one. Nil
		/// otherwise, as for most store packages, and on older engines.
		public let publisher: String?

		internal init(
			id: String,
			name: String,
			version: String,
			packageSHA256: String,
			sourceBasename: String,
			isUpdate: Bool,
			requiredPermissions: ChromiumExtensionPermissions,
			optionalPermissions: ChromiumExtensionPermissions,
			warnings: [Warning],
			permissionIncrease: Bool? = nil,
			publisher: String? = nil
		) {
			self.id = id
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

		internal var isValid: Bool {
			ChromiumExtension.validID(id)
			&& !name.isEmpty && name.utf8.count <= 4096 && !name.contains("\0")
			&& !version.isEmpty && version.utf8.count <= 128
			&& packageSHA256.utf8.count == 64 && packageSHA256.utf8.allSatisfy {
				(48...57).contains($0) || (97...102).contains($0)
			}
			&& !sourceBasename.isEmpty && sourceBasename.utf8.count <= 255
			&& !sourceBasename.utf8.contains { $0 < 32 || $0 == 127 || $0 == 47 || $0 == 92 }
			&& requiredPermissions.isValid && optionalPermissions.isValid
			&& warnings.count <= 512 && warnings.allSatisfy(\.isValid)
			&& (publisher.map { !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains {
				$0.value < 32 || $0.value == 127
			} } ?? true)
		}
	}

	public struct Warning: Decodable, Equatable, Sendable {
		public let message: String
		public let details: [String]

		internal init(
			message: String,
			details: [String]
		) {
			self.message = message
			self.details = details
		}

		internal var isValid: Bool {
			message.utf8.count <= 4096
			&& !message.contains("\0")
			&& details.count <= 512
			&& details.allSatisfy { $0.utf8.count <= 4096 && !$0.contains("\0") }
		}
	}
}

/// ABI44. The Chrome Web Store's Add to Chrome in an ordinary page. The token is
/// bound natively to this profile and item; it is used once and expires after
/// two minutes.
public struct ChromiumWebstoreInstallRequest: Equatable, Sendable {
	/// What a store package's prompt names as its source.
	public static let sourceName: String = "Chrome Web Store"
	internal let runtimeID: UUID
	internal let token: UInt64
	public let profileID: UUID?
	public let extensionID: String

	internal init(
		runtimeID: UUID,
		token: UInt64,
		profileID: UUID?,
		extensionID: String
	) {
		self.runtimeID = runtimeID
		self.token = token
		self.profileID = profileID
		self.extensionID = extensionID
	}
}
