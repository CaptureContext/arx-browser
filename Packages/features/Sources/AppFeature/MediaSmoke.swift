#if DEBUG
import AppKit
import BrowserCore
import BrowserMediaClient
import ChromiumBrowserEngine
import ChromiumEngine
import Darwin
import Foundation

/// Developer-only disposable fixture, independent of ordinary capability composition.
@MainActor
internal enum MediaSmoke {
	internal static func run(
		engine: ChromiumBrowserEngine,
		runtime: ChromiumRuntime,
		profileID: Profile.ID,
		baseURL: URL,
		profileDirectory: URL,
		environment: [String: String]
	) async throws {
		guard let path = environment["ARX_MEDIA_SMOKE_ROOT"]
		else { throw MediaSmokeFailure.invalidFixture }

		try MediaSmokeFixture.validate(
			root: URL(fileURLWithPath: path),
			profile: profileDirectory,
			baseURL: baseURL
		)
		try await Runner(
			engine: engine,
			runtime: runtime,
			profileID: profileID,
			baseURL: baseURL
		).run()
		try await AutomaticMediaVisibilitySmoke.run(
			engine: engine,
			baseURL: baseURL,
			profileID: profileID
		)
		try await AutomaticPictureInPictureSmoke.run(
			engine: engine,
			baseURL: baseURL,
			profileID: profileID
		)
		try await PageFullScreenSmoke.run(
			engine: engine,
			baseURL: baseURL,
			profileID: profileID
		)
		try await PagePictureInPictureSmoke.run(
			engine: engine,
			baseURL: baseURL,
			profileID: profileID
		)
	}
}

extension MediaSmoke {
	@MainActor
	private final class Runner {
		private let engine: ChromiumBrowserEngine
		private let runtime: ChromiumRuntime
		private let profileID: Profile.ID
		private let baseURL: URL
		private let privateID: UUID = .init()
		private var privatePage: ChromiumPage?
		private var windows: [Tab.ID: NSWindow] = [:]
		private var ownedTabs: Set<Tab.ID> = []
		private var fixtureCases: [Tab.ID: String] = [:]
		private var privateWindow: NSWindow?
		private var snapshot: BrowserMediaSnapshot = .init()
		private var observation: Task<Void, Never>?
		private var client: BrowserMediaClient?

		internal init(
			engine: ChromiumBrowserEngine,
			runtime: ChromiumRuntime,
			profileID: Profile.ID,
			baseURL: URL
		) {
			self.engine = engine
			self.runtime = runtime
			self.profileID = profileID
			self.baseURL = baseURL
		}

		internal func run() async throws {
			let previous = NSApp.keyWindow
			defer {
				observation?.cancel()
				for tab in Array(windows.keys) { close(tab) }
				privatePage?.close()
				privateWindow?.close()
				runtime.releasePrivateProfile(privateID)
				previous?.makeKeyAndOrderFront(nil)
			}

			let client = try engine.media()
			self.client = client
			let events = client.events()
			observation = Task { [weak self] in
				for await snapshot in events {
					guard !Task.isCancelled else { return }

					self?.snapshot = snapshot
				}
			}

			let first = try await open("normal")
			try await wait {
				guard let source = self.source(first) else { return false }

				return source.supports(.pause) && client.isSourceCurrent(source.id)
			}

			guard
				let firstSource = source(first),
				client.isSourceCurrent(firstSource.id)
			else { throw MediaSmokeFailure.sourceIdentityMismatch }

			try await perform(first, .pause)
			try await wait {
				self.source(first)?.playback == .paused
				&& self.state(first)?.playing == false
			}
			try await perform(first, .play)
			try await wait {
				self.source(first)?.playback == .playing
				&& self.state(first)?.playing == true
			}

			let before = try pageState(first)
			let originalURL = engine.client.snapshot(first)?.navigation.url
			try await enter(first)
			try await placedPictureInPictureWindow()
			try await perform(first, .exitPictureInPicture)
			try await wait {
				self.source(first)?.isInPictureInPicture == false
				&& self.state(first)?.pip == false
			}
			let after = try pageState(first)

			guard
				after.playing,
				after.loads == before.loads,
				after.plays == before.plays,
				after.pauses == before.pauses,
				engine.client.snapshot(first)?.navigation.url == originalURL,
				after.entered == before.entered + 1,
				after.left == before.left + 1
			else { throw MediaSmokeFailure.playbackMismatch }

			print("ARX_MEDIA_PLAYBACK_SUCCESS")

			try await enter(first)
			let second = try await open("second")
			try await enter(second)
			try await wait {
				self.source(first)?.isInPictureInPicture == false
				&& self.state(first)?.pip == false
				&& self.source(second)?.isInPictureInPicture == true
				&& self.state(second)?.pip == true
				&& self.source(second).map { client.isSourceCurrent($0.id) } == true
			}

			guard
				snapshot.sources.filter(\.isInPictureInPicture).count == 1,
				try pageState(first).playing,
				try pageState(first).pauses == after.pauses
			else { throw MediaSmokeFailure.replacementMismatch }

			guard
				let secondSource = source(second),
				client.isSourceCurrent(secondSource.id)
			else { throw MediaSmokeFailure.sourceIdentityMismatch }

			close(second)

			guard !client.isSourceCurrent(secondSource.id)
			else { throw MediaSmokeFailure.sourceIdentityMismatch }

			try await wait {
				self.source(second) == nil
				&& !self.snapshot.sources.contains(where: \.isInPictureInPicture)
			}
			try await enter(first)

			let stale = try request(first, .pause)
			try await engine.client.command(first, .navigate(url("second")))
			try await start(first, fixtureCase: "second")
			try await wait {
				self.state(first)?.fixtureCase == "second"
				&& self.source(first)?.id.generation != stale.sourceID.generation
				&& self.source(first)?.isInPictureInPicture == false
				&& self.source(first).map { client.isSourceCurrent($0.id) } == true
			}

			guard
				!client.isSourceCurrent(stale.sourceID),
				let replacement = source(first),
				client.isSourceCurrent(replacement.id)
			else { throw MediaSmokeFailure.sourceIdentityMismatch }

			do {
				try await client.perform(stale)
				throw MediaSmokeFailure.staleRequestAccepted
			} catch BrowserMediaClient.Failure.staleSource {}

			close(first)

			guard !client.isSourceCurrent(replacement.id)
			else { throw MediaSmokeFailure.sourceIdentityMismatch }

			try await wait { self.source(first) == nil }
			print("ARX_MEDIA_REPLACEMENT_SUCCESS")

			let late = try await open("late")
			try await wait { self.source(late)?.supports(.enterPictureInPicture) == true }

			do {
				try await perform(late, .enterPictureInPicture)
				throw lateEntryAccepted(late)
			} catch BrowserMediaClient.Failure.timedOut {}

			try await rejectQuarantinedRetry(late)
			try await wait {
				self.state(late)?.requests == 1 && self.state(late)?.error == "pip-denied"
			}

			guard source(late)?.isInPictureInPicture == false
			else { throw lateEntryAccepted(late) }

			close(late)
			try await interrupt(.cancel)
			try await interrupt(.navigate)
			try await interrupt(.close)

			let removed = try await open("remove")
			try await enter(removed)
			try await wait {
				self.source(removed)?.isInPictureInPicture != true
				&& self.state(removed)?.pip == false
			}
			close(removed)
			print("ARX_MEDIA_INVALIDATION_SUCCESS")
			try await positionAndSound()
			try await automaticEntry()

			// Compare only this owned OTR page's known URL/readiness.
			// Collect no private title, playback or metadata.
			try runtime.preparePrivateProfile(privateID)
			let page = try await runtime.makePage(profile: privateID)
			privatePage = page

			guard page.isPrivate else { throw MediaSmokeFailure.privatePolicyMismatch }

			privateWindow = window(content: page.view)
			try page.navigate(to: url("private"))
			try await wait {
				page.navigation.url == self.url("private")
				&& !page.navigation.isLoading
				&& page.navigation.errorCode == nil
			}

			guard
				let ownedPrivateWindow = privateWindow,
				privatePage === page,
				page.isPrivate,
				!page.isClosed,
				ownedPrivateWindow.contentView === page.view,
				page.view.window === ownedPrivateWindow
			else { throw MediaSmokeFailure.invalidFixture }

			try await clickStart(
				in: ownedPrivateWindow,
				content: page.view,
				currentURL: page.navigation.url,
				expectedURL: url("private")
			)
			try await wait { self.runtime.privateMediaMetadataIsHidden(page) == true }

			do {
				try runtime.observeMedia(page)
				throw MediaSmokeFailure.privatePolicyMismatch
			} catch ChromiumMediaFailure.unavailable {}

			page.close()
			privatePage = nil
			privateWindow?.close()
			privateWindow = nil
			runtime.releasePrivateProfile(privateID)
			print("ARX_MEDIA_PRIVATE_POLICY_SUCCESS")

			try await wait {
				self.windows.isEmpty
				&& self.ownedTabs.allSatisfy {
					self.source($0) == nil && self.engine.client.snapshot($0) == nil
				}
			}
			print("ARX_MEDIA_SMOKE_SUCCESS")
		}

		/// Seeks paused media, reads its position on request, and mutes and
		/// unmutes the page while it plays.
		private func positionAndSound() async throws {
			guard let client else { throw MediaSmokeFailure.invalidFixture }

			let tab = try await open("normal")
			defer { close(tab) }

			try await wait {
				self.source(tab)?.supports(.pause) == true
				&& self.source(tab)?.supports(.seek) == true
			}
			try await perform(tab, .pause)
			try await wait {
				self.source(tab)?.playback == .paused
				&& self.state(tab)?.playing == false
			}

			guard
				let paused = source(tab),
				let before = client.position(tab),
				before.sourceID == paused.id,
				!before.isMuted,
				before.position != nil,
				let duration = before.duration,
				abs(duration - 2) < 0.25
			else { throw MediaSmokeFailure.positionMismatch }

			try await run(.init(source: paused, seekingTo: 1.25))
			try await wait { self.state(tab)?.time.map { abs($0 - 1.25) < 0.1 } == true }

			guard
				let seeked = client.position(tab),
				let position = seeked.position,
				abs(position - 1.25) < 0.25,
				state(tab)?.playing == false
			else { throw MediaSmokeFailure.positionMismatch }

			// Muting a playing page keeps it playing; Chromium drops its player
			// from the media session until it is unmuted.
			try await perform(tab, .play)
			try await wait { self.state(tab)?.playing == true }
			try setMuted(tab, true)
			try await wait { client.position(tab)?.isMuted == true }

			guard state(tab)?.playing == true
			else { throw MediaSmokeFailure.positionMismatch }

			try setMuted(tab, false)
			try await wait {
				client.position(tab)?.isMuted == false
				&& self.source(tab)?.supports(.pause) == true
				&& self.state(tab)?.playing == true
			}
			print("ARX_MEDIA_POSITION_SUCCESS")

			try await volume(tab)

			// The same page muted the way a tab row's Mute Tab does, through the app's composition.
			try await AppTabMuteSmoke.run(
				engine: engine,
				runtime: runtime,
				tab: tab,
				profileID: profileID,
				url: url("normal"),
				native: client,
				isPlaying: { [weak self] in self?.state(tab)?.playing == true }
			)
		}

		/// Turns the playing page down and back up (DEV-800). The engine reports
		/// success only once the page's audio group carries the new volume.
		private func volume(_ tab: Tab.ID) async throws {
			guard let client else { throw MediaSmokeFailure.invalidFixture }
			guard client.supportsVolume() else { throw MediaSmokeFailure.volumeMismatch }

			try client.setVolume(tab, 0.3)
			try await wait { self.state(tab)?.playing == true }
			try client.setVolume(tab, 0)

			guard
				state(tab)?.playing == true,
				client.position(tab)?.isMuted == false
			else { throw MediaSmokeFailure.volumeMismatch }

			// Outside [0, 1] is refused and leaves the page as it was.
			if (try? client.setVolume(tab, 1.5)) != nil { throw MediaSmokeFailure.volumeMismatch }

			try client.setVolume(tab, 1)
			try await wait { self.state(tab)?.playing == true }
			print("ARX_MEDIA_VOLUME_SUCCESS")
		}

		private enum Interruption {
			case cancel, navigate, close
		}

		private func automaticEntry() async throws {
			let tab = try await open("automatic")
			defer { close(tab) }

			try await wait {
				self.source(tab)?.supports(.enterAutomaticPictureInPicture) == true
				&& self.state(tab)?.active == false
				&& self.windows[tab]?.occlusionState.contains(.visible) == true
			}

			guard let window = windows[tab]
			else { throw MediaSmokeFailure.invalidFixture }

			do {
				try await perform(tab, .enterAutomaticPictureInPicture)
				throw MediaSmokeFailure.visibleAutomaticEntryAccepted
			} catch BrowserMediaClient.Failure.unsupportedAction {}

			guard state(tab)?.requests == 0
			else { throw MediaSmokeFailure.visibleAutomaticEntryAccepted }

			window.orderOut(nil)
			try await wait { !window.isVisible }
			try await perform(tab, .enterAutomaticPictureInPicture)
			try await wait {
				self.source(tab)?.isInPictureInPicture == true
				&& self.state(tab)?.pip == true
			}

			let entered = try pageState(tab)
			guard
				entered.requests == 1,
				entered.entryReason == "contentoccluded",
				entered.activeAtRequest == false,
				entered.starts == 1,
				entered.plays == 1,
				entered.pauses == 0
			else { throw MediaSmokeFailure.automaticEntryMismatch }

			try await perform(tab, .exitPictureInPicture)
			close(tab)

			// A page without an enterpictureinpicture handler still gets automatic PiP: Arx
			// enters it on the browser's behalf (BrowserInitiatedAutomaticPictureInPicture),
			// so sites like YouTube open PiP when their tab is left. Whether Arx asks is
			// decided per site and by Settings; AutomaticMediaVisibilitySmoke checks those gates.
			let manual = try await open("manual-only")
			defer { close(manual) }
			try await wait {
				self.source(manual)?.supports(.enterPictureInPicture) == true
				&& self.source(manual)?.supports(.enterAutomaticPictureInPicture) == true
				&& self.windows[manual]?.occlusionState.contains(.visible) == true
			}

			guard let manualWindow = windows[manual]
			else { throw MediaSmokeFailure.invalidFixture }

			manualWindow.orderOut(nil)
			try await wait { !manualWindow.isVisible }
			try await perform(manual, .enterAutomaticPictureInPicture)
			try await wait {
				self.source(manual)?.isInPictureInPicture == true
				&& self.state(manual)?.pip == true
			}
			guard state(manual)?.requests == 0
			else { throw MediaSmokeFailure.automaticEntryMismatch }

			try await perform(manual, .exitPictureInPicture)
			close(manual)

			let delayed = try await open("automatic-delayed")
			defer { close(delayed) }
			try await wait {
				self.source(delayed)?.supports(.enterAutomaticPictureInPicture) == true
				&& self.state(delayed)?.active == false
			}

			guard let delayedWindow = windows[delayed]
			else { throw MediaSmokeFailure.invalidFixture }

			delayedWindow.orderOut(nil)
			try await wait { !delayedWindow.isVisible }
			let task = Task { try await perform(delayed, .enterAutomaticPictureInPicture) }
			defer { task.cancel() }
			try await wait { self.state(delayed)?.requests == 1 }
			delayedWindow.makeKeyAndOrderFront(nil)
			try await wait { delayedWindow.occlusionState.contains(.visible) }

			do {
				try await task.value
				throw MediaSmokeFailure.visibleAutomaticEntryAccepted
			} catch BrowserMediaClient.Failure.timedOut {}

			try await wait {
				self.state(delayed)?.error == "pip-denied"
				&& self.source(delayed)?.supports(.enterAutomaticPictureInPicture) == false
			}

			guard
				state(delayed)?.pip == false,
				source(delayed)?.isInPictureInPicture == false
			else { throw MediaSmokeFailure.visibleAutomaticEntryAccepted }

			print("ARX_MEDIA_AUTOMATIC_SUCCESS")
		}

		private func interrupt(_ interruption: Interruption) async throws {
			let tab = try await open("late")
			defer { close(tab) }

			try await wait { self.source(tab)?.supports(.enterPictureInPicture) == true }
			let task = Task { try await perform(tab, .enterPictureInPicture) }
			defer { task.cancel() }

			try await wait { self.state(tab)?.requests == 1 }

			switch interruption {
			case .cancel: task.cancel()
			case .navigate: try await engine.client.command(tab, .navigate(url("normal")))
			case .close: close(tab)
			}

			do {
				try await task.value
				throw MediaSmokeFailure.staleRequestAccepted
			} catch is CancellationError where interruption == .cancel {
			} catch is MediaSmokeStaleSource where interruption != .cancel {
			}

			if interruption == .cancel {
				try await rejectQuarantinedRetry(tab)
				try await wait { self.state(tab)?.error == "pip-denied" }

				guard source(tab)?.isInPictureInPicture == false
				else { throw lateEntryAccepted(tab) }

			} else if interruption == .navigate {
				try await start(tab, fixtureCase: "normal")

				// The new page's source can arrive a moment after it starts playing; until then
				// there's nothing to be in Picture in Picture (DEV-964).
				try await wait { self.source(tab) != nil }

				guard source(tab)?.isInPictureInPicture == false
				else { throw lateEntryAccepted(tab) }
			}
		}

		private func rejectQuarantinedRetry(_ tab: Tab.ID) async throws {
			try await wait {
				self.source(tab) != nil
				&& self.source(tab)?.supports(.enterPictureInPicture) == false
			}

			guard
				let client,
				let current = source(tab),
				state(tab)?.requests == 1
			else { throw MediaSmokeFailure.missingSource }

			do {
				try await client.perform(.init(source: current, action: .enterPictureInPicture))
				throw lateEntryAccepted(tab)
			} catch BrowserMediaClient.Failure.staleSource {}

			guard state(tab)?.requests == 1 else { throw lateEntryAccepted(tab) }
		}

		private func open(_ fixtureCase: String) async throws -> Tab.ID {
			let tab = Tab(
				id: .init(rawValue: UUID()),
				profileID: profileID,
				restoration: .init(title: "Media fixture", url: url(fixtureCase))
			)
			let host = NSView(frame: .init(x: 0, y: 0, width: 640, height: 420))

			ownedTabs.insert(tab.id)
			windows[tab.id] = window(content: host)

			// The host is in its window before the page exists, so the engine mounts the page as it
			// opens and the fixture loads in a visible page. Attached after, the fixture's video was
			// created while the page was still hidden, where Chromium defers a never-played page's
			// media load until it's shown; one run waited 10 s with the page still loading and its
			// video never ready (DEV-1177). The private page below is shown before it loads too.
			engine.surface.attach(tab.id, host)
			try await engine.client.open(tab)
			try await start(tab.id, fixtureCase: fixtureCase)

			return tab.id
		}

		private func start(
			_ tab: Tab.ID,
			fixtureCase: String
		) async throws {
			fixtureCases[tab] = fixtureCase
			try await wait {
				self.state(tab)?.fixtureCase == fixtureCase
				&& self.state(tab)?.ready == true
				&& self.engine.client.snapshot(tab)?.navigation.isLoading == false
			}

			guard
				ownedTabs.contains(tab),
				let window = windows[tab],
				let host = window.contentView,
				host.window === window,
				host.subviews.count == 1,
				host.subviews.first?.window === window,
				engine.isAttached(tab),
				let state = state(tab),
				state.starts == 0,
				state.trustedStarts == 0,
				!state.playing,
				state.error == nil
			else { throw MediaSmokeFailure.invalidFixture }

			try await clickStart(
				in: window,
				content: host,
				currentURL: engine.client.snapshot(tab)?.navigation.url,
				expectedURL: url(fixtureCase)
			)
			try await wait {
				self.state(tab)?.fixtureCase == fixtureCase
				&& self.state(tab)?.playing == true
				&& self.state(tab)?.starts == 1
				&& self.state(tab)?.trustedStarts == 1
			}
		}

		private func clickStart(
			in window: NSWindow,
			content: NSView,
			currentURL: URL?,
			expectedURL: URL
		) async throws {
			guard
				windows.values.contains(where: { $0 === window }) || privateWindow === window,
				window.contentView === content,
				content.window === window
			else { throw MediaSmokeFailure.invalidFixture }

			// AppKit hands over key status asynchronously, and only to an active app.
			NSApp.activate()
			window.makeKeyAndOrderFront(nil)
			try await wait { window.isKeyWindow && NSApp.keyWindow === window }

			guard
				window.isVisible,
				window.isKeyWindow,
				NSApp.keyWindow === window,
				window.windowNumber > 0
			else { throw MediaSmokeFailure.invalidFixture }

			let point = try MediaSmokeInput.startPoint(
				currentURL: currentURL,
				expectedURL: expectedURL,
				bounds: content.bounds,
				isFlipped: content.isFlipped
			)
			let location = content.convert(point, to: nil)
			let timestamp = ProcessInfo.processInfo.systemUptime
			let down = NSEvent.mouseEvent(
				with: .leftMouseDown,
				location: location,
				modifierFlags: [],
				timestamp: timestamp,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 1,
				clickCount: 1,
				pressure: 1
			)
			let up = NSEvent.mouseEvent(
				with: .leftMouseUp,
				location: location,
				modifierFlags: [],
				timestamp: timestamp + 0.001,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 2,
				clickCount: 1,
				pressure: 0
			)

			guard let down, let up
			else { throw MediaSmokeFailure.invalidFixture }

			// Dispatch only to this owned fixture window, never the global event queue or the user's browser.
			window.sendEvent(down)
			window.sendEvent(up)
		}

		private func window(content: NSView) -> NSWindow {
			let window = NSWindow(
				contentRect: .init(x: 0, y: 0, width: 640, height: 420),
				styleMask: [.titled],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			window.title = "Arx controlled media fixture"
			window.contentView = content
			window.makeKeyAndOrderFront(nil)

			return window
		}

		private func close(_ tab: Tab.ID) {
			guard let window = windows.removeValue(forKey: tab) else { return }

			engine.client.close(tab)
			if let host = window.contentView { engine.surface.detach(host) }
			window.close()
		}

		private func url(_ fixtureCase: String) -> URL {
			baseURL.deletingLastPathComponent().appendingPathComponent("media/\(fixtureCase).html")
		}

		private func source(_ tab: Tab.ID) -> BrowserMediaSource? {
			snapshot.sources.first { $0.id.tabID == tab && $0.id.profileID == profileID }
		}

		private func request(
			_ tab: Tab.ID,
			_ action: BrowserMediaSource.Action
		) throws -> BrowserMediaRequest {
			guard let source = source(tab), source.supports(action)
			else { throw MediaSmokeFailure.missingSource }

			return .init(source: source, action: action)
		}

		private func perform(
			_ tab: Tab.ID,
			_ action: BrowserMediaSource.Action,
			line: Int = #line
		) async throws {
			try await run(try request(tab, action), line: line)
		}

		private func run(
			_ request: BrowserMediaRequest,
			line: Int = #line
		) async throws {
			guard let client else { throw MediaSmokeFailure.missingSource }

			var request = request
			for attempt in 0...2 {
				do {
					return try await run(request, on: client)
				} catch BrowserMediaClient.Failure.staleSource {
					guard
						attempt < 2,
						let revised = await revisedSource(for: request, client: client)
					else {
						// An earlier attempt may have done it: its reply can land after the
						// snapshot has moved past the revision the next attempt carried. On the
						// same source (the same document), the request's goal already holding
						// is success. A navigated page is a new source and never counts.
						if
							let current = source(request.sourceID.tabID),
							current.id == request.sourceID,
							Self.holds(request.action, on: current)
						{
							let message = "ARX_MEDIA_SMOKE_ALREADY_DONE step=\(fixtureCases[request.sourceID.tabID] ?? "unknown")."
							+ "\(request.action)@MediaSmoke.swift:\(line) source=(\(MediaSmokeStaleSource.describe(current)))\n"
							FileHandle.standardError.write(Data(message.utf8))
							return
						}
						throw staleSource(
							"\(request.action)",
							line: line,
							tab: request.sourceID.tabID,
							request: request
						)
					}

					// Chromium bumps a source's revision on any media-session change, and
					// starting playback can bump it once more after the source first appears.
					// Like any client, re-read and retry while it's the same source.
					let message = "ARX_MEDIA_SMOKE_REVISION_RETRY step=\(fixtureCases[request.sourceID.tabID] ?? "unknown")."
					+ "\(request.action)@MediaSmoke.swift:\(line) from=\(request.expectedRevision) "
					+ "to=\(revised.revision) source=(\(MediaSmokeStaleSource.describe(revised)))\n"
					FileHandle.standardError.write(Data(message.utf8))
					request.expectedRevision = revised.revision
				}
			}
		}

		/// Whether `source` is already where `action` takes it. Only state-setting actions count;
		/// the others always need their own successful reply.
		private static func holds(_ action: BrowserMediaSource.Action, on source: BrowserMediaSource) -> Bool {
			switch action {
			case .enterPictureInPicture, .enterAutomaticPictureInPicture: source.isInPictureInPicture
			case .exitPictureInPicture: !source.isInPictureInPicture
			case .play: source.playback == .playing
			case .pause: source.playback == .paused
			default: false
			}
		}

		/// `lateEntryAccepted`, with what the page and Chromium reported at the time, so a failure
		/// says whether the page itself asked for Picture in Picture (DEV-964).
		private func lateEntryAccepted(_ tab: Tab.ID, line: Int = #line) -> MediaSmokeFailure {
			let fields: [String] = [
				"line=\(line)",
				"case=\(fixtureCases[tab] ?? "unknown")",
				"state=\(state(tab).map { String(describing: $0) } ?? "none")",
				"source=\(source(tab).map(MediaSmokeStaleSource.describe) ?? "none")",
			]
			FileHandle.standardError.write(Data(
				("ARX_MEDIA_SMOKE_LATE_ENTRY " + fields.joined(separator: " ") + "\n").utf8
			))
			return .lateEntryAccepted
		}

		/// The same source at a newer revision that still offers the request's action, if one
		/// shows up within a second; `nil` when the source was replaced, closed or lost the action.
		private func revisedSource(
			for request: BrowserMediaRequest,
			client: BrowserMediaClient
		) async -> BrowserMediaSource? {
			let deadline = ContinuousClock.now.advanced(by: .seconds(1))
			while ContinuousClock.now < deadline, !Task.isCancelled {
				if
					let current = source(request.sourceID.tabID),
					current.id == request.sourceID,
					current.revision > request.expectedRevision,
					current.supports(request.action),
					client.isSourceCurrent(current.id)
				{ return current }

				try? await Task.sleep(for: .milliseconds(25))
			}

			return nil
		}

		private func setMuted(
			_ tab: Tab.ID,
			_ isMuted: Bool,
			line: Int = #line
		) throws {
			guard let client else { throw MediaSmokeFailure.missingSource }

			do {
				try client.setMuted(tab, isMuted)
			} catch BrowserMediaClient.Failure.staleSource {
				throw staleSource("setMuted(\(isMuted))", line: line, tab: tab, request: nil)
			}
		}

		/// Names the step and compares the request with the source this smoke last observed.
		private func staleSource(
			_ action: String,
			line: Int,
			tab: Tab.ID,
			request: BrowserMediaRequest?
		) -> MediaSmokeStaleSource {
			let current = source(tab)
			let window = windows[tab]
			let windowState = window.map { window in
				"visible=\(window.isVisible) occlusionVisible=\(window.occlusionState.contains(.visible)) key=\(window.isKeyWindow)"
			}

			return MediaSmokeStaleSource(
				step: "\(fixtureCases[tab] ?? "unknown").\(action)@MediaSmoke.swift:\(line)",
				expected: request.map { "generation=\($0.sourceID.generation) revision=\($0.expectedRevision)" }
					?? "an ordinary page for the tab",
				actual: [
					current.map(MediaSmokeStaleSource.describe) ?? "source=none",
					"sourceCurrent=\(request.map { client?.isSourceCurrent($0.sourceID) == true }.map(String.init) ?? "n/a")",
					"snapshotRevision=\(snapshot.revision)",
					"fixtureWindow(\(windowState ?? "none"))",
				].joined(separator: " "),
				focus: SmokeDiagnostics.focus()
			)
		}

		private func run(
			_ request: BrowserMediaRequest,
			on client: BrowserMediaClient
		) async throws {
			let task = Task { try await client.perform(request) }
			let deadline = Task {
				try await Task.sleep(for: .seconds(7))
				task.cancel()
			}
			defer {
				task.cancel()
				deadline.cancel()
			}

			try await withTaskCancellationHandler {
				try await task.value
			} onCancel: {
				task.cancel()
			}
		}

		private func enter(
			_ tab: Tab.ID,
			line: Int = #line
		) async throws {
			try await wait { self.source(tab)?.supports(.enterPictureInPicture) == true }
			try await perform(tab, .enterPictureInPicture, line: line)
			try await wait {
				self.source(tab)?.isInPictureInPicture == true
				&& self.state(tab)?.pip == true
			}
		}

		/// ArxPiP opens at its bottom-right resting position 16 points inside its screen's visible
		/// frame (DEV-848), with continuous 16-point corners (DEV-825), on every Space and over
		/// full-screen apps (DEV-852). Throwing, the time labels and display changes are
		/// `AutomaticPictureInPictureSmoke`'s; pinching needs input and is checked by hand.
		private func placedPictureInPictureWindow() async throws {
			try await wait { Self.isPictureInPictureWindowPlaced() }
			print("ARX_MEDIA_PIP_WINDOW_SUCCESS")
		}

		private static func isPictureInPictureWindowPlaced() -> Bool {
			guard
				let window = PictureInPictureWindow.visible(),
				PictureInPictureWindow.joinsEverySpace(window),
				let screen = window.screen,
				let layer = window.contentView?.layer,
				layer.cornerRadius == 16,
				layer.cornerCurve == .continuous
			else { return false }

			let frame: NSRect = window.frame
			let visible: NSRect = screen.visibleFrame
			return abs(frame.maxX - (visible.maxX - 16)) < 1
			&& abs(frame.minY - (visible.minY + 16)) < 1
		}

		private func state(_ tab: Tab.ID) -> MediaSmokePageState? { try? pageState(tab) }

		private func pageState(_ tab: Tab.ID) throws -> MediaSmokePageState {
			guard
				windows[tab] != nil,
				let navigation = engine.client.snapshot(tab)?.navigation,
				navigation.errorCode == nil,
				navigation.url?.host == baseURL.host,
				navigation.url?.port == baseURL.port,
				navigation.url?.path.hasPrefix("/media/") == true
			else { throw MediaSmokeFailure.invalidFixture }

			return try MediaSmokePageState(title: navigation.title)
		}

		private func wait(
			file: StaticString = #fileID,
			line: Int = #line,
			function: StaticString = #function,
			_ condition: () -> Bool
		) async throws {
			let start = ContinuousClock.now
			let deadline = start.advanced(by: .seconds(10))

			while ContinuousClock.now < deadline {
				try Task.checkCancellation()
				if condition() { return }
				try await Task.sleep(for: .milliseconds(25))
			}

			throw SmokeDiagnostics.timeout(
				site: "\(file):\(line) \(function)",
				since: start,
				state: ownedState()
			)
		}

		/// Every owned fixture's source, page state and window; fixture state only, no titles or URLs.
		private func ownedState() -> String {
			let tabs = windows.keys.map { tab -> String in
				let page = state(tab).map { page in
					"ready=\(page.ready) playing=\(page.playing) pip=\(page.pip) requests=\(page.requests) "
					+ "starts=\(page.starts) active=\(page.active) error=\(page.error ?? "nil") "
					+ "visibility=\(page.visibility ?? "nil") videoReady=\(page.videoReady.map(String.init) ?? "nil") "
					+ "network=\(page.network.map(String.init) ?? "nil") reports=\(page.reports.map(String.init) ?? "nil")"
				} ?? "page=unreadable"
				let window = windows[tab].map { window in
					"visible=\(window.isVisible) occlusionVisible=\(window.occlusionState.contains(.visible)) "
					+ "key=\(window.isKeyWindow)"
				} ?? "none"
				let loading = engine.client.snapshot(tab).map { "\($0.navigation.isLoading)" } ?? "noSnapshot"
				let source = source(tab).map(MediaSmokeStaleSource.describe) ?? "source=none"
				return "\(fixtureCases[tab] ?? "unknown"): \(source) \(page) loading=\(loading) window(\(window))"
			}

			return [
				"snapshotRevision=\(snapshot.revision)",
				"sourcesInPictureInPicture=\(snapshot.sources.filter(\.isInPictureInPicture).count)",
				"privatePage=\(privatePage != nil)",
				"tabs=[\(tabs.sorted().joined(separator: "; "))]",
			].joined(separator: " ")
		}
	}
}

/// `BrowserMediaClient.Failure.staleSource`, with the step that got it and what this smoke saw.
///
/// Holds identifiers, revisions and flags only, never media titles or URLs.
internal struct MediaSmokeStaleSource: Error, CustomStringConvertible {
	internal let step: String
	internal let expected: String
	internal let actual: String
	internal let focus: String

	internal init(
		step: String,
		expected: String,
		actual: String,
		focus: String
	) {
		self.step = step
		self.expected = expected
		self.actual = actual
		self.focus = focus
	}

	internal var description: String {
		"staleSource step=\(step) expected=(\(expected)) actual=(\(actual)) \(focus)"
	}

	internal static func describe(_ source: BrowserMediaSource) -> String {
		let actions = source.actions.map { "\($0)" }.sorted().joined(separator: ",")
		return [
			"generation=\(source.id.generation)",
			"revision=\(source.revision)",
			"playback=\(source.playback)",
			"pip=\(source.isInPictureInPicture)",
			"hasVideo=\(source.hasVideo)",
			"site=\(source.site == nil ? "none" : "some")",
			"titleLength=\(source.title.count)",
			"actions=[\(actions)]",
		].joined(separator: " ")
	}
}

internal enum MediaSmokeFailure: Error {
	case invalidFixture, invalidPageState, missingSource, timedOut
	case playbackMismatch, replacementMismatch, staleRequestAccepted
	case lateEntryAccepted, privatePolicyMismatch, sourceIdentityMismatch
	case visibleAutomaticEntryAccepted, automaticEntryMismatch
	case positionMismatch, volumeMismatch
}

internal struct MediaSmokePageState: Decodable {
	internal let fixtureCase: String
	internal let ready: Bool
	internal let starts: Int
	internal let trustedStarts: Int
	internal let playing: Bool
	internal let pip: Bool
	internal let loads: Int
	internal let plays: Int
	internal let pauses: Int
	internal let entered: Int
	internal let left: Int
	internal let requests: Int
	internal let error: String?
	internal let active: Bool
	internal let activeAtRequest: Bool?
	internal let entryReason: String?

	/// The video's current time, in seconds.
	internal let time: Double?

	/// For a timeout's description (DEV-1177): the page's `visibilityState`, the video's
	/// `readyState` and `networkState`, and how many times the page has reported, every 100 ms.
	/// A hidden page's video never starts loading; a visible one stuck at `readyState` 0 with
	/// `networkState` 2 waits on its fetch; few reports after seconds mean the title the app sees
	/// stopped changing.
	internal let visibility: String?
	internal let videoReady: Int?
	internal let network: Int?
	internal let reports: Int?

	private enum CodingKeys: String, CodingKey {
		case fixtureCase = "case"
		case ready, starts, trustedStarts
		case playing, pip, loads, plays, pauses
		case entered, left, requests, error
		case active, activeAtRequest, entryReason, time
		case visibility, videoReady, network, reports
	}

	internal init(title: String) throws {
		guard title.utf8.count <= 2048, title.hasPrefix("Arx media ")
		else { throw MediaSmokeFailure.invalidPageState }

		let payload = Data(title.dropFirst("Arx media ".count).utf8)
		self = try JSONDecoder().decode(Self.self, from: payload)

		guard
			["normal", "second", "late", "remove", "automatic", "automatic-delayed", "manual-only"].contains(fixtureCase),
			(0...1).contains(starts),
			trustedStarts == starts,
			entryReason.map({ ["other", "useraction", "contentoccluded"].contains($0) }) != false,
			!playing || (ready && trustedStarts == 1),
			[loads, plays, pauses, entered, left, requests].allSatisfy({ (0...100).contains($0) }),
			visibility.map({ ["visible", "hidden"].contains($0) }) != false,
			videoReady.map({ (0...4).contains($0) }) != false,
			network.map({ (0...3).contains($0) }) != false,
			reports.map({ $0 >= 0 }) != false
		else { throw MediaSmokeFailure.invalidPageState }
	}
}

internal enum MediaSmokeInput {
	/// The fixture's fixed Start button occupies CSS points (16, 286, 200, 44).
	internal static func startPoint(
		currentURL: URL?,
		expectedURL: URL,
		bounds: CGRect,
		isFlipped: Bool
	) throws -> CGPoint {
		let fixtureCase = expectedURL.deletingPathExtension().lastPathComponent

		guard
			currentURL == expectedURL,
			let parts = URLComponents(url: expectedURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			(1...65535).contains(parts.port ?? 0),
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil,
			["normal", "second", "late", "remove", "private", "automatic", "automatic-delayed", "manual-only", "portrait"].contains(fixtureCase),
			parts.path == "/media/\(expectedURL.lastPathComponent)",
			expectedURL.pathExtension == "html"
		else { throw MediaSmokeFailure.invalidFixture }

		guard
			bounds.origin == .zero,
			bounds.width.isFinite,
			bounds.height.isFinite,
			(480...2048).contains(bounds.width),
			(330...2048).contains(bounds.height)
		else { throw MediaSmokeFailure.invalidFixture }

		return .init(x: 116, y: isFlipped ? 308 : bounds.height - 308)
	}
}

internal enum MediaSmokeFixture {
	internal static let sentinel: String = "Arx media disposable fixture v1\n"

	internal static func validate(
		root: URL,
		profile: URL,
		baseURL: URL
	) throws {
		guard
			root.isFileURL,
			profile.isFileURL,
			root.lastPathComponent.hasPrefix("app-smoke-"),
			profile.standardizedFileURL == root.appendingPathComponent("profile").standardizedFileURL,
			valid(root, kind: S_IFDIR, mode: 0o700),
			valid(profile, kind: S_IFDIR, mode: 0o700),
			profile.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			(1...65535).contains(parts.port ?? 0),
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil,
			parts.path == "/index.html"
		else { throw MediaSmokeFailure.invalidFixture }

		let marker = root.appendingPathComponent(".arx-media-smoke")

		guard
			valid(marker, kind: S_IFREG, mode: 0o600, size: sentinel.utf8.count),
			(try? Data(contentsOf: marker)) == Data(sentinel.utf8)
		else { throw MediaSmokeFailure.invalidFixture }
	}

	private static func valid(
		_ url: URL,
		kind: mode_t,
		mode: mode_t,
		size: Int? = nil
	) -> Bool {
		var info = stat()

		guard
			lstat(url.path, &info) == 0,
			info.st_uid == getuid(),
			info.st_mode & S_IFMT == kind,
			info.st_mode & 0o777 == mode
		else { return false }

		return size.map { info.st_size == $0 } ?? true
	}
}
#endif
