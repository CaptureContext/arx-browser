import AppKit
import ChromiumBridge
import Foundation

/// ABI52 (DEV-893). A saved address in one ordinary profile.
public struct ChromiumAutofillAddress: Codable, Equatable, Sendable {
	/// Nil for a new address.
	public var id: String?
	public var name: String
	public var organization: String
	public var street: String
	public var city: String
	public var state: String
	public var zip: String

	/// A two-letter country code, or empty.
	public var country: String
	public var phone: String
	public var email: String

	public init(
		id: String? = nil,
		name: String = "",
		organization: String = "",
		street: String = "",
		city: String = "",
		state: String = "",
		zip: String = "",
		country: String = "",
		phone: String = "",
		email: String = ""
	) {
		self.id = id
		self.name = name
		self.organization = organization
		self.street = street
		self.city = city
		self.state = state
		self.zip = zip
		self.country = country
		self.phone = phone
		self.email = email
	}
}

/// A saved payment card, by what its face shows in a list. Never its number.
public struct ChromiumAutofillCard: Decodable, Equatable, Sendable {
	public var id: String
	public var name: String

	/// Chromium's network name, such as `visa` or `mastercard`.
	public var network: String
	public var lastFour: String
	public var month: Int
	public var year: Int
	public var nickname: String

	public init(
		id: String,
		name: String,
		network: String,
		lastFour: String,
		month: Int,
		year: Int,
		nickname: String
	) {
		self.id = id
		self.name = name
		self.network = network
		self.lastFour = lastFour
		self.month = month
		self.year = year
		self.nickname = nickname
	}
}

/// What a new or edited card says besides its number.
public struct ChromiumAutofillCardDetails: Encodable, Equatable, Sendable {
	/// Nil for a new card.
	public var id: String?
	public var name: String
	public var nickname: String
	public var month: Int
	public var year: Int

	public init(
		id: String? = nil,
		name: String,
		nickname: String = "",
		month: Int,
		year: Int
	) {
		self.id = id
		self.name = name
		self.nickname = nickname
		self.month = month
		self.year = year
	}
}

public struct ChromiumAutofillListing: Decodable, Equatable, Sendable {
	public var addresses: [ChromiumAutofillAddress]
	public var cards: [ChromiumAutofillCard]

	public init(
		addresses: [ChromiumAutofillAddress] = [],
		cards: [ChromiumAutofillCard] = []
	) {
		self.addresses = addresses
		self.cards = cards
	}
}

public enum ChromiumAutofillDataFailure: Error, Equatable, Sendable {
	/// An older engine, a private or unknown profile, or data that didn't load.
	case unavailable

	/// Empty, too long or malformed fields, or a card number that isn't valid.
	case invalid
	case notFound
	case busy

	/// Filling that kind is off in Settings, and Chromium keeps no changes to it then.
	case disabled
}

/// Pending Settings › Autofill requests. Each native request replies once.
@MainActor
internal final class ChromiumAutofillData {
	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: CheckedContinuation<(ArxAutofillDataStatus, Data), any Error>] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.list_autofill_data != nil
		&& api.save_autofill_address != nil
		&& api.save_autofill_card != nil
		&& api.remove_autofill_data != nil
		&& api.cancel_autofill_data != nil
	}

	internal func list(profileKey: String) async throws(ChromiumAutofillDataFailure) -> ChromiumAutofillListing {
		try Self.listing(await request { [api] id in
			profileKey.withCString { api.list_autofill_data?($0, id) }
		})
	}

	internal func save(
		profileKey: String,
		address: ChromiumAutofillAddress
	) async throws(ChromiumAutofillDataFailure) -> ChromiumAutofillListing {
		guard let json = Self.json(address) else { throw .invalid }

		return try Self.listing(await request { [api] id in
			profileKey.withCString { key in
				json.withCString { api.save_autofill_address?(key, id, $0) }
			}
		})
	}

	internal func save(
		profileKey: String,
		card: ChromiumAutofillCardDetails,
		numberField: NSTextField?
	) async throws(ChromiumAutofillDataFailure) -> ChromiumAutofillListing {
		guard let json = Self.json(card) else { throw .invalid }

		let field = numberField.map { Unmanaged.passUnretained($0).toOpaque() }
		return try Self.listing(await request { [api] id in
			profileKey.withCString { key in
				json.withCString { api.save_autofill_card?(key, id, $0, field) }
			}
		})
	}

	internal func remove(
		profileKey: String,
		id: String
	) async throws(ChromiumAutofillDataFailure) -> ChromiumAutofillListing {
		guard !id.isEmpty, id.utf8.count <= 64 else { throw .invalid }

		return try Self.listing(await request { [api] request in
			profileKey.withCString { key in
				id.withCString { api.remove_autofill_data?(key, request, $0) }
			}
		})
	}

	internal func complete(
		_ id: UInt64,
		status: ArxAutofillDataStatus,
		json: UnsafePointer<UInt8>?,
		count: Int
	) {
		guard let continuation = requests.removeValue(forKey: id) else { return }

		if status == ARX_AUTOFILL_DATA_CANCELLED {
			return continuation.resume(throwing: CancellationError())
		}
		let body = json.flatMap { count > 0 && count <= 4 * 1_024 * 1_024 ? Data(bytes: $0, count: count) : nil } ?? Data()
		continuation.resume(returning: (status, body))
	}

	internal func stop() {
		for id in Array(requests.keys) {
			requests.removeValue(forKey: id)?.resume(throwing: ChromiumAutofillDataFailure.unavailable)
		}
	}

	private func request(
		start: @escaping (UInt64) -> Void
	) async throws(ChromiumAutofillDataFailure) -> Data {
		guard isAvailable, requests.count < 8, nextRequest < UInt64.max
		else { throw .unavailable }

		let id = nextRequest
		nextRequest += 1
		let result: (ArxAutofillDataStatus, Data)
		do {
			result = try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation { continuation in
					guard !Task.isCancelled else {
						continuation.resume(throwing: CancellationError())
						return
					}

					requests[id] = continuation
					start(id)
				}
			} onCancel: {
				Task { @MainActor [weak self] in self?.cancel(id) }
			}
		} catch {
			// Cancelled: the caller's task is cancelled, so this is never shown.
			throw .unavailable
		}
		switch result.0 {
		case ARX_AUTOFILL_DATA_OK: return result.1
		case ARX_AUTOFILL_DATA_INVALID: throw .invalid
		case ARX_AUTOFILL_DATA_NOT_FOUND: throw .notFound
		case ARX_AUTOFILL_DATA_BUSY: throw .busy
		case ARX_AUTOFILL_DATA_DISABLED: throw .disabled
		default: throw .unavailable
		}
	}

	private func cancel(_ id: UInt64) {
		guard requests[id] != nil else { return }

		api.cancel_autofill_data?(id)
		requests.removeValue(forKey: id)?.resume(throwing: CancellationError())
	}

	internal static func listing(_ data: Data) throws(ChromiumAutofillDataFailure) -> ChromiumAutofillListing {
		guard let listing = ChromiumReply.decode(ChromiumAutofillListing.self, from: data)
		else { throw .unavailable }

		return listing
	}

	private static func json(_ value: some Encodable) -> String? {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		guard
			let data = ChromiumReply.encode(value, with: encoder),
			data.count <= 16 * 1_024
		else { return nil }

		return String(data: data, encoding: .utf8)
	}
}
