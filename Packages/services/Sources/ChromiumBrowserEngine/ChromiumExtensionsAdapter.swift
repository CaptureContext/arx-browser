import BrowserCore
import BrowserExtensionsClient
import ChromiumEngine
import Foundation

/// Keeps opaque native inventory authority out of feature state and rejects replayed row actions.
@MainActor
internal final class ChromiumExtensionsAdapter {
	private struct Inventory {
		internal let native: ChromiumExtensionInventory
		internal let value: BrowserExtensionInventory

		internal init(
			native: ChromiumExtensionInventory,
			value: BrowserExtensionInventory
		) {
			self.native = native
			self.value = value
		}
	}

	private let legacyProfileID: Profile.ID
	private let available: @MainActor @Sendable () -> Bool
	private let installationAvailable: @MainActor @Sendable () -> Bool
	private let ordinaryProfileExists: @MainActor @Sendable (Profile.ID) -> Bool
	private let inspect: @MainActor @Sendable (UUID?) async throws -> ChromiumExtensionInventory
	private let manage: @MainActor @Sendable (
		ChromiumExtensionAction,
		String,
		ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory

	private let optionsAvailable: @MainActor @Sendable () -> Bool
	private let openOptions: @MainActor @Sendable (
		String,
		ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory
	private let readPackage: @Sendable (URL) async throws -> BrowserExtensionPackage
	private let prepareInstallation: @MainActor @Sendable (
		BrowserExtensionPackage,
		String?,
		ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt
	private let resolveInstallation: @MainActor @Sendable (
		ChromiumExtensionInstallPrompt,
		Bool
	) async throws -> ChromiumExtensionInventory
	private let cancelInstallation: @MainActor @Sendable (ChromiumExtensionInstallPrompt) -> Void
	private let unpackedAvailable: @MainActor @Sendable () -> Bool
	private let loadUnpacked: @MainActor @Sendable (
		URL,
		ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory

	private struct Installation {
		internal let native: ChromiumExtensionInstallPrompt
		internal let value: BrowserExtensionInstallPrompt

		internal init(
			native: ChromiumExtensionInstallPrompt,
			value: BrowserExtensionInstallPrompt
		) {
			self.native = native
			self.value = value
		}
	}

	private var installations: [UUID: Installation] = [:]

	private let webstoreAvailable: @MainActor @Sendable () -> Bool
	private let prepareWebstore: @MainActor @Sendable (
		ChromiumWebstoreInstallRequest,
		ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt
	private let declineWebstore: @MainActor @Sendable (ChromiumWebstoreInstallRequest) -> Void
	private let webstoreUpdateAvailable: @MainActor @Sendable () -> Bool
	private let prepareWebstoreUpdate: @MainActor @Sendable (
		String,
		ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt
	private let webstoreImportAvailable: @MainActor @Sendable () -> Bool
	private let prepareWebstoreImport: @MainActor @Sendable (
		String,
		ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt
	private var webstoreRequests: [UUID: ChromiumWebstoreInstallRequest] = [:]
	private var webstoreConsumer: AsyncStream<BrowserWebstoreInstallRequest>.Continuation?
	private var webstoreConsumerID: UUID?
	private var inventories: [Profile.ID: Inventory] = [:]
	private var busy: Set<Profile.ID> = []

	internal init(
		legacyProfileID: Profile.ID,
		optionsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		openOptions: @escaping @MainActor @Sendable (
			String,
			ChromiumExtensionInventory
		) async throws -> ChromiumExtensionInventory = { _, _ in
			throw ChromiumExtensionFailure.unavailable
		},
		available: @escaping @MainActor @Sendable () -> Bool,
		installationAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		ordinaryProfileExists: @escaping @MainActor @Sendable (Profile.ID) -> Bool,
		inspect: @escaping @MainActor @Sendable (UUID?) async throws -> ChromiumExtensionInventory,
		manage: @escaping @MainActor @Sendable (
			ChromiumExtensionAction,
			String,
			ChromiumExtensionInventory
		) async throws -> ChromiumExtensionInventory,
		readPackage: @escaping @Sendable (
			URL
		) async throws -> BrowserExtensionPackage = BrowserExtensionPackageReader.readSelectedFile,
		prepareInstallation: @escaping @MainActor @Sendable (
			BrowserExtensionPackage,
			String?,
			ChromiumExtensionInventory
		) async throws -> ChromiumExtensionInstallPrompt = { _, _, _ in
			throw ChromiumExtensionFailure.unavailable
		},
		resolveInstallation: @escaping @MainActor @Sendable (
			ChromiumExtensionInstallPrompt,
			Bool
		) async throws -> ChromiumExtensionInventory = { _, _ in
			throw ChromiumExtensionFailure.unavailable
		},
		cancelInstallation: @escaping @MainActor @Sendable (ChromiumExtensionInstallPrompt) -> Void = { _ in },
		unpackedAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		loadUnpacked: @escaping @MainActor @Sendable (
			URL,
			ChromiumExtensionInventory
		) async throws -> ChromiumExtensionInventory = { _, _ in
			throw ChromiumExtensionFailure.unavailable
		},
		webstoreAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		prepareWebstore: @escaping @MainActor @Sendable (
			ChromiumWebstoreInstallRequest,
			ChromiumExtensionInventory
		) async throws -> ChromiumExtensionInstallPrompt = { _, _ in
			throw ChromiumExtensionFailure.unavailable
		},
		declineWebstore: @escaping @MainActor @Sendable (ChromiumWebstoreInstallRequest) -> Void = { _ in },
		webstoreUpdateAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		prepareWebstoreUpdate: @escaping @MainActor @Sendable (
			String,
			ChromiumExtensionInventory
		) async throws -> ChromiumExtensionInstallPrompt = { _, _ in
			throw ChromiumExtensionFailure.unavailable
		},
		webstoreImportAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		prepareWebstoreImport: @escaping @MainActor @Sendable (
			String,
			ChromiumExtensionInventory
		) async throws -> ChromiumExtensionInstallPrompt = { _, _ in
			throw ChromiumExtensionFailure.unavailable
		}
	) {
		self.optionsAvailable = optionsAvailable
		self.openOptions = openOptions
		self.legacyProfileID = legacyProfileID
		self.available = available
		self.installationAvailable = installationAvailable
		self.ordinaryProfileExists = ordinaryProfileExists
		self.inspect = inspect
		self.manage = manage
		self.readPackage = readPackage
		self.prepareInstallation = prepareInstallation
		self.resolveInstallation = resolveInstallation
		self.cancelInstallation = cancelInstallation
		self.unpackedAvailable = unpackedAvailable
		self.loadUnpacked = loadUnpacked
		self.webstoreAvailable = webstoreAvailable
		self.prepareWebstore = prepareWebstore
		self.declineWebstore = declineWebstore
		self.webstoreUpdateAvailable = webstoreUpdateAvailable
		self.prepareWebstoreUpdate = prepareWebstoreUpdate
		self.webstoreImportAvailable = webstoreImportAvailable
		self.prepareWebstoreImport = prepareWebstoreImport
	}

	internal var client: BrowserExtensionsClient {
		.init(
			optionsAvailability: optionsAvailable,
			openOptions: { [self] in try await showOptions($0) },
			availability: available,
			installationAvailability: installationAvailable,
			inspect: { [self] in try await load($0) },
			manage: { [self] in try await perform($0) },
			prepareInstallation: { [self] in try await prepare($0) },
			resolveInstallation: { [self] in try await resolve($0, accept: $1) },
			cancelInstallation: { [self] in cancel($0) },
			unpackedAvailability: unpackedAvailable,
			loadUnpacked: { [self] in try await load($0) },
			webstoreAvailability: { [self] in installationAvailable() && webstoreAvailable() },
			webstoreInstallRequests: { [self] in webstoreRequestStream() },
			prepareWebstoreInstallation: { [self] in try await prepare($0, inventory: $1) },
			declineWebstoreInstallation: { [self] in decline($0) },
			webstoreUpdateAvailability: { [self] in installationAvailable() && webstoreUpdateAvailable() },
			prepareWebstoreUpdate: { [self] in try await prepare($0) },
			webstoreImportAvailability: { [self] in installationAvailable() && webstoreImportAvailable() },
			prepareWebstoreImport: { [self] in try await prepare($0) },
			icon: { await BrowserExtensionIconReader.read($0) }
		)
	}

	/// The store asked to install an item in a page's ordinary profile. True
	/// hands it to the app's one consumer; the native token stays here.
	internal func offerWebstore(_ native: ChromiumWebstoreInstallRequest) -> Bool {
		let profileID = Profile.ID.chromium(native.profileID, legacy: legacyProfileID)
		guard
			available(),
			installationAvailable(),
			webstoreAvailable(),
			ordinaryProfileExists(profileID),
			let webstoreConsumer
		else { return false }

		let value = BrowserWebstoreInstallRequest(
			id: UUID(),
			profileID: profileID,
			extensionID: native.extensionID
		)
		webstoreRequests[value.id] = native
		webstoreConsumer.yield(value)
		return true
	}

	private func webstoreRequestStream() -> AsyncStream<BrowserWebstoreInstallRequest> {
		let (stream, continuation) = AsyncStream<BrowserWebstoreInstallRequest>.makeStream(
			bufferingPolicy: .bufferingNewest(4)
		)

		// One consumer: a newer one replaces the previous stream.
		let previous = webstoreConsumer
		webstoreConsumer = continuation
		previous?.finish()
		let consumer = UUID()
		webstoreConsumerID = consumer
		continuation.onTermination = { _ in
			Task { @MainActor [weak self] in
				guard let self, webstoreConsumerID == consumer else { return }
				webstoreConsumer = nil

				// Unanswered requests would otherwise wait out their native timeout.
				for (id, native) in webstoreRequests {
					webstoreRequests[id] = nil
					declineWebstore(native)
				}
			}
		}
		return stream
	}

	private func decline(_ request: BrowserWebstoreInstallRequest) {
		guard let native = webstoreRequests.removeValue(forKey: request.id) else { return }
		declineWebstore(native)
	}

	private func prepare(
		_ request: BrowserWebstoreInstallRequest,
		inventory value: BrowserExtensionInventory
	) async throws -> BrowserExtensionInstallPrompt {
		// The request is used once, whatever happens next.
		guard let native = webstoreRequests.removeValue(forKey: request.id)
		else { throw BrowserExtensionsClient.Failure.staleInventory }

		do {
			try authorize(request.profileID)
			guard installationAvailable(), webstoreAvailable()
			else { throw BrowserExtensionsClient.Failure.unavailable }
			guard value.profileID == request.profileID, !busy.contains(request.profileID)
			else { throw BrowserExtensionsClient.Failure.busy }
			guard
				let inventory = inventories[request.profileID],
				inventory.value == value
			else { throw BrowserExtensionsClient.Failure.staleInventory }
			guard !value.extensions.contains(where: { $0.id == request.extensionID })
			else { throw BrowserExtensionsClient.Failure.invalidRequest }

			busy.insert(request.profileID)
			inventories[request.profileID] = nil
			var retained = false
			defer { if !retained { busy.remove(request.profileID) } }
			do {
				let prompt = try await prepareWebstore(native, inventory.native)
				let result = try installation(
					prompt,
					for: request.profileID,
					inventory: value,
					expectedExtensionID: nil,
					webstoreExtensionID: request.extensionID
				)
				retained = true
				return result
			} catch let failure as ChromiumExtensionFailure {
				throw Self.failure(failure)
			}
		} catch {
			// A request refused before its download still answers the store.
			if !(error is CancellationError) { declineWebstore(native) }
			throw error
		}
	}

	/// DEV-845. The same bounds as a store install: the displayed inventory, an extension it
	/// doesn't have yet, and one request per profile.
	private func prepare(
		_ request: BrowserWebstoreImportRequest
	) async throws -> BrowserExtensionInstallPrompt {
		try authorize(request.profileID)
		guard installationAvailable(), webstoreImportAvailable()
		else { throw BrowserExtensionsClient.Failure.unavailable }
		guard !busy.contains(request.profileID) else { throw BrowserExtensionsClient.Failure.busy }
		guard
			let inventory = inventories[request.profileID],
			inventory.value.id == request.inventoryID,
			inventory.value.revision == request.revision
		else { throw BrowserExtensionsClient.Failure.staleInventory }
		guard !inventory.value.extensions.contains(where: { $0.id == request.extensionID })
		else { throw BrowserExtensionsClient.Failure.invalidRequest }

		busy.insert(request.profileID)
		inventories[request.profileID] = nil
		var retained = false
		defer { if !retained { busy.remove(request.profileID) } }
		do {
			let native = try await prepareWebstoreImport(request.extensionID, inventory.native)
			let value = try installation(
				native,
				for: request.profileID,
				inventory: inventory.value,
				expectedExtensionID: nil,
				webstoreExtensionID: request.extensionID
			)
			retained = true
			return value
		} catch let failure as ChromiumExtensionFailure {
			throw Self.failure(failure)
		}
	}

	/// DEV-776. The same bounds as a local update: the displayed inventory, an extension
	/// the user may replace, and one request per profile.
	private func prepare(
		_ request: BrowserWebstoreUpdateRequest
	) async throws -> BrowserExtensionInstallPrompt {
		try authorize(request.profileID)
		guard installationAvailable(), webstoreUpdateAvailable()
		else { throw BrowserExtensionsClient.Failure.unavailable }
		guard !busy.contains(request.profileID) else { throw BrowserExtensionsClient.Failure.busy }
		guard
			let inventory = inventories[request.profileID],
			inventory.value.id == request.inventoryID,
			inventory.value.revision == request.revision
		else { throw BrowserExtensionsClient.Failure.staleInventory }
		guard
			let item = inventory.value.extensions.first(where: { $0.id == request.extensionID }),
			item.fromWebStore
		else { throw BrowserExtensionsClient.Failure.invalidRequest }

		guard item.allows(.remove) else { throw BrowserExtensionsClient.Failure.blockedByPolicy }

		busy.insert(request.profileID)
		var retained = false
		defer { if !retained { busy.remove(request.profileID) } }
		do {
			let native = try await prepareWebstoreUpdate(request.extensionID, inventory.native)
			let value = try installation(
				native,
				for: request.profileID,
				inventory: inventory.value,
				expectedExtensionID: request.extensionID,
				webstoreExtensionID: request.extensionID
			)

			// The update consumed the inventory's authority; nothing up to date did.
			inventories[request.profileID] = nil
			retained = true
			return value
		} catch let failure as ChromiumExtensionFailure {
			// Nothing newer leaves the inventory as it was, so the next check can use it.
			if failure != .upToDate { inventories[request.profileID] = nil }
			throw Self.failure(failure)
		} catch {
			inventories[request.profileID] = nil
			throw error
		}
	}

	private func authorize(_ profileID: Profile.ID) throws {
		try Task.checkCancellation()

		guard available()
		else { throw BrowserExtensionsClient.Failure.unavailable }

		guard ordinaryProfileExists(profileID) else {
			inventories[profileID] = nil
			throw BrowserExtensionsClient.Failure.missingProfile
		}
	}

	private func load(_ profileID: Profile.ID) async throws -> BrowserExtensionInventory {
		try authorize(profileID)

		guard busy.insert(profileID).inserted
		else { throw BrowserExtensionsClient.Failure.busy }

		defer { busy.remove(profileID) }
		inventories[profileID] = nil

		do {
			let native = try await inspect(nativeProfile(profileID))
			try authorize(profileID)

			return try accept(native, for: profileID)
		} catch let failure as ChromiumExtensionFailure {
			throw Self.failure(failure)
		}
	}

	private func perform(
		_ request: BrowserExtensionRequest
	) async throws -> BrowserExtensionInventory {
		try authorize(request.profileID)

		guard !busy.contains(request.profileID)
		else { throw BrowserExtensionsClient.Failure.busy }

		guard
			let inventory = inventories[request.profileID],
			inventory.value.id == request.inventoryID,
			inventory.value.revision == request.revision,
			let item = inventory.value.extensions.first(where: { $0.id == request.extensionID })
		else { throw BrowserExtensionsClient.Failure.staleInventory }

		guard item.allows(request.action) else {
			throw request.action == .enable
			? BrowserExtensionsClient.Failure.reviewRequired
			: .blockedByPolicy
		}

		busy.insert(request.profileID)
		defer { busy.remove(request.profileID) }

		// A request consumes its authority even on failure or cancellation. Refresh before retrying.
		inventories[request.profileID] = nil

		let action: ChromiumExtensionAction = switch request.action {
		case .enable: .enable
		case .disable: .disable
		case .remove: .remove
		case .reload: .reload
		case .allowInPrivate: .allowInPrivate
		case .disallowInPrivate: .disallowInPrivate
		}
		do {
			let native = try await manage(action, request.extensionID, inventory.native)
			try authorize(request.profileID)

			guard native.revision > inventory.native.revision
			else { throw BrowserExtensionsClient.Failure.staleInventory }

			let item = native.extensions.first { $0.id == request.extensionID }
			let applied = switch request.action {
			case .enable: item?.state == .enabled
			case .disable: item?.state == .disabled
			case .remove: item == nil
			case .reload: item != nil
			case .allowInPrivate: item?.allowedInPrivate == true
			case .disallowInPrivate: item?.allowedInPrivate == false
			}

			guard applied
			else { throw BrowserExtensionsClient.Failure.failed }

			return try accept(native, for: request.profileID)
		} catch let failure as ChromiumExtensionFailure {
			throw Self.failure(failure)
		}
	}

	private func load(
		_ request: BrowserExtensionUnpackedRequest
	) async throws -> BrowserExtensionInventory {
		try authorize(request.profileID)

		guard unpackedAvailable()
		else { throw BrowserExtensionsClient.Failure.unavailable }
		guard !busy.contains(request.profileID)
		else { throw BrowserExtensionsClient.Failure.busy }
		guard
			let inventory = inventories[request.profileID],
			inventory.value.id == request.inventoryID,
			inventory.value.revision == request.revision
		else { throw BrowserExtensionsClient.Failure.staleInventory }

		busy.insert(request.profileID)
		defer { busy.remove(request.profileID) }

		// A folder load consumes its authority even on failure. Refresh before retrying.
		inventories[request.profileID] = nil

		do {
			let native = try await loadUnpacked(request.directory, inventory.native)
			try authorize(request.profileID)

			guard native.revision > inventory.native.revision
			else { throw BrowserExtensionsClient.Failure.staleInventory }

			return try accept(native, for: request.profileID)
		} catch let failure as ChromiumExtensionFailure {
			throw Self.failure(failure)
		}
	}

	private func showOptions(
		_ request: BrowserExtensionViewRequest
	) async throws -> BrowserExtensionInventory {
		try authorize(request.profileID)

		guard optionsAvailable()
		else { throw BrowserExtensionsClient.Failure.unavailable }
		guard !busy.contains(request.profileID)
		else { throw BrowserExtensionsClient.Failure.busy }
		guard
			let inventory = inventories[request.profileID],
			inventory.value.id == request.inventoryID,
			inventory.value.revision == request.revision,
			let item = inventory.value.extensions.first(where: { $0.id == request.extensionID }),
			item.canOpenOptions,
			item.state == .enabled,
			!item.permissionsIncreased
		else { throw BrowserExtensionsClient.Failure.staleInventory }

		busy.insert(request.profileID)
		defer { busy.remove(request.profileID) }
		inventories[request.profileID] = nil

		do {
			let native = try await openOptions(request.extensionID, inventory.native)
			try authorize(request.profileID)

			guard native.revision >= inventory.native.revision
			else { throw BrowserExtensionsClient.Failure.staleInventory }

			return try accept(native, for: request.profileID)
		} catch let failure as ChromiumExtensionFailure {
			throw Self.failure(failure)
		}
	}

	private func prepare(
		_ request: BrowserExtensionInstallRequest
	) async throws -> BrowserExtensionInstallPrompt {
		try authorize(request.profileID)
		guard installationAvailable() else { throw BrowserExtensionsClient.Failure.unavailable }
		guard !busy.contains(request.profileID) else { throw BrowserExtensionsClient.Failure.busy }
		guard
			let inventory = inventories[request.profileID],
			inventory.value.id == request.inventoryID,
			inventory.value.revision == request.revision
		else { throw BrowserExtensionsClient.Failure.staleInventory }

		if let expected = request.expectedExtensionID {
			let isReplaceable = inventory.value.extensions.contains {
				$0.id == expected && $0.allows(.remove)
			}
			guard isReplaceable
			else { throw BrowserExtensionsClient.Failure.blockedByPolicy }
		}

		busy.insert(request.profileID)
		inventories[request.profileID] = nil
		var retained = false
		defer { if !retained { busy.remove(request.profileID) } }
		do {
			let package = try await readPackage(request.selectedFile)
			try authorize(request.profileID)
			guard installationAvailable() else { throw BrowserExtensionsClient.Failure.unavailable }
			guard !package.data.isEmpty, package.data.count <= BrowserExtensionPackage.maximumBytes
			else { throw BrowserExtensionsClient.Failure.limitExceeded }

			let native = try await prepareInstallation(
				package,
				request.expectedExtensionID,
				inventory.native
			)
			let value = try installation(
				native,
				for: request.profileID,
				inventory: inventory.value,
				expectedExtensionID: request.expectedExtensionID,
				webstoreExtensionID: nil
			)
			retained = true
			return value
		} catch let failure as ChromiumExtensionFailure {
			throw Self.failure(failure)
		}
	}

	/// Checks a native prompt against the request that produced it and keeps its
	/// authority here, behind a surrogate the feature can show.
	private func installation(
		_ native: ChromiumExtensionInstallPrompt,
		for profileID: Profile.ID,
		inventory: BrowserExtensionInventory,
		expectedExtensionID: String?,
		webstoreExtensionID: String?
	) throws -> BrowserExtensionInstallPrompt {
		do {
			try authorize(profileID)
			guard
				installationAvailable(),
				native.profileID == nativeProfile(profileID),
				native.inventoryRevision == inventory.revision,
				native.candidate.isUpdate == (expectedExtensionID != nil),
				expectedExtensionID == nil || native.candidate.id == expectedExtensionID,
				webstoreExtensionID == nil || native.candidate.id == webstoreExtensionID
			else { throw BrowserExtensionsClient.Failure.staleInventory }
		} catch {
			cancelInstallation(native)
			throw error
		}

		let candidate = native.candidate
		let value = BrowserExtensionInstallPrompt(
			id: UUID(),
			profileID: profileID,
			inventoryID: inventory.id,
			revision: inventory.revision,
			candidate: .init(
				extensionID: candidate.id,
				name: candidate.name,
				version: candidate.version,
				packageSHA256: candidate.packageSHA256,
				sourceBasename: candidate.sourceBasename,
				isUpdate: candidate.isUpdate,
				requiredPermissions: .init(
					apis: candidate.requiredPermissions.apis,
					hosts: candidate.requiredPermissions.hosts
				),
				optionalPermissions: .init(
					apis: candidate.optionalPermissions.apis,
					hosts: candidate.optionalPermissions.hosts
				),
				warnings: candidate.warnings.map {
					.init(message: $0.message, details: $0.details)
				},
				permissionIncrease: candidate.permissionIncrease ?? candidate.isUpdate,
				publisher: candidate.publisher
			)
		)
		installations[value.id] = .init(native: native, value: value)
		return value
	}

	private func resolve(
		_ prompt: BrowserExtensionInstallPrompt,
		accept consent: Bool
	) async throws -> BrowserExtensionInventory {
		do {
			try authorize(prompt.profileID)
		} catch {
			cancel(prompt)
			throw error
		}

		guard installationAvailable() else {
			cancel(prompt)
			throw BrowserExtensionsClient.Failure.unavailable
		}
		guard let installation = installations[prompt.id], installation.value == prompt
		else { throw BrowserExtensionsClient.Failure.staleInventory }

		// Consume the surrogate before native submission, including refusals and
		// failures. Native and SDK independently consume their opaque authority.
		installations[prompt.id] = nil
		defer { busy.remove(prompt.profileID) }
		do {
			let native = try await resolveInstallation(installation.native, consent)
			try authorize(prompt.profileID)
			let isInstalled = native.extensions.contains {
				$0.id == prompt.candidate.extensionID && $0.version == prompt.candidate.version
			}
			guard
				consent,
				native.revision > prompt.revision,
				isInstalled
			else { throw BrowserExtensionsClient.Failure.invalidResponse }
			return try accept(native, for: prompt.profileID)
		} catch ChromiumExtensionFailure.cancelled where !consent {
			// The native terminal callback follows physical cleanup. Only now is
			// it safe to refresh unchanged inventory after the user's refusal.
			try authorize(prompt.profileID)
			let native: ChromiumExtensionInventory
			do {
				native = try await inspect(nativeProfile(prompt.profileID))
			} catch let failure as ChromiumExtensionFailure {
				throw Self.failure(failure)
			}
			try authorize(prompt.profileID)
			return try accept(native, for: prompt.profileID)
		} catch let failure as ChromiumExtensionFailure {
			throw Self.failure(failure)
		}
	}

	private func cancel(_ prompt: BrowserExtensionInstallPrompt) {
		guard let installation = installations[prompt.id], installation.value == prompt
		else { return }
		installations[prompt.id] = nil
		busy.remove(prompt.profileID)
		cancelInstallation(installation.native)
	}

	private func nativeProfile(_ profileID: Profile.ID) -> UUID? {
		profileID.chromiumProfile(legacy: legacyProfileID)
	}

	private func accept(
		_ native: ChromiumExtensionInventory,
		for profileID: Profile.ID
	) throws -> BrowserExtensionInventory {
		let expected = nativeProfile(profileID)

		guard native.profileID == expected, native.revision > 0
		else { throw BrowserExtensionsClient.Failure.invalidResponse }

		let value = BrowserExtensionInventory(
			id: UUID(),
			profileID: profileID,
			revision: native.revision,
			extensions: native.extensions.map(Self.extensionValue)
		)
		inventories[profileID] = .init(native: native, value: value)

		return value
	}

	private static func extensionValue(_ value: ChromiumExtension) -> BrowserExtension {
		let state: BrowserExtension.State = switch value.state {
		case .enabled: .enabled
		case .disabled: .disabled
		case .terminated: .terminated
		case .blocklisted: .blocklisted
		case .blocked: .blocked
		}

		return .init(
			id: value.id,
			name: value.name,
			version: value.version,
			manifestVersion: value.manifestVersion,
			location: value.location.rawValue,
			fromWebStore: value.fromWebStore,
			state: state,
			disableReasons: value.disableReasons.map { .init(rawValue: $0.rawValue) },
			permissionsIncreased: value.permissionsIncreased,
			canEnable: value.canEnable,
			canDisable: value.canDisable,
			canRemove: value.canRemove,
			canOpenOptions: value.canOpenOptions == true,
			canReload: value.canReload == true && value.location == .unpacked,
			sourcePath: value.sourcePath,
			iconPath: value.iconPath,
			icons: ChromiumExtension.iconSizes(value.icons),
			actionIcons: ChromiumExtension.iconSizes(value.actionIcons),
			bundledIcon: value.componentIconData,
			allowedInPrivate: value.allowedInPrivate == true,
			canAllowInPrivate: value.canAllowInPrivate == true,
			canRunInPrivate: value.canRunInPrivate ?? true,
			requiredPermissions: .init(
				apis: value.requiredPermissions.apis,
				hosts: value.requiredPermissions.hosts
			),
			optionalPermissions: .init(
				apis: value.optionalPermissions.apis,
				hosts: value.optionalPermissions.hosts
			),
			activePermissions: .init(
				apis: value.activePermissions.apis,
				hosts: value.activePermissions.hosts
			),
			withheldPermissions: .init(
				apis: value.withheldPermissions.apis,
				hosts: value.withheldPermissions.hosts
			)
		)
	}

	private static func failure(
		_ failure: ChromiumExtensionFailure
	) -> BrowserExtensionsClient.Failure {
		switch failure {
		case .unavailable: .unavailable
		case .staleInventory: .staleInventory
		case .blockedByPolicy: .blockedByPolicy
		case .reviewRequired: .reviewRequired
		case .invalidRequest: .invalidRequest
		case .failed: .failed
		case .limitExceeded: .limitExceeded
		case .timeout: .timeout
		case .busy: .busy
		case .invalidResponse: .invalidResponse
		case .cancelled: .cancelled
		case .invalidPackage: .invalidPackage
		case .directoryMissing: .directoryMissing
		case .directoryUnreadable: .directoryUnreadable
		case let .invalidManifest(detail): .invalidManifest(detail)
		case .upToDate: .upToDate
		}
	}
}
