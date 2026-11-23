import BrowserCore
import Foundation
import _Dependencies

/// Ordinary-profile inventory, management and explicit verified-package consent.
public struct BrowserExtensionsClient: Sendable {
	public var optionsAvailability: @MainActor @Sendable () -> Bool
	public var openOptions: @MainActor @Sendable (BrowserExtensionViewRequest) async throws -> BrowserExtensionInventory
	public var availability: @MainActor @Sendable () -> Bool
	public var installationAvailability: @MainActor @Sendable () -> Bool
	public var inspect: @MainActor @Sendable (Profile.ID) async throws -> BrowserExtensionInventory
	public var manage: @MainActor @Sendable (BrowserExtensionRequest) async throws -> BrowserExtensionInventory

	public var prepareInstallation: @MainActor @Sendable (
		BrowserExtensionInstallRequest
	) async throws -> BrowserExtensionInstallPrompt
	public var resolveInstallation: @MainActor @Sendable (
		BrowserExtensionInstallPrompt,
		Bool
	) async throws -> BrowserExtensionInventory
	public var cancelInstallation: @MainActor @Sendable (BrowserExtensionInstallPrompt) -> Void

	public var unpackedAvailability: @MainActor @Sendable () -> Bool
	public var loadUnpacked: @MainActor @Sendable (BrowserExtensionUnpackedRequest) async throws -> BrowserExtensionInventory

	/// DEV-765 Chrome Web Store installs. One consumer receives the store's requests.
	public var webstoreAvailability: @MainActor @Sendable () -> Bool
	public var webstoreInstallRequests: @MainActor @Sendable () -> AsyncStream<BrowserWebstoreInstallRequest>
	public var prepareWebstoreInstallation: @MainActor @Sendable (
		BrowserWebstoreInstallRequest,
		BrowserExtensionInventory
	) async throws -> BrowserExtensionInstallPrompt
	public var declineWebstoreInstallation: @MainActor @Sendable (BrowserWebstoreInstallRequest) -> Void

	/// DEV-776 Chrome Web Store updates, through the same verified review as installs.
	public var webstoreUpdateAvailability: @MainActor @Sendable () -> Bool
	public var prepareWebstoreUpdate: @MainActor @Sendable (
		BrowserWebstoreUpdateRequest
	) async throws -> BrowserExtensionInstallPrompt

	/// DEV-845 store installs by ID, for extensions brought over from another browser.
	public var webstoreImportAvailability: @MainActor @Sendable () -> Bool
	public var prepareWebstoreImport: @MainActor @Sendable (
		BrowserWebstoreImportRequest
	) async throws -> BrowserExtensionInstallPrompt

	/// DEV-824. The image at an extension's `iconPath`, or nil.
	public var icon: @Sendable (String) async -> Data?

	/// DEV-884. Arx's content blocking (Helium's uBlock Origin) in every profile, and its
	/// cookie notice lists: (isOn, blocksCookieBanners). Safe before the engine starts.
	public var setContentBlocking: @MainActor @Sendable (Bool, Bool) -> Void

	public init(
		isAvailable: Bool = false,
		optionsAvailability: @escaping @MainActor @Sendable () -> Bool = { false },
		openOptions: @escaping @MainActor @Sendable (BrowserExtensionViewRequest) async throws -> BrowserExtensionInventory = { _ in
			throw Failure.unavailable
		},
		availability: (@MainActor @Sendable () -> Bool)? = nil,
		installationAvailability: @escaping @MainActor @Sendable () -> Bool = { false },
		inspect: @escaping @MainActor @Sendable (Profile.ID) async throws -> BrowserExtensionInventory = { _ in
			throw Failure.unavailable
		},
		manage: @escaping @MainActor @Sendable (BrowserExtensionRequest) async throws -> BrowserExtensionInventory = { _ in
			throw Failure.unavailable
		},
		prepareInstallation: @escaping @MainActor @Sendable (
			BrowserExtensionInstallRequest
		) async throws -> BrowserExtensionInstallPrompt = { _ in
			throw Failure.unavailable
		},
		resolveInstallation: @escaping @MainActor @Sendable (
			BrowserExtensionInstallPrompt,
			Bool
		) async throws -> BrowserExtensionInventory = { _, _ in
			throw Failure.unavailable
		},
		cancelInstallation: @escaping @MainActor @Sendable (BrowserExtensionInstallPrompt) -> Void = { _ in },
		unpackedAvailability: @escaping @MainActor @Sendable () -> Bool = { false },
		loadUnpacked: @escaping @MainActor @Sendable (BrowserExtensionUnpackedRequest) async throws -> BrowserExtensionInventory = { _ in
			throw Failure.unavailable
		},
		webstoreAvailability: @escaping @MainActor @Sendable () -> Bool = { false },
		webstoreInstallRequests: @escaping @MainActor @Sendable () -> AsyncStream<BrowserWebstoreInstallRequest> = {
			AsyncStream { $0.finish() }
		},
		prepareWebstoreInstallation: @escaping @MainActor @Sendable (
			BrowserWebstoreInstallRequest,
			BrowserExtensionInventory
		) async throws -> BrowserExtensionInstallPrompt = { _, _ in
			throw Failure.unavailable
		},
		declineWebstoreInstallation: @escaping @MainActor @Sendable (BrowserWebstoreInstallRequest) -> Void = { _ in },
		webstoreUpdateAvailability: @escaping @MainActor @Sendable () -> Bool = { false },
		prepareWebstoreUpdate: @escaping @MainActor @Sendable (
			BrowserWebstoreUpdateRequest
		) async throws -> BrowserExtensionInstallPrompt = { _ in
			throw Failure.unavailable
		},
		webstoreImportAvailability: @escaping @MainActor @Sendable () -> Bool = { false },
		prepareWebstoreImport: @escaping @MainActor @Sendable (
			BrowserWebstoreImportRequest
		) async throws -> BrowserExtensionInstallPrompt = { _ in
			throw Failure.unavailable
		},
		icon: @escaping @Sendable (String) async -> Data? = { _ in nil },
		setContentBlocking: @escaping @MainActor @Sendable (Bool, Bool) -> Void = { _, _ in }
	) {
		self.optionsAvailability = optionsAvailability
		self.openOptions = openOptions
		self.availability = availability ?? { isAvailable }
		self.installationAvailability = installationAvailability
		self.inspect = inspect
		self.manage = manage
		self.prepareInstallation = prepareInstallation
		self.resolveInstallation = resolveInstallation
		self.cancelInstallation = cancelInstallation
		self.unpackedAvailability = unpackedAvailability
		self.loadUnpacked = loadUnpacked
		self.webstoreAvailability = webstoreAvailability
		self.webstoreInstallRequests = webstoreInstallRequests
		self.prepareWebstoreInstallation = prepareWebstoreInstallation
		self.declineWebstoreInstallation = declineWebstoreInstallation
		self.webstoreUpdateAvailability = webstoreUpdateAvailability
		self.prepareWebstoreUpdate = prepareWebstoreUpdate
		self.webstoreImportAvailability = webstoreImportAvailability
		self.prepareWebstoreImport = prepareWebstoreImport
		self.icon = icon
		self.setContentBlocking = setContentBlocking
	}

	@MainActor
	public var isAvailable: Bool { availability() }

	@MainActor
	public var isInstallationAvailable: Bool { availability() && installationAvailability() }

	/// Folder loading capability only; the app's developer mode gates its controls.
	@MainActor
	public var isUnpackedAvailable: Bool { availability() && unpackedAvailability() }

	/// Add to Chrome on the Chrome Web Store reaches Arx's review.
	@MainActor
	public var isWebstoreAvailable: Bool { isInstallationAvailable && webstoreAvailability() }

	/// Installed store extensions can be checked for updates.
	@MainActor
	public var isWebstoreUpdateAvailable: Bool { isInstallationAvailable && webstoreUpdateAvailability() }

	/// Store extensions can be installed by ID, as an import does.
	@MainActor
	public var isWebstoreImportAvailable: Bool { isInstallationAvailable && webstoreImportAvailability() }

	public enum Failure: Error, Equatable, Sendable {
		case unavailable
		case staleInventory
		case missingProfile
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
		case sourceChanged
		case directoryMissing
		case directoryUnreadable

		/// Chromium's bounded reason, such as a JSON position or a missing script.
		case invalidManifest(String)

		/// DEV-776. The store has no newer version.
		case upToDate
	}
}

extension BrowserExtensionsClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var browserExtensions: BrowserExtensionsClient {
		get { self[BrowserExtensionsClient.self] }
		set { self[BrowserExtensionsClient.self] = newValue }
	}
}
