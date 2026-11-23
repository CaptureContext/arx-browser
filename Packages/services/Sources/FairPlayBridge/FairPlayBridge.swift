import BrowserCore
import FairPlayProtocol
import Foundation
import OSLog

/// FairPlay in Chromium tabs, the app's side (DEV-1144). The bridge script in a Spotify page
/// answers the page's EME calls and takes over its media element; this pairs that page with
/// Arx's FairPlay helper. One tab's document owns the player at a time: another tab that loads a
/// track takes it, and the first is told to pause. A track that fails (no key, no playback, no
/// helper) is reported once, so the app can move the tab to WebKit.
@MainActor
public final class FairPlayBridge {
	/// The page's message, from the engine's page media bridge.
	public struct Message: Equatable, Sendable {
		public var tabID: Tab.ID
		public var document: UInt64
		public var text: String

		/// A private window's page: Now Playing never names its track.
		public var isPrivate: Bool

		public init(
			tabID: Tab.ID,
			document: UInt64,
			text: String,
			isPrivate: Bool = false
		) {
			self.tabID = tabID
			self.document = document
			self.text = text
			self.isPrivate = isPrivate
		}
	}

	/// The track a tab's page holds, as the app's speaker and Media page show it (DEV-1147).
	public struct Track: Equatable, Sendable {
		public var tabID: Tab.ID

		/// Changes with each track the helper loads.
		public var number: Int

		/// The page's media session; a private window's is `FairPlayMetadata.privateTrack`.
		public var metadata: FairPlayMetadata

		/// Playing, or asked to play while it loads or buffers.
		public var isPlaying: Bool

		public init(
			tabID: Tab.ID,
			number: Int,
			metadata: FairPlayMetadata = .init(),
			isPlaying: Bool = false
		) {
			self.tabID = tabID
			self.number = number
			self.metadata = metadata
			self.isPlaying = isPlaying
		}
	}

	/// Sends an event to a document; false when that document is gone.
	public typealias SendToPage = @MainActor (_ tabID: Tab.ID, _ document: UInt64, _ text: String) -> Bool

	/// Hears a tab whose track failed, once per track.
	public var onFailure: (@MainActor (Tab.ID, FairPlayStep) -> Void)?

	/// Hears whether the helper is playing for a tab.
	public var onPlayingChange: (@MainActor (Tab.ID, Bool) -> Void)?

	/// Hears when a tab's document starts or stops holding the helper's track, playing or paused.
	/// While it does, its page must keep running though Chromium hears nothing: its script
	/// answers licence renewals, moves to the next track and takes Now Playing's commands
	/// (DEV-1151).
	public var onHolderChange: (@MainActor (_ tabID: Tab.ID, _ document: UInt64, _ holds: Bool) -> Void)?

	/// Hears the held track change: another track or tab, its metadata, playing or paused, or none.
	public var onTrackChange: (@MainActor (Track?) -> Void)?

	private struct Page: Equatable {
		var tabID: Tab.ID
		var document: UInt64
	}

	private struct Owner {
		var page: Page

		/// The page's generation for the track.
		var generation: Int

		/// The helper's generation for the same track.
		var helperGeneration: Int
	}

	private struct Assembly {
		var page: Page
		var generation: Int
		var parts: Int
		var playlist: [String]
		var certificate: Data
		var volume: Double
		var isMuted: Bool
	}

	private let helper: FairPlayHelperConnection
	private let sendToPage: SendToPage
	private var owner: Owner? {
		didSet {
			guard oldValue?.page != owner?.page else { return }
			wantsToPlay = false
			if let page = oldValue?.page { onHolderChange?(page.tabID, page.document, false) }
			if let page = owner?.page { onHolderChange?(page.tabID, page.document, true) }
		}
	}
	private var assembly: Assembly?
	private var helperGenerations: Int = 0
	private var failedGeneration: Int?
	private var isPageMuted: Bool = false

	/// The owner's media element volume, `0 ... 1`.
	private var pageVolume: Double = 1
	private var mutedTabs: Set<Tab.ID> = []

	/// Each tab's volume from Arx's tab volume control (DEV-800), `0 ... 1`; absent is 1.
	private var tabVolumes: [Tab.ID: Double] = [:]
	private var isPlaying: Bool = false

	/// The page asked the owner's track to play and hasn't paused it: loading or buffering, the
	/// helper reports it stopped though the person hears it start soon.
	private var wantsToPlay: Bool = false

	/// The owner's media session metadata, as Now Playing has it.
	private var metadata: FairPlayMetadata = .init()
	private var publishedTrack: Track?

	public init(
		helper: FairPlayHelperConnection,
		sendToPage: @escaping SendToPage
	) {
		self.helper = helper
		self.sendToPage = sendToPage
	}

	/// The track a tab's page holds now, playing or paused.
	public var track: Track? {
		owner.map { owner in
			Track(
				tabID: owner.page.tabID,
				number: owner.helperGeneration,
				metadata: metadata,
				isPlaying: isPlaying || wantsToPlay
			)
		}
	}

	/// The tab the helper plays for, if it plays.
	public var playingTab: Tab.ID? {
		isPlaying ? owner?.page.tabID : nil
	}

	// MARK: - Page

	public func receive(_ message: Message) {
		guard let decoded = FairPlayPageMessage(decoding: message.text)
		else { return }
		if case let .trace(step) = decoded {
			log.info("Tab \(message.tabID.logName, privacy: .public): page \(step.rawValue, privacy: .public)")
			return
		}
		defer { publishTrack() }

		let page = Page(tabID: message.tabID, document: message.document)
		if case let .load(generation, part, parts, playlist, certificate, volume, isMuted) = decoded {
			receivePart(
				of: page,
				generation: generation,
				part: part,
				parts: parts,
				playlist: playlist,
				certificate: certificate,
				volume: volume,
				isMuted: isMuted
			)
			return
		}

		// The page gave up on a track the app never took, such as one it refused: fall back anyway.
		if case .failed = decoded, owner?.page != page {
			log.notice("Tab \(page.tabID.logName, privacy: .public): the page gave up on a track the helper doesn't hold; falling back")
			onFailure?(page.tabID, .playback)
			return
		}
		guard let owner, owner.page == page
		else { return }

		switch decoded {
		case .load:
			break
		case let .license(generation, ckc):
			guard generation == owner.generation else {
				log.info("Tab \(page.tabID.logName, privacy: .public): a licence for an older track, dropped")
				break
			}
			log.notice("Tab \(page.tabID.logName, privacy: .public): the page's licence (\(ckc.count) bytes) goes to the helper")
			helper.send(.license(generation: owner.helperGeneration, ckc: ckc))
		case .play:
			log.info("Tab \(page.tabID.logName, privacy: .public): the page plays")
			wantsToPlay = true
			helper.send(.play)
		case .pause:
			log.info("Tab \(page.tabID.logName, privacy: .public): the page pauses")
			wantsToPlay = false
			helper.send(.pause)
		case let .seek(time, sequence):
			helper.send(.seek(time: time, sequence: sequence))
		case let .volume(volume):
			pageVolume = volume
			helper.send(.volume(volume * tabVolume(page.tabID)))
		case let .muted(isMuted):
			isPageMuted = isMuted
			helper.send(.muted(isMuted || mutedTabs.contains(page.tabID)))
		case let .metadata(metadata):
			self.metadata = message.isPrivate ? .privateTrack : metadata
			helper.send(.metadata(self.metadata))
		case .stop:
			log.info("Tab \(page.tabID.logName, privacy: .public): the page let go of its track")
			release()
		case .failed:
			log.notice("Tab \(page.tabID.logName, privacy: .public): the page gave up on its track")
			fail(owner, step: .playback, tellsPage: false)
		case .trace:
			break
		}
	}

	private func receivePart(
		of page: Page,
		generation: Int,
		part: Int,
		parts: Int,
		playlist: String,
		certificate: Data?,
		volume: Double,
		isMuted: Bool
	) {
		if part == 0, let certificate {
			assembly = Assembly(
				page: page,
				generation: generation,
				parts: parts,
				playlist: [],
				certificate: certificate,
				volume: volume,
				isMuted: isMuted
			)
		}
		guard
			var assembly,
			assembly.page == page,
			assembly.generation == generation,
			assembly.parts == parts,
			assembly.playlist.count == part
		else { return }

		assembly.playlist.append(playlist)
		guard assembly.playlist.count == parts else {
			self.assembly = assembly
			return
		}

		self.assembly = nil
		load(assembly)
	}

	private func load(_ assembly: Assembly) {
		let playlist = assembly.playlist.joined()
		let page = assembly.page
		guard FairPlayPlaylist.isAcceptable(playlist), FairPlayPlaylist.hasFairPlayKey(playlist) else {
			log.notice("Tab \(page.tabID.logName, privacy: .public): refused the page's playlist (acceptable: \(FairPlayPlaylist.isAcceptable(playlist)), FairPlay key: \(FairPlayPlaylist.hasFairPlayKey(playlist))); falling back")
			if owner?.page == page { release() }
			_ = sendToPage(page.tabID, page.document, FairPlayPageEvent.failed(generation: assembly.generation, step: .playback).text)
			onFailure?(page.tabID, .playback)
			return
		}

		if let previous = owner, previous.page != page {
			setPlaying(false)
			_ = sendToPage(previous.page.tabID, previous.page.document, FairPlayPageEvent.stolen(generation: previous.generation).text)
		}
		helperGenerations += 1
		let owner = Owner(page: page, generation: assembly.generation, helperGeneration: helperGenerations)
		self.owner = owner
		failedGeneration = nil

		// A new track starts paused until the page asks it to play, and unnamed until its page says.
		wantsToPlay = false
		metadata = .init()
		isPageMuted = assembly.isMuted
		pageVolume = assembly.volume
		guard
			helper.start(
				{ [weak self] event in self?.receive(event) },
				{ [weak self] in self?.helperExited() }
			)
		else {
			log.error("Tab \(page.tabID.logName, privacy: .public): the helper app didn't start")
			fail(owner, step: .player, tellsPage: true)
			return
		}

		log.notice("Tab \(page.tabID.logName, privacy: .public): track \(owner.helperGeneration) goes to the helper (\(assembly.parts) playlist parts, certificate \(assembly.certificate.count) bytes)")
		helper.send(.load(
			generation: owner.helperGeneration,
			certificate: assembly.certificate,
			playlist: playlist,
			volume: assembly.volume * tabVolume(page.tabID),
			isMuted: assembly.isMuted || mutedTabs.contains(page.tabID)
		))
		setPlaying(false)
	}

	// MARK: - Helper

	private func receive(_ event: FairPlayHelperEvent) {
		guard let owner else { return }
		defer { publishTrack() }

		let pageEvent: FairPlayPageEvent
		switch event {
		case let .remote(command, time):
			pageEvent = .remote(command, time: time)
		case let .request(generation, spc):
			guard generation == owner.helperGeneration else { return }
			log.notice("Tab \(owner.page.tabID.logName, privacy: .public): the helper's key request (\(spc.count) bytes) goes to the page")
			pageEvent = .request(generation: owner.generation, spc: spc)
		case let .ready(generation, duration):
			guard generation == owner.helperGeneration else { return }
			log.notice("Tab \(owner.page.tabID.logName, privacy: .public): track \(generation) is ready")
			pageEvent = .ready(generation: owner.generation, duration: duration)
		case let .position(generation, time, isPlaying, sequence):
			guard generation == owner.helperGeneration else { return }
			setPlaying(isPlaying)
			pageEvent = .position(generation: owner.generation, time: time, isPlaying: isPlaying, sequence: sequence)
		case let .ended(generation):
			guard generation == owner.helperGeneration else { return }
			wantsToPlay = false
			setPlaying(false)
			pageEvent = .ended(generation: owner.generation)
		case let .failed(generation, step):
			guard generation == owner.helperGeneration else { return }
			log.error("Tab \(owner.page.tabID.logName, privacy: .public): the helper failed track \(generation) at its \(step.rawValue, privacy: .public)")
			fail(owner, step: step, tellsPage: true)
			return
		}
		deliver(pageEvent, to: owner)
	}

	private func helperExited() {
		guard let owner else { return }
		log.error("Tab \(owner.page.tabID.logName, privacy: .public): the helper app exited while it held the track")
		fail(owner, step: .player, tellsPage: true)
		publishTrack()
	}

	// MARK: - Tabs

	/// The tab's mute: a muted tab's track plays silently.
	public func setMuted(
		_ isMuted: Bool,
		tab: Tab.ID
	) {
		if isMuted { mutedTabs.insert(tab) } else { mutedTabs.remove(tab) }
		guard owner?.page.tabID == tab else { return }
		helper.send(.muted(isPageMuted || isMuted))
	}

	/// The tab's volume from Arx's tab volume control, `0 ... 1`, applied over the page's own.
	public func setVolume(
		_ volume: Double,
		tab: Tab.ID
	) {
		let volume = volume.isFinite ? min(max(volume, 0), 1) : 1
		tabVolumes[tab] = volume
		guard owner?.page.tabID == tab else { return }
		helper.send(.volume(pageVolume * volume))
	}

	/// Whether the helper plays for `tab` now, or will once its track has loaded or buffered: such a
	/// tab is audible though Chromium plays nothing. A paused track's tab isn't.
	public func isPlaying(_ tab: Tab.ID) -> Bool {
		owner?.page.tabID == tab && (isPlaying || wantsToPlay)
	}

	private func tabVolume(_ tab: Tab.ID) -> Double {
		tabVolumes[tab] ?? 1
	}

	/// The tab closed, or its page moved to another engine: its track stops.
	public func pageGone(_ tab: Tab.ID) {
		mutedTabs.remove(tab)
		tabVolumes[tab] = nil
		if assembly?.page.tabID == tab { assembly = nil }
		guard owner?.page.tabID == tab else { return }
		release()
		publishTrack()
	}

	/// Stops the helper altogether, as when the feature flag goes off.
	public func stop() {
		assembly = nil
		release()
		helper.stop()
		publishTrack()
	}

	/// The app's own control for a tab's track, from its speaker or the Media page: the page's own
	/// player takes it, as it takes Now Playing's (DEV-1147). False when the tab holds no track.
	/// Play, pause, and the next and previous track; other actions aren't the page player's.
	@discardableResult
	public func control(
		_ action: BrowserMediaSource.Action,
		tab: Tab.ID
	) -> Bool {
		let command: FairPlayRemoteCommand
		switch action {
		case .play: command = .play
		case .pause: command = .pause
		case .nextTrack: command = .nextTrack
		case .previousTrack: command = .previousTrack
		default: return false
		}
		guard let owner, owner.page.tabID == tab
		else { return false }

		deliver(.remote(command, time: nil), to: owner)
		publishTrack()
		return owner.page == self.owner?.page
	}

	// MARK: - State

	private func deliver(
		_ event: FairPlayPageEvent,
		to owner: Owner
	) {
		// The document is gone, such as a page that navigated without a pagehide: its track stops.
		guard sendToPage(owner.page.tabID, owner.page.document, event.text) else {
			release()
			return
		}
	}

	private func fail(
		_ owner: Owner,
		step: FairPlayStep,
		tellsPage: Bool
	) {
		guard failedGeneration != owner.helperGeneration else { return }
		failedGeneration = owner.helperGeneration
		helper.send(.stop)
		setPlaying(false)

		// A document that's gone has nothing to fall back: the tab may show another by now.
		let reachesPage = !tellsPage
			|| sendToPage(owner.page.tabID, owner.page.document, FairPlayPageEvent.failed(generation: owner.generation, step: step).text)
		self.owner = nil
		guard reachesPage else {
			log.notice("Tab \(owner.page.tabID.logName, privacy: .public): its track failed at \(step.rawValue, privacy: .public), but its page is gone; no fallback")
			return
		}
		log.notice("Tab \(owner.page.tabID.logName, privacy: .public): its track failed at \(step.rawValue, privacy: .public); falling back")
		onFailure?(owner.page.tabID, step)
	}

	private func release() {
		guard owner != nil else { return }
		helper.send(.stop)
		setPlaying(false)
		owner = nil
	}

	private func publishTrack() {
		let track = track
		guard track != publishedTrack else { return }
		publishedTrack = track
		onTrackChange?(track)
	}

	private func setPlaying(_ playing: Bool) {
		guard playing != isPlaying else { return }
		isPlaying = playing
		if let tab = owner?.page.tabID { onPlayingChange?(tab, playing) }
	}
}

extension FairPlayBridge {
	/// The FairPlay diagnostics log (`FairPlayLog`), for the app's own steps.
	public static var diagnosticsLog: Logger {
		FairPlayLog.logger
	}
}

private let log: Logger = FairPlayLog.logger

extension BrowserID {
	/// A tab's ID as the FairPlay log names it: its first characters, enough to tell tabs apart.
	fileprivate var logName: String {
		String(rawValue.uuidString.prefix(8))
	}
}
