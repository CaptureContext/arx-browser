import AVFoundation
import FairPlayProtocol
import Foundation
import OSLog

/// One FairPlay track (DEV-1144): an asset that reads the page's playlist through its own URL
/// scheme, and a content key session that turns each key request into an SPC for the page and
/// takes the page's CKC back. The media itself comes straight from the playlist's https URLs.
@MainActor
internal final class FairPlayTrack: NSObject {
	nonisolated internal static let playlistScheme: String = "arx-fairplay"

	/// How long the page has to answer a key request.
	internal static let licenseTimeout: Duration = .seconds(30)

	internal let generation: Int
	internal let item: AVPlayerItem
	internal var pendingSeek: (time: Double, sequence: Int)?
	internal var hasAnnouncedReady: Bool = false
	private let certificate: Data
	private let asset: AVURLAsset
	private let loader: PlaylistLoader
	private let session: AVContentKeySession = AVContentKeySession(keySystem: .fairPlayStreaming)
	private var awaitingLicense: AVContentKeyRequest?
	private var licenseDeadline: Task<Void, Never>?
	private var isExchanging: Bool = false
	private var isCancelled: Bool = false
	private var hasFailed: Bool = false
	private let send: (FairPlayHelperEvent) -> Void

	internal init(
		generation: Int,
		certificate: Data,
		playlist: String,
		send: @escaping (FairPlayHelperEvent) -> Void
	) {
		self.generation = generation
		self.certificate = certificate
		self.send = send
		self.loader = PlaylistLoader(playlist: Data(playlist.utf8))

		// The scheme is the asset's own: AVFoundation asks the loader for it, never the network.
		self.asset = AVURLAsset(url: URL(string: "\(Self.playlistScheme)://track/\(generation).m3u8")!)
		self.item = AVPlayerItem(asset: asset)
		super.init()
		asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "dev.capturecontext.arx.fairplay.playlist"))
		session.setDelegate(self, queue: .main)
		session.addContentKeyRecipient(asset)
	}

	/// The page's licence for the key request it was given.
	internal func license(_ ckc: Data) {
		guard
			let request = awaitingLicense,
			!isCancelled
		else { return }

		awaitingLicense = nil
		isExchanging = false
		licenseDeadline?.cancel()
		log.notice("Helper: track \(self.generation) got its licence (\(ckc.count) bytes)")
		request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
	}

	/// Reports `step` once and stops the track.
	internal func fail(_ step: FairPlayStep) {
		guard !isCancelled, !hasFailed else { return }
		hasFailed = true
		send(.failed(generation: generation, step: step))
		cancel()
	}

	internal func cancel() {
		isCancelled = true
		licenseDeadline?.cancel()
		awaitingLicense = nil
		session.expire()
	}

	private func requestLicense(_ request: AVContentKeyRequest) {
		guard !isExchanging, !isCancelled else { return }
		isExchanging = true

		// The key's content ID is the skd:// URI's host, as FairPlay HLS names it.
		let identifier = (request.identifier as? String) ?? ""
		let contentIdentifier = Data(identifier.replacingOccurrences(of: "skd://", with: "").utf8)
		let pending = PendingRequest(request)
		let track = WeakReference(self)
		request.makeStreamingContentKeyRequestData(
			forApp: certificate,
			contentIdentifier: contentIdentifier,
			options: nil
		) { spc, error in
			if let error {
				let error = error as NSError
				log.error("Helper: no key request data for the key: \(error.domain, privacy: .public) \(error.code)")
			}
			Task { @MainActor in
				track.object?.requested(pending.request, spc: spc)
			}
		}
	}

	private func requested(
		_ request: AVContentKeyRequest,
		spc: Data?
	) {
		guard !isCancelled else { return }
		guard let spc else {
			isExchanging = false
			fail(.license)
			return
		}

		awaitingLicense = request
		licenseDeadline?.cancel()
		licenseDeadline = Task { [weak self] in
			try? await Task.sleep(for: Self.licenseTimeout)
			guard !Task.isCancelled, let self, self.awaitingLicense != nil else { return }
			log.error("Helper: track \(self.generation) got no licence in time")
			self.fail(.license)
		}
		log.notice("Helper: track \(self.generation) asks for its licence")
		send(.request(generation: generation, spc: spc))
	}
}

extension FairPlayTrack: AVContentKeySessionDelegate {
	nonisolated func contentKeySession(
		_ session: AVContentKeySession,
		didProvide keyRequest: AVContentKeyRequest
	) {
		let pending = PendingRequest(keyRequest)
		MainActor.assumeIsolated { requestLicense(pending.request) }
	}

	nonisolated func contentKeySession(
		_ session: AVContentKeySession,
		didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest
	) {
		let pending = PendingRequest(keyRequest)
		MainActor.assumeIsolated { requestLicense(pending.request) }
	}

	nonisolated func contentKeySession(
		_ session: AVContentKeySession,
		contentKeyRequest keyRequest: AVContentKeyRequest,
		didFailWithError error: any Error
	) {
		let error = error as NSError
		log.error("Helper: the key failed: \(error.domain, privacy: .public) \(error.code)")
		MainActor.assumeIsolated { fail(.license) }
	}
}

/// A key request carried to the main actor. The session calls back on the main queue, and the
/// request is only touched there.
private struct PendingRequest: @unchecked Sendable {
	let request: AVContentKeyRequest

	init(_ request: AVContentKeyRequest) {
		self.request = request
	}
}

/// Serves the page's playlist for the track's own URL scheme, and nothing else.
private final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
	private let playlist: Data

	init(playlist: Data) {
		self.playlist = playlist
	}

	func resourceLoader(
		_ resourceLoader: AVAssetResourceLoader,
		shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
	) -> Bool {
		guard loadingRequest.request.url?.scheme == FairPlayTrack.playlistScheme
		else { return false }

		loadingRequest.contentInformationRequest?.contentType = "public.m3u-playlist"
		loadingRequest.contentInformationRequest?.contentLength = Int64(playlist.count)
		loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
		loadingRequest.dataRequest?.respond(with: playlist)
		loadingRequest.finishLoading()
		return true
	}
}

private let log: Logger = FairPlayLog.logger
