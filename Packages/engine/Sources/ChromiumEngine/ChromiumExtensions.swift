import ChromiumBridge
import Foundation

@MainActor
internal final class ChromiumExtensions {
	private let api: ArxEngineAPI
	internal let runtimeID: UUID = .init()
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: Request] = [:]
	internal private(set) var isEnabled: Bool = false
	internal private(set) var isFixture: Bool = false
	internal private(set) var isSignedFixture: Bool = false
	internal lazy var installs: ChromiumExtensionInstalls = .init(
		api: api,
		runtimeID: runtimeID
	) { [unowned self] in
		try allocateRequest()
	}

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal func configure(
		enabled: Bool,
		fixture: Bool,
		signedFixture: Bool = false
	) {
		isEnabled = enabled || fixture || signedFixture
		isFixture = fixture
		isSignedFixture = signedFixture
	}

	internal func inspect(profileID: UUID?) async throws -> ChromiumExtensionInventory {
		guard let inspect = api.inspect_extensions
		else { throw ChromiumExtensionFailure.unavailable }

		return try await request(profileID: profileID) { key, request in inspect(key, request) }
	}

	internal func owns(_ inventory: ChromiumExtensionInventory) -> Bool {
		inventory.runtimeID == runtimeID
	}

	internal func manage(
		_ action: ChromiumExtensionAction,
		extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard
			inventory.runtimeID == runtimeID,
			let extension_ = inventory.extensions.first(where: { $0.id == extensionID })
		else { throw ChromiumExtensionFailure.staleInventory }

		let native: ArxExtensionAction
		switch action {
		case .enable:
			guard extension_.canEnable
			else { throw ChromiumExtensionFailure.reviewRequired }
			native = ARX_EXTENSION_ENABLE

		case .disable:
			guard extension_.canDisable
			else { throw ChromiumExtensionFailure.blockedByPolicy }
			native = ARX_EXTENSION_DISABLE

		case .remove:
			guard extension_.canRemove
			else { throw ChromiumExtensionFailure.blockedByPolicy }
			native = ARX_EXTENSION_REMOVE

		case .reload:
			guard extension_.canReload == true, extension_.location == .unpacked
			else { throw ChromiumExtensionFailure.blockedByPolicy }
			native = ARX_EXTENSION_RELOAD

		case .allowInPrivate:
			guard extension_.canAllowInPrivate == true
			else { throw ChromiumExtensionFailure.blockedByPolicy }
			native = ARX_EXTENSION_ALLOW_PRIVATE

		case .disallowInPrivate:
			guard extension_.canAllowInPrivate == true
			else { throw ChromiumExtensionFailure.blockedByPolicy }
			native = ARX_EXTENSION_DISALLOW_PRIVATE
		}

		return try await perform(native, extensionID: extensionID, in: inventory)
	}

	internal var isUnpackedAvailable: Bool {
		isEnabled
		&& api.unpacked_extensions_available?() == true
		&& api.load_unpacked_extension != nil
	}

	/// The folder path is borrowed only for the native call; Chromium reads it
	/// through its unpacked installer and policy checks.
	internal func loadUnpacked(
		directory: URL,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard inventory.runtimeID == runtimeID
		else { throw ChromiumExtensionFailure.staleInventory }

		guard isUnpackedAvailable, let load = api.load_unpacked_extension
		else { throw ChromiumExtensionFailure.unavailable }

		let path = directory.standardizedFileURL.path(percentEncoded: false)
		guard
			directory.isFileURL,
			ChromiumExtension.validSourcePath(path)
		else { throw ChromiumExtensionFailure.invalidRequest }

		return try await request(profileID: inventory.profileID) { key, request in
			load(key, request, inventory.revision, path)
		}
	}

	internal func openOptions(
		extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard
			inventory.runtimeID == runtimeID,
			let item = inventory.extensions.first(where: { $0.id == extensionID }),
			item.canOpenOptions == true,
			item.state == .enabled,
			!item.permissionsIncreased,
			api.extension_views_available?() == true,
			let open = api.open_extension_view
		else { throw ChromiumExtensionFailure.unavailable }

		return try await request(
			profileID: inventory.profileID,
			optionsExtensionID: extensionID
		) { key, request in
			open(key, request, inventory.revision, extensionID, ARX_EXTENSION_VIEW_OPTIONS, 0, 0)
		}
	}

	/// Admission belongs to one pending options request, never an extension ID alone.
	internal func consumeOptionsOffer(
		request: UInt64,
		profileKey: String,
		extensionID: String
	) -> Bool {
		guard
			var pending = requests[request],
			(pending.profileID?.uuidString.lowercased() ?? "") == profileKey,
			pending.optionsExtensionID == extensionID,
			!pending.offered
		else { return false }

		pending.offered = true
		requests[request] = pending
		return true
	}

	internal func loadFixture(profileID: UUID?) async throws -> ChromiumExtensionInventory {
		guard isFixture, let load = api.load_extension_fixture
		else { throw ChromiumExtensionFailure.unavailable }

		return try await request(profileID: profileID) { key, request in load(key, request) }
	}

	internal func requireFixturePermissions(
		extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard
			isFixture,
			inventory.extensions.contains(where: { $0.id == extensionID && $0.isFixture })
		else { throw ChromiumExtensionFailure.unavailable }

		return try await perform(
			ARX_EXTENSION_FIXTURE_REQUIRE_PERMISSIONS,
			extensionID: extensionID,
			in: inventory
		)
	}

	internal func attemptFixtureEnable(
		extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard
			isFixture,
			inventory.extensions.contains(where: { $0.id == extensionID && $0.isFixture })
		else { throw ChromiumExtensionFailure.unavailable }

		return try await perform(ARX_EXTENSION_ENABLE, extensionID: extensionID, in: inventory)
	}

	private func perform(
		_ action: ArxExtensionAction,
		extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard inventory.runtimeID == runtimeID
		else { throw ChromiumExtensionFailure.staleInventory }
		guard let manage = api.manage_extension
		else { throw ChromiumExtensionFailure.unavailable }

		return try await request(profileID: inventory.profileID) { key, request in
			manage(key, request, inventory.revision, extensionID, action)
		}
	}

	private func request(
		profileID: UUID?,
		optionsExtensionID: String? = nil,
		start: (String, UInt64) -> Void
	) async throws -> ChromiumExtensionInventory {
		try Task.checkCancellation()
		guard isEnabled
		else { throw ChromiumExtensionFailure.unavailable }
		guard requests.count < 32 else { throw ChromiumExtensionFailure.busy }
		let id = try allocateRequest()

		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				requests[id] = .init(
					profileID: profileID,
					optionsExtensionID: optionsExtensionID,
					continuation: continuation
				)
				start(profileID?.uuidString.lowercased() ?? "", id)
			}
		} onCancel: {
			Task { @MainActor [weak self] in
				self?.cancel(id)
			}
		}
	}

	private func allocateRequest() throws -> UInt64 {
		guard nextRequest < UInt64.max else { throw ChromiumExtensionFailure.busy }
		defer { nextRequest += 1 }
		return nextRequest
	}

	private func cancel(_ id: UInt64) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		api.cancel_extension_request?(id)
		request.continuation.resume(throwing: CancellationError())
	}

	internal func complete(
		_ id: UInt64,
		profileKey: String,
		status: ArxExtensionStatus,
		revision: UInt64,
		bytes: UnsafePointer<UInt8>?,
		count: Int
	) {
		let isInstallRequest = installs.complete(
			id,
			profileKey: profileKey,
			status: status,
			revision: revision,
			bytes: bytes,
			count: count
		)
		if isInstallRequest { return }

		guard let request = requests.removeValue(forKey: id)
		else { return }

		do {
			guard profileKey == (request.profileID?.uuidString.lowercased() ?? "")
			else { throw ChromiumExtensionFailure.staleInventory }
			guard status == ARX_EXTENSION_SUCCESS else {
				throw ChromiumExtensionFailure(status: status, detail: Self.detail(bytes, count: count))
			}
			guard request.optionsExtensionID == nil || request.offered
			else { throw ChromiumExtensionFailure.invalidResponse }

			guard count > 0, count <= 1_048_576
			else { throw ChromiumExtensionFailure.limitExceeded }
			guard let bytes, revision > 0
			else { throw ChromiumExtensionFailure.invalidResponse }

			// The native pointer is borrowed only for this callback; copy before decoding.
			let data = Data(bytes: bytes, count: count)
			let payload = try JSONDecoder().decode(Payload.self, from: data)
			guard
				payload.extensions.count <= 512,
				Set(payload.extensions.map(\.id)).count == payload.extensions.count,
				payload.extensions.allSatisfy(\.isValid)
			else { throw ChromiumExtensionFailure.invalidResponse }

			request.continuation.resume(
				returning: .init(
					runtimeID: runtimeID,
					profileID: request.profileID,
					revision: revision,
					extensions: payload.extensions
				)
			)
		} catch let failure as ChromiumExtensionFailure {
			request.continuation.resume(throwing: failure)
		} catch {
			request.continuation.resume(throwing: ChromiumExtensionFailure.invalidResponse)
		}
	}

	internal func stop() {
		isEnabled = false
		isFixture = false
		isSignedFixture = false
		installs.stop()

		let pending = requests.values
		requests.removeAll()
		for request in pending {
			request.continuation.resume(throwing: ChromiumExtensionFailure.unavailable)
		}
	}

	private struct Request {
		internal let profileID: UUID?
		internal let optionsExtensionID: String?
		internal var offered: Bool
		internal let continuation: CheckedContinuation<ChromiumExtensionInventory, any Error>

		internal init(
			profileID: UUID?,
			optionsExtensionID: String?,
			continuation: CheckedContinuation<ChromiumExtensionInventory, any Error>
		) {
			self.profileID = profileID
			self.optionsExtensionID = optionsExtensionID
			self.offered = false
			self.continuation = continuation
		}
	}

	/// A failure payload is optional, bounded and copied during the callback.
	private static func detail(
		_ bytes: UnsafePointer<UInt8>?,
		count: Int
	) -> String? {
		guard let bytes, count > 0, count <= 16_384
		else { return nil }

		// The detail is optional; a malformed payload falls back to the bare status.
		let failure = try? JSONDecoder().decode(
			FailurePayload.self,
			from: Data(bytes: bytes, count: count)
		)
		guard
			let error = failure?.error,
			!error.isEmpty,
			error.utf8.count <= 2048,
			!error.utf8.contains(where: { $0 < 32 || $0 == 127 })
		else { return nil }

		return error
	}

	private struct Payload: Decodable {
		internal let extensions: [ChromiumExtension]

		internal init(extensions: [ChromiumExtension]) {
			self.extensions = extensions
		}
	}

	private struct FailurePayload: Decodable {
		internal let error: String

		internal init(error: String) {
			self.error = error
		}
	}
}

extension ChromiumExtensionFailure {
	internal init(
		status: ArxExtensionStatus,
		detail: String? = nil
	) {
		self = switch status {
		case ARX_EXTENSION_UNAVAILABLE: .unavailable
		case ARX_EXTENSION_STALE: .staleInventory
		case ARX_EXTENSION_POLICY_BLOCKED: .blockedByPolicy
		case ARX_EXTENSION_REVIEW_REQUIRED: .reviewRequired
		case ARX_EXTENSION_INVALID_REQUEST: .invalidRequest
		case ARX_EXTENSION_FAILED: .failed
		case ARX_EXTENSION_LIMIT_EXCEEDED: .limitExceeded
		case ARX_EXTENSION_TIMEOUT: .timeout
		case ARX_EXTENSION_BUSY: .busy
		case ARX_EXTENSION_CANCELLED: .cancelled
		case ARX_EXTENSION_INVALID_PACKAGE: .invalidPackage
		case ARX_EXTENSION_DIRECTORY_MISSING: .directoryMissing
		case ARX_EXTENSION_DIRECTORY_UNREADABLE: .directoryUnreadable
		case ARX_EXTENSION_MANIFEST_INVALID: .invalidManifest(detail ?? "")
		case ARX_EXTENSION_UP_TO_DATE: .upToDate
		default: .invalidResponse
		}
	}
}
