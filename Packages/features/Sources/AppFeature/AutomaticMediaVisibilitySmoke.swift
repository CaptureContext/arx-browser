#if DEBUG
import AppKit
import BrowserCore
import BrowserMediaClient
import BrowserSurfaceClient
import ChromiumBrowserEngine
import Foundation
import SwiftUI
import _ComposableArchitecture

/// Uses disposable sessions and a separate store; it never changes the user's workspace.
@MainActor
internal enum AutomaticMediaVisibilitySmoke {
	internal static func run(
		engine: ChromiumBrowserEngine,
		baseURL: URL,
		profileID: Profile.ID
	) async throws {
		guard
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			(1...65_535).contains(parts.port ?? 0),
			parts.path == "/index.html",
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil
		else { throw Failure.invalidFixture }

		let root = baseURL.deletingLastPathComponent()
		let videoURL = root.appending(path: "media/automatic.html")
		let spareURL = root.appending(path: "media/manual-only.html")
		let video = BrowserCore.Tab(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			restoration: .init(title: "Owned automatic video", url: videoURL)
		)
		let spare = BrowserCore.Tab(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			restoration: .init(title: "Owned spare page", url: spareURL)
		)
		let space = Space(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			name: "Owned media acceptance",
			unpinnedTabs: [video.id, spare.id],
			selectedTabID: video.id
		)
		let organization = BrowserOrganization(
			profiles: [.init(id: profileID, name: "Owned media acceptance")],
			spaces: [space],
			tabs: [video, spare]
		)
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		initial.main.viewer.item.tab = video
		let client = try engine.media()
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine = engine.client
			$0.browserSurface = engine.surface
			$0.browserMedia = client
		}
		let previousWindow = NSApp.keyWindow
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 420),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.title = "Arx owned automatic visibility acceptance"
		let host = NSHostingView(rootView: Host(store: store, surface: engine.surface))
		window.contentView = host
		var pressurePages: [(tab: BrowserCore.Tab, window: NSWindow)] = []
		var phase = "opening"

		defer {
			if phase != "complete" {
				let page = try? evidence(engine: engine, tab: video.id, url: videoURL)
				let source = store.media.visibleSources.first { $0.id.tabID == video.id }
				let visible = source.flatMap { store.mediaSourceVisibility[$0.id] }
				let fields: [String] = [
					"phase=\(phase)",
					"attached=\(engine.isAttached(video.id))",
					"windowVisible=\(window.isVisible)",
					"occluded=\(!window.occlusionState.contains(.visible))",
					"reports=\(store.mediaSurfaces.count)",
					"source=\(source != nil)",
					"visible=\(String(describing: visible))",
					"ready=\(String(describing: page?.ready))",
					"starts=\(String(describing: page?.starts))",
					"playing=\(String(describing: page?.playing))",
					"active=\(String(describing: page?.active))",
					"requests=\(String(describing: page?.requests))",
					"pip=\(String(describing: page?.pip))",
					"entered=\(String(describing: page?.entered))",
					"left=\(String(describing: page?.left))",
					"pauses=\(String(describing: page?.pauses))",
					"error=\(String(describing: page?.error))",
					"failure=\(String(describing: store.media.failure))",
					"pending=\(store.media.pending != nil)",
				]
				let diagnostic = "ARX_MEDIA_VISIBILITY_DIAGNOSTIC "
				+ fields.joined(separator: " ")
				+ "\n"
				FileHandle.standardError.write(Data(diagnostic.utf8))
			}
			store.send(.media(.ui(.dismissed)))
			store.send(.main(.viewer(.suspend)))
			window.contentView = nil
			window.close()
			for page in pressurePages {
				page.window.contentView = nil
				page.window.close()
				engine.client.close(page.tab.id)
			}
			engine.client.close(video.id)
			engine.client.close(spare.id)
			previousWindow?.makeKeyAndOrderFront(nil)
		}

		try await engine.client.open(video)
		try await engine.client.open(spare)

		// Exhaust Chromium's five-tab MRU allowance with genuinely visible owned
		// surfaces. The media source must stay runnable through its own exemption.
		guard
			let screen = NSScreen.main,
			screen.visibleFrame.width >= 660,
			screen.visibleFrame.height >= 600
		else { throw Failure.invalidFixture }

		window.setFrameOrigin(.init(
			x: screen.visibleFrame.minX + 8,
			y: screen.visibleFrame.minY + 8
		))

		for index in 0..<6 {
			let tab = BrowserCore.Tab(
				id: .init(rawValue: UUID()),
				profileID: profileID,
				restoration: .init(title: "Owned visible media peer", url: spareURL)
			)
			let peer = NSWindow(
				contentRect: .init(
					x: screen.visibleFrame.minX + CGFloat(index) * 92,
					y: screen.visibleFrame.maxY - 100,
					width: 84,
					height: 80
				),
				styleMask: [.borderless],
				backing: .buffered,
				defer: false
			)
			peer.isReleasedWhenClosed = false
			peer.ignoresMouseEvents = true
			pressurePages.append((tab, peer))
			try await engine.client.open(tab)
			peer.contentView = NSHostingView(
				rootView: BrowserSurface(tabID: tab.id, client: engine.surface)
					.frame(width: 84, height: 80)
			)
			peer.orderFront(nil)
		}

		window.makeKeyAndOrderFront(nil)
		try await wait {
			pressurePages.allSatisfy { page in
				engine.isAttached(page.tab.id)
				&& page.window.isVisible
				&& page.window.occlusionState.contains(.visible)
			}
		}
		store.send(.configureMedia)
		phase = "source-ready"
		try await wait {
			try evidence(engine: engine, tab: video.id, url: videoURL)?.ready == true
			&& engine.isAttached(video.id)
			&& window.occlusionState.contains(.visible)
		}
		try clickStart(
			window: window,
			host: host,
			currentURL: engine.client.snapshot(video.id)?.navigation.url,
			url: videoURL
		)
		phase = "playing-visible-without-activation"
		try await wait {
			guard
				let state = try evidence(engine: engine, tab: video.id, url: videoURL),
				let source = store.media.visibleSources.first(where: { $0.id.tabID == video.id })
			else { return false }

			return state.playing
			&& state.starts == 1
			&& state.trustedStarts == 1
			&& !state.active
			&& source.supports(.enterAutomaticPictureInPicture)
			&& store.mediaSourceVisibility[source.id] == true
		}
		guard
			let source = store.media.visibleSources.first(where: { $0.id.tabID == video.id }),
			!source.isPrivate
		else { throw Failure.invalidFixture }

		let document = engine.client.snapshot(video.id)?.documentRevision

		// Automatic PiP is on by default for ordinary sites. The per-site opt-out and the
		// Settings toggle each keep it closed when the video's tab is left.
		guard store.settings.automaticPictureInPicture.permits(source)
		else { throw Failure.invalidFixture }

		let gates: [(phase: String, close: AppFeature.Action, reopen: AppFeature.Action)] = [
			(
				"site-opt-out",
				.media(.ui(.setAutomatic(source.id, enabled: false))),
				.media(.ui(.setAutomatic(source.id, enabled: true)))
			),
			(
				"setting-off",
				.settings(.ui(.automaticPictureInPicture(false))),
				.settings(.ui(.automaticPictureInPicture(true)))
			),
		]
		for gate in gates {
			store.send(gate.close)
			phase = gate.phase
			try await wait {
				!store.settings.automaticPictureInPicture.permits(source)
				&& !store.media.automatic.permits(source)
			}
			store.send(.main(.viewer(.show(spare, in: store.main.viewer.activePaneID))))
			try await wait {
				store.main.viewer.item.tab?.id == spare.id
				&& store.mediaSourceVisibility[source.id] == false
			}
			try await Task.sleep(for: .milliseconds(750))
			guard
				let hidden = try evidence(engine: engine, tab: video.id, url: videoURL),
				hidden.requests == 0,
				!hidden.pip,
				store.media.pending == nil,
				!store.media.automaticAttempts.contains(source.id)
			else { throw Failure.unexpectedEntry }

			store.send(.main(.viewer(.show(video, in: store.main.viewer.activePaneID))))
			store.send(gate.reopen)
			try await wait {
				store.main.viewer.item.tab?.id == video.id
				&& store.mediaSourceVisibility[source.id] == true
				&& store.media.automatic.permits(source)
			}
		}
		phase = "opted-in"
		guard try evidence(engine: engine, tab: video.id, url: videoURL)?.requests == 0
		else { throw Failure.unexpectedEntry }

		store.send(.main(.viewer(.show(spare, in: store.main.viewer.activePaneID))))
		phase = "automatic-entry"
		try await wait {
			guard let state = try evidence(engine: engine, tab: video.id, url: videoURL)
			else { return false }

			return store.main.viewer.item.tab?.id == spare.id
			&& store.mediaSourceVisibility[source.id] == false
			&& store.media.pending == nil
			&& store.media.visibleSources.contains(where: { $0.id == source.id && $0.isInPictureInPicture })
			&& state.pip
		}
		try await Task.sleep(for: .milliseconds(250))
		guard
			let entered = try evidence(engine: engine, tab: video.id, url: videoURL),
			pressurePages.count == 6,
			pressurePages.allSatisfy({ $0.window.isVisible && $0.window.occlusionState.contains(.visible) }),
			entered.requests == 1,
			entered.playing,
			store.media.visibleSources.contains(where: { $0.id == source.id && $0.playback == .playing }),
			entered.entryReason == "contentoccluded",
			entered.activeAtRequest == false,
			entered.starts == 1,
			entered.trustedStarts == 1,
			entered.plays == 1,
			entered.pauses == 0,
			entered.error == nil,
			document != nil,
			engine.client.snapshot(video.id)?.documentRevision == document,
			store.media.automaticAttempts.contains(source.id)
		else { throw Failure.unexpectedEntry }

		phase = "complete"
		print("ARX_MEDIA_AUTOMATIC_GATES_SUCCESS")
		print("ARX_MEDIA_VISIBLE_PEERS_AUTOMATIC_SUCCESS")
		print("ARX_MEDIA_VISIBILITY_AUTOMATIC_SUCCESS")
	}

	private static func evidence(
		engine: ChromiumBrowserEngine,
		tab: BrowserCore.Tab.ID,
		url: URL
	) throws -> Evidence? {
		guard
			let navigation = engine.client.snapshot(tab)?.navigation,
			navigation.url == url,
			navigation.errorCode == nil,
			navigation.title.hasPrefix("Arx media {")
		else { return nil }

		return try Evidence(title: navigation.title)
	}

	private static func clickStart(
		window: NSWindow,
		host: NSView,
		currentURL: URL?,
		url: URL
	) throws {
		guard
			window.contentView === host,
			host.window === window,
			window.isVisible,
			window.isKeyWindow,
			NSApp.keyWindow === window,
			window.windowNumber > 0
		else { throw Failure.invalidFixture }

		let point = try MediaSmokeInput.startPoint(
			currentURL: currentURL,
			expectedURL: url,
			bounds: host.bounds,
			isFlipped: host.isFlipped
		)
		let timestamp = ProcessInfo.processInfo.systemUptime
		for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
			let event = NSEvent.mouseEvent(
				with: type,
				location: host.convert(point, to: nil),
				modifierFlags: [],
				timestamp: timestamp + Double(index) * 0.001,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: index + 1,
				clickCount: 1,
				pressure: index == 0 ? 1 : 0
			)
			guard let event else { throw Failure.invalidFixture }

			window.sendEvent(event)
		}
	}

	private static func wait(
		file: StaticString = #fileID,
		line: Int = #line,
		function: StaticString = #function,
		_ condition: () throws -> Bool
	) async throws {
		let start = ContinuousClock.now
		let deadline = start.advanced(by: .seconds(15))
		while ContinuousClock.now < deadline {
			try Task.checkCancellation()
			if try condition() { return }
			try await Task.sleep(for: .milliseconds(25))
		}
		throw SmokeDiagnostics.timeout(
			site: "\(file):\(line) \(function)",
			since: start,
			state: "condition still false"
		)
	}

	private struct Host: View {
		internal let store: StoreOf<AppFeature>
		internal let surface: BrowserSurfaceClient

		internal init(
			store: StoreOf<AppFeature>,
			surface: BrowserSurfaceClient
		) {
			self.store = store
			self.surface = surface
		}

		internal var body: some View {
			Group {
				if let tab = store.main.viewer.item.tab {
					BrowserSurface(tabID: tab.id, client: surface)
				}
			}
			.frame(width: 640, height: 420)
			.environment(\.browserSurfaceVisibilityObserver, .init { report in
				store.send(.event(.mediaSurfaceVisibility(store.main.id, report)))
			})
		}
	}

	private struct Evidence: Decodable {
		internal let fixtureCase: String
		internal let ready: Bool
		internal let starts: Int
		internal let trustedStarts: Int
		internal let playing: Bool
		internal let pip: Bool
		internal let plays: Int
		internal let pauses: Int
		internal let entered: Int
		internal let left: Int
		internal let requests: Int
		internal let active: Bool
		internal let activeAtRequest: Bool?
		internal let entryReason: String?
		internal let error: String?

		internal init(title: String) throws {
			guard title.utf8.count <= 2048, title.hasPrefix("Arx media ")
			else { throw Failure.invalidFixture }

			let payload = Data(title.dropFirst("Arx media ".count).utf8)
			self = try JSONDecoder().decode(Self.self, from: payload)
			guard fixtureCase == "automatic" else { throw Failure.invalidFixture }
		}

		private enum CodingKeys: String, CodingKey {
			case fixtureCase = "case"
			case ready
			case starts
			case trustedStarts
			case playing
			case pip
			case plays
			case pauses
			case entered
			case left
			case requests
			case active
			case activeAtRequest
			case entryReason
			case error
		}
	}

	private enum Failure: Error {
		case invalidFixture
		case timedOut
		case unexpectedEntry
	}
}
#endif
