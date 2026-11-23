import AppKit
import ChromiumEngine

/// The back/forward cache (DEV-943). A → B → Back must restore A without a new document:
/// A's own `pageshow` reports `persisted`, the server served it once, and its script
/// token survives. The title, site icon, back/forward list and agent snapshot identities
/// must be A's again, while the old snapshot and the old document revision stay stale.
/// Forward restores B the same way. A page whose video played and paused comes back with
/// that paused player observable and controllable under a new media generation, and with
/// the track, artist, artwork and previous and next track buttons its Media Session named,
/// after Back and after Forward; a change the page makes after a restore wins (DEV-960).
/// The host validates fresh owned storage first. A failure names its phase and, for a time
/// out, the wait and the last state it saw; the runner adds the fixture's requests.
@MainActor
internal final class BackForwardCacheSmoke {
	internal static let argument: String = "--back-forward-cache-fixture"
	private static let titleA: String = "Arx cache A"
	private static let titleB: String = "Arx cache B"
	private static let titleMedia: String = "Arx cache media"
	private static let track: String = "Arx cache track"
	private static let artist: String = "Arx cache artist"

	/// The page renames its track and drops next track on its third restore.
	private static let changedTrack: String = "Arx cache track changed"
	private static let buttonName: String = "Arx cache button"
	private static let statePrefix: String = "ARX_BACK_FORWARD_CACHE_STATE"

	private enum Failure: Error, CustomStringConvertible {
		/// `wait` names what never became true; `state` is the last thing it saw.
		case timedOut(wait: String, state: String)
		case acceptedStale
		case click
		case unexpected(String)

		internal var description: String {
			switch self {
			case let .timedOut(wait, state): "timed-out wait=\(wait) last=\(state)"
			case .acceptedStale: "accepted-stale"
			case .click: "click"
			case let .unexpected(detail): "unexpected \(detail)"
			}
		}
	}

	/// What the fixture page reports about itself in its state line.
	private struct PageState: Equatable {
		internal var persisted: Bool
		internal var served: Int
		internal var token: String

		internal init(
			persisted: Bool,
			served: Int,
			token: String
		) {
			self.persisted = persisted
			self.served = served
			self.token = token
		}
	}

	private let runtime: ChromiumRuntime
	private let baseURL: URL
	private var pages: [ChromiumPage] = []
	private var windows: [UInt64: NSWindow] = [:]
	private var scopes: [UUID] = []
	private var iconChanges: [ChromiumSiteIconChange] = []
	private var iconTask: Task<Void, Never>?
	private var mediaSources: [ChromiumMediaSource] = []
	private var mediaTask: Task<Void, Never>?
	private var phase: String = "startup"
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) {
		self.runtime = runtime
		self.baseURL = url
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_FAILED phase=\(phase) reason=\(error)")
			}

			iconTask?.cancel()
			mediaTask?.cancel()
			for scope in scopes {
				runtime.revokeInspectionScope(scope)
			}
			for page in pages {
				page.close()
			}
			for window in windows.values {
				window.orderOut(nil)
				window.close()
			}
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		phase = "first-load"

		// Icons come from the profile's database only, never a fresh fetch.
		runtime.configureSiteIconProfiles([nil])
		runtime.setSiteIconFetch(enabled: false)
		let changes = runtime.siteIconChanges()
		iconTask = Task { [weak self] in
			for await change in changes {
				self?.iconChanges.append(change)
			}
		}

		let page = try await makePage()
		try runtime.observeMedia(page)
		let media = runtime.mediaEvents()
		mediaTask = Task { [weak self] in
			for await sources in media {
				self?.mediaSources = sources
			}
		}
		try page.navigate(to: url("a"))
		try await waitLoaded(page, url: url("a"), title: Self.titleA)
		let scope = UUID()
		scopes.append(scope)
		let (first, firstState) = try await inspect(page, scope: scope, persisted: false)
		guard firstState.served == 1
		else { throw Failure.unexpected("first-served=\(firstState.served)") }

		let firstRevision = try revision(of: page)
		let reference = try reference(in: first)
		try await wait("first-icon-change", state: { "changes=\(self.iconChanges.count)" }) {
			self.iconChanges.contains { $0.pageID == page.identifier && $0.pageURLs.contains(self.url("a")) }
		}

		// The load's end announces a change too, before Chromium has fetched and stored
		// the icon, so the first change may come before the store has it.
		try await waitStoredIcon(of: page, pageURL: url("a"))

		diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_FIRST_LOAD")

		phase = "leave"
		try page.navigate(to: url("b"))
		try await waitLoaded(page, url: url("b"), title: Self.titleB)
		let leftRevision = try revision(of: page)
		guard leftRevision != firstRevision
		else { throw Failure.unexpected("leave-revision") }

		let (_, leftState) = try await inspect(page, scope: scope, persisted: false)
		guard leftState.served == 1
		else { throw Failure.unexpected("b-served=\(leftState.served)") }

		try await requireStale(reference, in: first, on: page, scope: scope)
		diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_LEAVE")

		phase = "back"
		let iconsBeforeBack = iconChanges.count
		try page.goBack()
		try await waitLoaded(page, url: url("a"), title: Self.titleA)
		try await wait("restored-revision", state: { String(describing: self.runtime.documentRevision(for: page)) }) {
			// No revision while the restored document takes over; keep waiting for it.
			(try? self.revision(of: page)).map { $0 != leftRevision } ?? false
		}
		let (restored, restoredState) = try await inspect(page, scope: scope, persisted: true)
		guard restoredState == PageState(persisted: true, served: 1, token: firstState.token)
		else { throw Failure.unexpected("restored-state=\(restoredState)") }

		diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_RESTORED")

		phase = "snapshot"

		// The same document comes back, as a new visit: a new revision and a new
		// snapshot. The snapshot read before leaving stays stale.
		let restoredRevision = try revision(of: page)
		guard
			restoredRevision != firstRevision,
			restoredRevision != leftRevision,
			restored.documentID == first.documentID,
			restored.snapshotID != first.snapshotID
		else { throw Failure.unexpected("snapshot-identity") }

		try await requireStale(reference, in: first, on: page, scope: scope)
		try await runtime.validateInspectionReference(
			try self.reference(in: restored),
			in: restored,
			on: page,
			scope: scope
		)
		diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_SNAPSHOT")

		phase = "title-history"
		let history = page.navigation.history
		guard
			page.navigation.title == Self.titleA,
			!page.navigation.canGoBack,
			page.navigation.canGoForward,
			history.map(\.url) == [url("a"), url("b")],
			history.map(\.title) == [Self.titleA, Self.titleB],
			history.map(\.isCurrent) == [true, false]
		else { throw Failure.unexpected("history=\(history.map { "\($0.title)|\($0.isCurrent)" })") }

		diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_TITLE_HISTORY")

		phase = "icon"

		// Either the favicon driver's restored candidates or the terminal load
		// refresh tells the app to look the page's icon up again.
		try await wait("restored-icon-change", state: { "changes=\(self.iconChanges.count - iconsBeforeBack)" }) {
			self.iconChanges.dropFirst(iconsBeforeBack).contains {
				$0.pageID == page.identifier && ($0.isProfileWide || $0.pageURLs.contains(self.url("a")))
			}
		}
		guard let current = page.navigation.url
		else { throw Failure.unexpected("restored-url-missing") }

		try await waitStoredIcon(of: page, pageURL: current)
		diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_ICON")

		phase = "forward"
		try page.goForward()
		try await waitLoaded(page, url: url("b"), title: Self.titleB)
		let (_, forwardState) = try await inspect(page, scope: scope, persisted: true)
		guard forwardState == PageState(persisted: true, served: 1, token: leftState.token)
		else { throw Failure.unexpected("forward-state=\(forwardState)") }

		diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_FORWARD")

		phase = "media"

		// Played, then paused by the page itself: Chromium restores such a player
		// paused and never reports it starting again. The page reports its playback
		// state, so its short clip's session is controllable, and reports it again when
		// restored, as Chromium resets the browser's copy then (see the fixture).
		try page.navigate(to: url("media"))
		try await waitLoaded(page, url: url("media"), title: Self.titleMedia)
		try click(page)
		try await wait("paused-media-source", state: { self.describeMedia(of: page) }) {
			guard let source = self.mediaSource(of: page) else { return false }

			return source.playback == .paused && source.actions.contains(.play)
		}
		let pausedSource = try require(mediaSource(of: page))
		try await wait("media-session", state: { self.describeMedia(of: page) }) {
			self.showsTrack(Self.track, nextTrack: true, on: page)
		}
		try page.navigate(to: url("b"))
		try await waitLoaded(page, url: url("b"), title: Self.titleB)
		try page.goBack()
		try await waitLoaded(page, url: url("media"), title: Self.titleMedia)
		let (_, mediaState) = try await inspect(page, scope: scope, persisted: true)
		guard mediaState.served == 1
		else { throw Failure.unexpected("media-served=\(mediaState.served)") }

		try await wait("restored-media-source", state: { self.describeMedia(of: page) }) {
			guard let source = self.mediaSource(of: page) else { return false }

			return source.generation != pausedSource.generation
			&& source.hasVideo
			&& source.playback == .paused
			&& source.actions.contains(.play)
		}

		// The page never sends its track or handlers again; the browser kept them.
		try await wait("restored-media-session", state: { self.describeMedia(of: page) }) {
			self.mediaSource(of: page)?.generation != pausedSource.generation
			&& self.showsTrack(Self.track, nextTrack: true, on: page)
		}
		let restoredSource = try require(mediaSource(of: page))
		do {
			try await runtime.performMedia(
				page,
				generation: pausedSource.generation,
				revision: pausedSource.revision,
				action: .play
			)
			throw Failure.acceptedStale
		} catch ChromiumMediaFailure.staleSource {
			// The generation from before leaving no longer commands the page.
		}
		try await runtime.performMedia(
			page,
			generation: restoredSource.generation,
			revision: restoredSource.revision,
			action: .play
		)
		try await wait("restored-media-playing", state: { self.describeMedia(of: page) }) {
			self.mediaSource(of: page)?.playback == .playing
		}
		diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_MEDIA")

		phase = "media-session"

		// Forward brings the page back from the cache a second time, still with its track.
		try page.goBack()
		try await waitLoaded(page, url: url("b"), title: Self.titleB)
		try page.goForward()
		try await restoreMedia(page, scope: scope, after: restoredSource.generation, track: Self.track, nextTrack: true)
		let forwardSource = try require(mediaSource(of: page))

		// On its third restore the page renames its track and drops next track: that wins.
		try page.goForward()
		try await waitLoaded(page, url: url("b"), title: Self.titleB)
		try page.goBack()
		try await restoreMedia(
			page,
			scope: scope,
			after: forwardSource.generation,
			track: Self.changedTrack,
			nextTrack: false
		)
		try await Task.sleep(for: .milliseconds(500))
		guard showsTrack(Self.changedTrack, nextTrack: false, on: page)
		else { throw Failure.unexpected("changed-media-session \(describeMedia(of: page))") }

		diagnostic("ARX_BACK_FORWARD_CACHE_SMOKE_MEDIA_SESSION")
	}

	/// Waits for the media page to come back from the cache, unserved, and for a media source
	/// newer than `generation` that shows `track` with or without next track.
	private func restoreMedia(
		_ page: ChromiumPage,
		scope: UUID,
		after generation: UInt64,
		track: String,
		nextTrack: Bool
	) async throws {
		try await waitLoaded(page, url: url("media"), title: Self.titleMedia)
		let (_, state) = try await inspect(page, scope: scope, persisted: true)
		guard state.served == 1
		else { throw Failure.unexpected("media-served=\(state.served)") }

		try await wait("restored-\(track)", state: { self.describeMedia(of: page) }) {
			self.mediaSource(of: page).map { $0.generation != generation } == true
			&& self.showsTrack(track, nextTrack: nextTrack, on: page)
		}
	}

	/// Whether the page's media source shows the fixture's `track` by its artist, with artwork
	/// and previous track, and with next track only when `nextTrack`.
	private func showsTrack(
		_ track: String,
		nextTrack: Bool,
		on page: ChromiumPage
	) -> Bool {
		guard let source = mediaSource(of: page) else { return false }

		return source.title == track
		&& source.artist == Self.artist
		&& source.artwork != nil
		&& source.actions.contains(.previousTrack)
		&& source.actions.contains(.nextTrack) == nextTrack
	}

	/// Reads the profile's favicon database, never the network, until it holds the
	/// fixture's icon for `pageURL`. A time out names the page, the icon, the last read
	/// and the page's icon changes.
	private func waitStoredIcon(
		of page: ChromiumPage,
		pageURL: URL
	) async throws {
		let wait = StoredSiteIconWait(pageURL: pageURL, iconURL: url("icon.png"))
		try await wait.wait(
			clock: ContinuousClock(),
			read: {
				StoredSiteIconWait.Read(
					try await self.runtime.siteIcon(pageURL: pageURL, profileID: nil, mayFetch: false)
				)
			},
			context: { self.describeIconChanges(of: page) }
		)
	}

	/// How many icon changes named the page, and the favicon Chromium last reported for it.
	private func describeIconChanges(of page: ChromiumPage) -> String {
		let changes = iconChanges.filter { $0.pageID == page.identifier || $0.isProfileWide }
		let reported = changes.last { $0.iconURL != nil }?.iconURL?.absoluteString ?? "none"
		return "changes=\(changes.count),reported=\(reported)"
	}

	private func mediaSource(of page: ChromiumPage) -> ChromiumMediaSource? {
		mediaSources.first { $0.page == page.identifier }
	}

	/// The page's media source as a failure reports it, or `none`.
	private func describeMedia(of page: ChromiumPage) -> String {
		guard let source = mediaSource(of: page) else { return "none" }

		let actions = source.actions.map { "\($0)" }.sorted().joined(separator: ",")
		return "generation=\(source.generation),revision=\(source.revision),playback=\(source.playback),"
		+ "video=\(source.hasVideo),actions=[\(actions)],title=\(source.title),artist=\(source.artist),"
		+ "artwork=\(source.artwork?.count ?? 0)"
	}

	private func require(_ source: ChromiumMediaSource?) throws -> ChromiumMediaSource {
		guard let source
		else { throw Failure.unexpected("media-source-missing") }

		return source
	}

	/// One window-local click at the page's center, where the fixture's start button is.
	private func click(_ page: ChromiumPage) throws {
		let view = page.view
		guard
			let window = view.window,
			window.isVisible,
			!view.isHiddenOrHasHiddenAncestor
		else { throw Failure.click }

		let point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
		let location = view.convert(point, to: nil)
		let timestamp = ProcessInfo.processInfo.systemUptime
		for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: location,
				modifierFlags: [],
				timestamp: timestamp + Double(offset) * 0.001,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: offset + 1,
				clickCount: 1,
				pressure: offset == 0 ? 1 : 0
			)
			else { throw Failure.click }

			window.sendEvent(event)
		}
	}

	/// Reads the page until its state line reports `persisted` as expected.
	private func inspect(
		_ page: ChromiumPage,
		scope: UUID,
		persisted: Bool
	) async throws -> (ChromiumInspectionSnapshot, PageState) {
		let deadline = Date().addingTimeInterval(15)
		while true {
			let snapshot = try await runtime.inspect(page, scope: scope)
			let state = Self.state(in: snapshot)
			if let state, state.persisted == persisted {
				return (snapshot, state)
			}

			guard Date() < deadline else {
				throw Failure.timedOut(
					wait: "page-state-persisted-\(persisted)",
					state: state.map { "persisted=\($0.persisted),served=\($0.served)" } ?? "none"
				)
			}

			try await Task.sleep(for: .milliseconds(100))
		}
	}

	private static func state(in snapshot: ChromiumInspectionSnapshot) -> PageState? {
		let line = snapshot.nodes
			.flatMap { [$0.name, $0.text].compactMap(\.self) }
			.first { $0.hasPrefix(statePrefix + " ") }
		guard let line else { return nil }

		var fields: [String: String] = [:]
		for field in line.split(separator: " ").dropFirst() {
			let parts = field.split(separator: "=", maxSplits: 1)
			guard parts.count == 2 else { return nil }

			fields[String(parts[0])] = String(parts[1])
		}
		guard
			let persisted = fields["persisted"],
			let served = fields["served"].flatMap({ Int($0) }),
			let token = fields["token"],
			!token.isEmpty
		else { return nil }

		return PageState(persisted: persisted == "true", served: served, token: token)
	}

	private func reference(in snapshot: ChromiumInspectionSnapshot) throws -> String {
		let matches = snapshot.nodes.filter { $0.role == "button" && $0.name == Self.buttonName }
		guard matches.count == 1, let reference = matches.first?.reference
		else { throw Failure.unexpected("button-reference") }

		return reference
	}

	private func requireStale(
		_ reference: String,
		in snapshot: ChromiumInspectionSnapshot,
		on page: ChromiumPage,
		scope: UUID
	) async throws {
		do {
			try await runtime.validateInspectionReference(reference, in: snapshot, on: page, scope: scope)
			throw Failure.acceptedStale
		} catch ChromiumInspectionFailure.staleReference {
			// Only the exact stale-reference failure counts.
		}
	}

	private func revision(of page: ChromiumPage) throws -> UInt64 {
		guard let revision = runtime.documentRevision(for: page)
		else { throw Failure.unexpected("revision-missing") }

		return revision
	}

	private func makePage() async throws -> ChromiumPage {
		let page = try await runtime.makePage(profile: nil)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 480),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = page.view
		window.makeKeyAndOrderFront(nil)
		pages.append(page)
		windows[page.identifier] = window
		return page
	}

	private func waitLoaded(
		_ page: ChromiumPage,
		url: URL,
		title: String
	) async throws {
		try await wait(
			"loaded-\(url.lastPathComponent)",
			state: {
				let navigation = page.navigation
				return "url=\(navigation.url?.path ?? "none"),title=\(navigation.title),"
				+ "loading=\(navigation.isLoading),error=\(String(describing: navigation.errorCode))"
			}
		) {
			page.navigation.url == url
			&& page.navigation.title == title
			&& !page.navigation.isLoading
			&& page.navigation.errorCode == nil
		}
	}

	private func url(_ name: String) -> URL {
		URL(string: "/back-forward-cache/\(name)", relativeTo: baseURL)!.absoluteURL
	}

	/// Waits up to 15 seconds for `condition`. A time out names the wait and what `state`
	/// reports at that moment.
	private func wait(
		_ name: String,
		state: @escaping @MainActor () -> String,
		until condition: @escaping @MainActor () -> Bool
	) async throws {
		let deadline = Date().addingTimeInterval(15)
		while !condition() {
			guard Date() < deadline else { throw Failure.timedOut(wait: name, state: state()) }

			try await Task.sleep(for: .milliseconds(25))
		}
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
