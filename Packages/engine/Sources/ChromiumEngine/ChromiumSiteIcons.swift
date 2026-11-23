import ChromiumBridge
import Foundation
import ImageIO

public struct ChromiumSiteIcon: Equatable, Sendable {
	public let png: Data
	public let width: Int
	public let height: Int

	/// ABI51 (DEV-940). The favicon this bitmap belongs to. Every page mapped to it
	/// shares the bitmap, so a change to it changes them all. Nil when unknown.
	public let iconURL: URL?

	internal init(
		png: Data,
		width: Int,
		height: Int,
		iconURL: URL? = nil
	) throws {
		guard
			!png.isEmpty,
			png.count <= 65_536,
			(1...32).contains(width),
			(1...32).contains(height)
		else { throw ChromiumSiteIconFailure.limitExceeded }

		guard
			let source = CGImageSourceCreateWithData(png as CFData, nil),
			CGImageSourceGetType(source) as String? == "public.png",
			CGImageSourceGetCount(source) == 1,
			let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			properties[kCGImagePropertyPixelWidth] as? Int == width,
			properties[kCGImagePropertyPixelHeight] as? Int == height
		else { throw ChromiumSiteIconFailure.invalidResponse }

		self.png = png
		self.width = width
		self.height = height
		self.iconURL = iconURL
	}

	/// A favicon address from native, or nil when empty, malformed or too long.
	internal static func iconURL(_ spec: String) -> URL? {
		guard !spec.isEmpty, spec.utf8.count <= 8192
		else { return nil }
		return URL(string: spec)
	}
}

public enum ChromiumSiteIconFailure: Error, Equatable, Sendable {
	case unavailable
	case invalidRequest
	case invalidResponse
	case limitExceeded
	case timeout
	case busy

	/// The page had an icon Chromium fetched before DEV-1108, which may be another host's
	/// (the sign-in page its site redirected to). Chromium dropped it and found none of the
	/// page's own, so any copy kept elsewhere is stale too.
	case discarded
}

@MainActor
internal final class ChromiumSiteIcons {
	private let api: ArxEngineAPI
	private var generations: [UUID?: UInt64] = [:]
	private var nextGeneration: UInt64 = 1
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: Request] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	/// ABI50 (DEV-796): whether a database miss may fetch the site's icon. An engine
	/// without the entry always fetches, as before.
	internal func setFetch(_ enabled: Bool) {
		api.set_site_icon_fetch?(enabled)
	}

	internal func configure(profiles: Set<UUID?>) {
		let removed = Set(generations.keys).subtracting(profiles)
		for profile in removed {
			generations.removeValue(forKey: profile)
		}
		for id in requests.keys.filter({ removed.contains(requests[$0]!.scope.profileID) }) {
			cancel(id, failure: ChromiumSiteIconFailure.unavailable)
		}

		for profile in profiles where generations[profile] == nil {
			guard nextGeneration < UInt64.max else { return }
			generations[profile] = nextGeneration
			nextGeneration += 1
		}
	}

	internal func scope(profileID: UUID?) throws -> Scope {
		guard let scope = currentScope(profileID: profileID)
		else { throw ChromiumSiteIconFailure.unavailable }
		return scope
	}

	internal func currentScope(profileID: UUID?) -> Scope? {
		guard let generation = generations[profileID] else { return nil }
		return .init(profileID: profileID, generation: generation)
	}

	internal func isCurrent(_ scope: Scope) -> Bool {
		generations[scope.profileID] == scope.generation
	}

	internal func lookup(
		pageURL: URL,
		scope: Scope,
		mayFetch: Bool = true
	) async throws -> ChromiumSiteIcon? {
		try Task.checkCancellation()
		guard isCurrent(scope), let lookup = mayFetch ? api.lookup_site_icon : api.lookup_cached_site_icon
		else { throw ChromiumSiteIconFailure.unavailable }
		guard
			["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""),
			pageURL.host != nil,
			pageURL.absoluteString.utf8.count <= 8192
		else { throw ChromiumSiteIconFailure.invalidRequest }
		guard requests.count < 16, nextRequest < UInt64.max
		else { throw ChromiumSiteIconFailure.busy }

		let id = nextRequest
		nextRequest += 1
		let result: ChromiumSiteIcon? = try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				requests[id] = .init(scope: scope, continuation: continuation)
				lookup(scope.profileID?.uuidString.lowercased() ?? "", pageURL.absoluteString, id)
			}
		} onCancel: {
			Task { @MainActor [weak self] in
				self?.cancel(id, failure: CancellationError())
			}
		}

		// Cancellation/disposal may follow native completion before this task resumes.
		try Task.checkCancellation()
		guard isCurrent(scope)
		else { throw ChromiumSiteIconFailure.unavailable }
		return result
	}

	internal func complete(
		_ id: UInt64,
		status: ArxSiteIconStatus,
		bytes: UnsafePointer<UInt8>?,
		count: Int,
		width: UInt32,
		height: UInt32,
		iconURL: String? = nil
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		do {
			guard isCurrent(request.scope)
			else { throw ChromiumSiteIconFailure.unavailable }
			if status == ARX_SITE_ICON_MISSING {
				// With an icon URL, the lookup dropped that stale icon (DEV-1108).
				if iconURL.flatMap(ChromiumSiteIcon.iconURL) != nil {
					throw ChromiumSiteIconFailure.discarded
				}
				request.continuation.resume(returning: nil)
				return
			}
			guard status == ARX_SITE_ICON_SUCCESS
			else { throw ChromiumSiteIconFailure(status: status) }
			guard count > 0, count <= 65_536
			else { throw ChromiumSiteIconFailure.limitExceeded }
			guard let bytes
			else { throw ChromiumSiteIconFailure.invalidResponse }

			let icon = try ChromiumSiteIcon(
				png: Data(bytes: bytes, count: count),
				width: Int(width),
				height: Int(height),
				iconURL: iconURL.flatMap(ChromiumSiteIcon.iconURL)
			)
			request.continuation.resume(returning: icon)
		} catch {
			request.continuation.resume(throwing: error)
		}
	}

	internal func stop() {
		configure(profiles: [])
	}

	private func cancel(
		_ id: UInt64,
		failure: any Error
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }
		api.cancel_site_icon?(id)
		request.continuation.resume(throwing: failure)
	}

	internal struct Scope: Hashable, Sendable {
		internal let profileID: UUID?
		internal let generation: UInt64

		internal init(
			profileID: UUID?,
			generation: UInt64
		) {
			self.profileID = profileID
			self.generation = generation
		}
	}

	private struct Request {
		internal let scope: Scope
		internal let continuation: CheckedContinuation<ChromiumSiteIcon?, any Error>

		internal init(
			scope: Scope,
			continuation: CheckedContinuation<ChromiumSiteIcon?, any Error>
		) {
			self.scope = scope
			self.continuation = continuation
		}
	}
}

extension ChromiumSiteIconFailure {
	internal init(status: ArxSiteIconStatus) {
		self = switch status {
		case ARX_SITE_ICON_UNAVAILABLE: .unavailable
		case ARX_SITE_ICON_INVALID: .invalidRequest
		case ARX_SITE_ICON_LIMIT: .limitExceeded
		case ARX_SITE_ICON_TIMEOUT: .timeout
		case ARX_SITE_ICON_BUSY: .busy
		default: .invalidResponse
		}
	}
}

public struct ChromiumSiteIconChange: Equatable, Sendable {
	internal let scope: ChromiumSiteIcons.Scope

	/// The page whose icon changed or whose load ended. Nil for a profile-wide change.
	public let pageID: UInt64?

	/// The pages whose icons may have changed: the address Chromium reported or the page
	/// showed, and the addresses its current load went through (redirects, same-document
	/// changes), which Chromium's favicon database updates alongside it (DEV-940).
	/// Empty when any icon in the profile may have changed, as after its history is cleared.
	public let pageURLs: [URL]

	/// ABI51 (DEV-940). The favicon Chromium reported for the page. Its bitmap is shared
	/// by every page mapped to it, so those pages' icons may have changed too. Nil when
	/// unknown, as for lifecycle changes.
	public let iconURL: URL?

	internal init(
		pageID: UInt64?,
		pageURLs: [URL],
		iconURL: URL?,
		scope: ChromiumSiteIcons.Scope
	) {
		self.scope = scope
		self.pageID = pageID
		self.pageURLs = pageURLs
		self.iconURL = iconURL
	}

	public var profileID: UUID? { scope.profileID }

	/// Whether every icon in the profile may have changed.
	public var isProfileWide: Bool { pageURLs.isEmpty }
}

extension AsyncStream<ChromiumSiteIconChange>.Continuation {
	/// Yields a change. When the full buffer drops an older one, a profile-wide change
	/// for its profile takes its place, so no page loses its refresh (DEV-940).
	internal func yieldKeepingRefreshes(_ change: ChromiumSiteIconChange) {
		var pending = [change]
		var recovered: Set<ChromiumSiteIcons.Scope> = []
		while let next = pending.popLast() {
			guard
				case let .dropped(lost) = yield(next),
				recovered.insert(lost.scope).inserted
			else { continue }
			pending.append(.init(pageID: nil, pageURLs: [], iconURL: nil, scope: lost.scope))
		}
	}
}
