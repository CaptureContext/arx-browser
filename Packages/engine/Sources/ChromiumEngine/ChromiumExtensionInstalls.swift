import ChromiumBridge
import CryptoKit
import Foundation

@MainActor
internal final class ChromiumExtensionInstalls {
	private let api: ArxEngineAPI
	private let runtimeID: UUID
	private let allocate: @MainActor () throws -> UInt64
	private var requests: [UInt64: Request] = [:]

	internal init(
		api: ArxEngineAPI,
		runtimeID: UUID,
		allocate: @escaping @MainActor () throws -> UInt64
	) {
		self.api = api
		self.runtimeID = runtimeID
		self.allocate = allocate
	}

	internal var isAvailable: Bool {
		api.extension_install_available?() == true
		&& api.install_extension_crx != nil
		&& api.resolve_extension_install != nil
	}

	internal var isWebstoreAvailable: Bool {
		isAvailable
		&& api.install_webstore_extension != nil
		&& api.decline_webstore_install != nil
	}

	internal func prepareWebstore(
		_ webstore: ChromiumWebstoreInstallRequest,
		inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard isWebstoreAvailable, let install = api.install_webstore_extension
		else { throw ChromiumExtensionFailure.unavailable }
		guard
			webstore.profileID == inventory.profileID,
			ChromiumExtension.validID(webstore.extensionID)
		else { throw ChromiumExtensionFailure.invalidRequest }
		guard !inventory.extensions.contains(where: { $0.id == webstore.extensionID })
		else { throw ChromiumExtensionFailure.invalidRequest }
		return try await prepare(
			inventory: inventory,
			expectedID: nil,
			webstoreID: webstore.extensionID,
			basename: ChromiumWebstoreInstallRequest.sourceName,
			digest: nil
		) { key, id in
			install(key, id, inventory.revision, webstore.token)
		}
	}

	/// ABI45 (DEV-776). Store updates: an installed internal store extension, updated from
	/// the store through the same verified review. `.upToDate` when the store has nothing newer.
	internal var isWebstoreUpdateAvailable: Bool {
		isAvailable && api.update_webstore_extension != nil
	}

	internal func prepareWebstoreUpdate(
		of extensionID: String,
		inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard isWebstoreUpdateAvailable, let update = api.update_webstore_extension
		else { throw ChromiumExtensionFailure.unavailable }
		guard
			ChromiumExtension.validID(extensionID),
			inventory.extensions.contains(where: {
				$0.id == extensionID && $0.fromWebStore && $0.location == .internalInstall
			})
		else { throw ChromiumExtensionFailure.invalidRequest }
		return try await prepare(
			inventory: inventory,
			expectedID: extensionID,
			webstoreID: extensionID,
			basename: ChromiumWebstoreInstallRequest.sourceName,
			digest: nil
		) { key, id in
			update(key, id, inventory.revision, extensionID)
		}
	}

	/// ABI47 (DEV-845). A new install of a store item by ID, with no store page: an
	/// extension brought over from another browser, through the same verified review.
	internal var isWebstoreImportAvailable: Bool {
		isAvailable && api.install_webstore_extension_by_id != nil
	}

	internal func prepareWebstoreImport(
		of extensionID: String,
		inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard isWebstoreImportAvailable, let install = api.install_webstore_extension_by_id
		else { throw ChromiumExtensionFailure.unavailable }
		guard
			ChromiumExtension.validID(extensionID),
			!inventory.extensions.contains(where: { $0.id == extensionID })
		else { throw ChromiumExtensionFailure.invalidRequest }
		return try await prepare(
			inventory: inventory,
			expectedID: nil,
			webstoreID: extensionID,
			basename: ChromiumWebstoreInstallRequest.sourceName,
			digest: nil
		) { key, id in
			install(key, id, inventory.revision, extensionID)
		}
	}

	internal func prepare(
		data: Data,
		basename: String,
		expectedID: String?,
		inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard isAvailable, let install = api.install_extension_crx
		else { throw ChromiumExtensionFailure.unavailable }
		guard !data.isEmpty, data.count <= ChromiumExtensionInstallPrompt.maximumPackageBytes
		else { throw ChromiumExtensionFailure.limitExceeded }
		guard Self.validBasename(basename)
		else { throw ChromiumExtensionFailure.invalidRequest }
		let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		return try await prepare(
			inventory: inventory,
			expectedID: expectedID,
			basename: basename,
			digest: digest
		) { key, id in
			data.withUnsafeBytes { bytes in
				install(
					key,
					id,
					inventory.revision,
					expectedID ?? "",
					basename,
					bytes.bindMemory(to: UInt8.self).baseAddress,
					bytes.count
				)
			}
		}
	}

	internal func prepareFixture(
		variant: UInt32,
		expectedID: String?,
		inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard variant < 4, let fixture = api.install_extension_fixture
		else { throw ChromiumExtensionFailure.unavailable }
		return try await prepare(
			inventory: inventory,
			expectedID: expectedID,
			basename: "Arx Disposable Signed Fixture.crx",
			digest: nil
		) { key, id in
			fixture(key, id, inventory.revision, expectedID ?? "", variant)
		}
	}

	private func prepare(
		inventory: ChromiumExtensionInventory,
		expectedID: String?,
		webstoreID: String? = nil,
		basename: String,
		digest: String?,
		start: (String, UInt64) -> Void
	) async throws -> ChromiumExtensionInstallPrompt {
		try Task.checkCancellation()
		guard inventory.runtimeID == runtimeID, inventory.revision > 0
		else { throw ChromiumExtensionFailure.staleInventory }
		if let expectedID {
			guard
				ChromiumExtension.validID(expectedID),
				inventory.extensions.contains(where: { $0.id == expectedID })
			else { throw ChromiumExtensionFailure.staleInventory }
		}
		guard
			requests.count < 2,
			!requests.values.contains(where: { $0.profileID == inventory.profileID })
		else { throw ChromiumExtensionFailure.busy }
		let id = try allocate()
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				requests[id] = .init(
					profileID: inventory.profileID,
					revision: inventory.revision,
					expectedID: expectedID,
					webstoreID: webstoreID,
					basename: basename,
					digest: digest,
					prepare: continuation
				)
				start(Self.key(inventory.profileID), id)
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.cancel(id, failure: CancellationError()) }
		}
	}

	internal func resolve(
		_ prompt: ChromiumExtensionInstallPrompt,
		accept: Bool
	) async throws -> ChromiumExtensionInventory {
		try Task.checkCancellation()
		guard
			prompt.runtimeID == runtimeID,
			let request = requests[prompt.requestID],
			request.prompt == prompt,
			!request.resolutionSent,
			let resolve = api.resolve_extension_install
		else { throw ChromiumExtensionFailure.staleInventory }
		let id = prompt.requestID
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				request.resolutionSent = true
				request.finish = continuation
				if !resolve(Self.key(prompt.profileID), id, prompt.token, accept) {
					cancel(id, failure: ChromiumExtensionFailure.staleInventory)
				}
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.cancel(id, failure: CancellationError()) }
		}
	}

	internal func cancel(_ prompt: ChromiumExtensionInstallPrompt) {
		guard
			prompt.runtimeID == runtimeID,
			requests[prompt.requestID]?.prompt == prompt
		else { return }
		cancel(prompt.requestID, failure: CancellationError())
	}

	private func cancel(
		_ id: UInt64,
		failure: any Error
	) {
		guard let request = requests.removeValue(forKey: id) else { return }
		api.cancel_extension_request?(id)
		request.prepare?.resume(throwing: failure)
		request.finish?.resume(throwing: failure)
	}

	internal func prompt(
		_ id: UInt64,
		profileKey: String,
		token: UInt64,
		bytes: UnsafePointer<UInt8>?,
		count: Int
	) {
		guard let request = requests[id] else { return }
		do {
			guard
				Self.key(request.profileID) == profileKey,
				token > 0,
				request.prompt == nil,
				!request.resolutionSent,
				let continuation = request.prepare,
				let bytes,
				count > 0,
				count <= 1_048_576
			else { throw ChromiumExtensionFailure.invalidResponse }
			let data = Data(bytes: bytes, count: count)
			let candidate = try JSONDecoder().decode(
				ChromiumExtensionInstallPrompt.Candidate.self,
				from: data
			)
			guard
				candidate.isValid,
				candidate.sourceBasename == request.basename,
				candidate.isUpdate == (request.expectedID != nil),
				request.expectedID == nil || candidate.id == request.expectedID,
				request.webstoreID == nil || candidate.id == request.webstoreID,
				request.digest == nil || candidate.packageSHA256 == request.digest
			else { throw ChromiumExtensionFailure.invalidResponse }
			let prompt = ChromiumExtensionInstallPrompt(
				runtimeID: runtimeID,
				requestID: id,
				token: token,
				profileID: request.profileID,
				inventoryRevision: request.revision,
				candidate: candidate
			)
			request.prompt = prompt
			request.prepare = nil
			continuation.resume(returning: prompt)
		} catch {
			cancel(id, failure: ChromiumExtensionFailure.invalidResponse)
		}
	}

	internal func complete(
		_ id: UInt64,
		profileKey: String,
		status: ArxExtensionStatus,
		revision: UInt64,
		bytes: UnsafePointer<UInt8>?,
		count: Int
	) -> Bool {
		guard let request = requests.removeValue(forKey: id) else { return false }
		do {
			guard Self.key(request.profileID) == profileKey
			else { throw ChromiumExtensionFailure.staleInventory }
			guard status == ARX_EXTENSION_SUCCESS
			else { throw ChromiumExtensionFailure(status: status) }
			guard request.resolutionSent, let continuation = request.finish
			else { throw ChromiumExtensionFailure.invalidResponse }
			guard let bytes, count > 0, count <= 1_048_576, revision > request.revision
			else { throw ChromiumExtensionFailure.invalidResponse }
			let payload = try JSONDecoder().decode(Payload.self, from: Data(bytes: bytes, count: count))
			guard
				payload.extensions.count <= 512,
				Set(payload.extensions.map(\.id)).count == payload.extensions.count,
				payload.extensions.allSatisfy(\.isValid),
				let candidate = request.prompt?.candidate,
				payload.extensions.contains(where: { $0.id == candidate.id && $0.version == candidate.version })
			else { throw ChromiumExtensionFailure.invalidResponse }
			continuation.resume(
				returning: .init(
					runtimeID: runtimeID,
					profileID: request.profileID,
					revision: revision,
					extensions: payload.extensions
				)
			)
		} catch {
			let failure = error as? ChromiumExtensionFailure ?? .invalidResponse
			request.prepare?.resume(throwing: failure)
			request.finish?.resume(throwing: failure)
		}
		return true
	}

	internal func stop() {
		for id in Array(requests.keys) { cancel(id, failure: ChromiumExtensionFailure.unavailable) }
	}

	private static func key(_ profileID: UUID?) -> String { profileID?.uuidString.lowercased() ?? "" }

	private static func validBasename(_ name: String) -> Bool {
		!name.isEmpty && name.utf8.count <= 255
		&& !name.utf8.contains { $0 < 32 || $0 == 127 || $0 == 47 || $0 == 92 }
	}

	private final class Request {
		internal let profileID: UUID?
		internal let revision: UInt64
		internal let expectedID: String?
		internal let webstoreID: String?
		internal let basename: String
		internal let digest: String?
		internal var prepare: CheckedContinuation<ChromiumExtensionInstallPrompt, any Error>?
		internal var finish: CheckedContinuation<ChromiumExtensionInventory, any Error>?
		internal var prompt: ChromiumExtensionInstallPrompt?
		internal var resolutionSent: Bool

		internal init(
			profileID: UUID?,
			revision: UInt64,
			expectedID: String?,
			webstoreID: String?,
			basename: String,
			digest: String?,
			prepare: CheckedContinuation<ChromiumExtensionInstallPrompt, any Error>
		) {
			self.profileID = profileID
			self.revision = revision
			self.expectedID = expectedID
			self.webstoreID = webstoreID
			self.basename = basename
			self.digest = digest
			self.prepare = prepare
			self.finish = nil
			self.prompt = nil
			self.resolutionSent = false
		}
	}

	private struct Payload: Decodable {
		internal let extensions: [ChromiumExtension]

		internal init(extensions: [ChromiumExtension]) {
			self.extensions = extensions
		}
	}
}
