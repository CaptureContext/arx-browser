#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Darwin
import Foundation
import _ComposableArchitecture

/// Real renderer-created, ordinarily published blank children. Only the external
/// runner's fresh protocol fixture arms dialog actions and suppresses OS launch.
@MainActor
internal enum PublishedBlankChildSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		source: BrowserCore.Tab.ID,
		window: NSWindow,
		baseURL: URL,
		privateWindow: @escaping @MainActor (UUID) -> NSWindow?
	) async throws {
		guard
			ExternalConsentSmoke.requested,
			let root = ProcessInfo.processInfo.environment["ARX_EXTERNAL_CONSENT_FIXTURE_ROOT"],
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			(1...65535).contains(parts.port ?? 0),
			parts.path == "/index.html",
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil,
			let originalURL = engine.client.snapshot(source)?.navigation.url
		else { throw Failure.invalidFixture }

		let run = Run(
			store: store,
			engine: engine,
			parts: parts,
			receipt: URL(fileURLWithPath: root).appending(path: "external-consent.receipt")
		)
		do {
			for phase in ["blank-http-immediate", "blank-http-delayed"] {
				try await run.exercise(phase, source: source, host: nil, window: window)
			}
			print("ARX_BLANK_CHILD_HTTP_SUCCESS")
			for phase in ["blank-cancel", "blank-accept", "blank-stale", "blank-source-loss", "blank-after-http"] {
				try await run.exercise(phase, source: source, host: nil, window: window)
			}
			print("ARX_BLANK_CHILD_EXTERNAL_SUCCESS")
			try await run.privateContinuation(window: privateWindow)
			try await engine.client.command(source, .navigate(originalURL))
			try await run.wait { engine.client.snapshot(source)?.navigation.url == originalURL
				&& engine.client.snapshot(source)?.navigation.isLoading == false }
		} catch {
			FileHandle.standardError.write(Data("ARX_BLANK_CHILD_PHASE_FAILED: \(run.phase)\n".utf8))
			throw error
		}
	}

	@MainActor
	private final class Run {
		private let store: StoreOf<AppFeature>
		private let engine: ChromiumBrowserEngine
		private let parts: URLComponents
		private let receipt: URL
		private var privateTabs: Set<BrowserCore.Tab.ID> = []
		internal private(set) var phase: String = "startup"

		internal init(
			store: StoreOf<AppFeature>,
			engine: ChromiumBrowserEngine,
			parts: URLComponents,
			receipt: URL
		) {
			self.store = store
			self.engine = engine
			self.parts = parts
			self.receipt = receipt
		}

		internal func exercise(
			_ phase: String,
			source: BrowserCore.Tab.ID,
			host: UUID?,
			window: NSWindow
		) async throws {
			self.phase = phase
			let originalTabs = Set(tabs(host).map(\.id))
			guard
				let profile = tabs(host).first(where: { $0.id == source })?.profileID,
				let view = engine.contentHostFixtureView(source)
			else { throw Failure.missingSource }

			select(source, host: host)
			var destination = parts
			destination.host = "arx-blank-\(UUID().uuidString.lowercased()).localhost"
			destination.path = "/external-consent/\(phase).html"
			let url = try require(destination.url)
			try await engine.client.command(source, .navigate(url))
			try await wait {
				self.engine.client.snapshot(source)?.navigation.title == "Arx Blank source \(phase)"
				&& self.engine.client.snapshot(source)?.navigation.isLoading == false
				&& view.window === window && self.engine.isAttached(source)
			}
			window.makeKeyAndOrderFront(nil)
			engine.surface.focus(source)
			try await wait { window.isKeyWindow }
			try PageConsentSmoke.clickRequest(view: view, window: window)
			try await wait { self.tabs(host).filter { !originalTabs.contains($0.id) }.count == 1 }
			let child = try require(tabs(host).first(where: { !originalTabs.contains($0.id) }))
			guard child.profileID == profile else { throw Failure.crossProfile }
			if host != nil { privateTabs.insert(child.id) }
			try await wait {
				self.selected(host) == child.id && self.engine.isAttached(child.id)
				&& self.engine.contentHostFixtureView(child.id)?.window === window
				&& self.engine.client.snapshot(source)?.isVisibleForCapture == false
				&& (view.window == nil || view.isHiddenOrHasHiddenAncestor || view.visibleRect.isEmpty)
			}
			let childView = try require(engine.contentHostFixtureView(child.id))

			if phase.hasPrefix("blank-http-") || phase == "blank-after-http" {
				try await wait {
					self.engine.client.snapshot(child.id)?.navigation.title == "Arx Blank HTTP \(phase)|\(phase)"
					&& self.engine.client.snapshot(child.id)?.navigation.isLoading == false
				}
				guard engine.client.snapshot(child.id)?.navigation.url?.path == "/external-consent/blank-http-destination.html"
				else { throw Failure.reconstructedChild }
				if phase == "blank-after-http" {
					try await wait { try self.records().contains("published:\(phase):requested") }
					try await Task.sleep(for: .milliseconds(300))
					let finalRecords = try records()
					guard
						!finalRecords.contains("dialog:\(phase):visible"),
						!finalRecords.contains("os-attempt:\(phase):intercepted"),
						engine.client.snapshot(child.id)?.navigation.title == "Arx Blank HTTP \(phase)|\(phase)"
					else { throw Failure.staleAttribution }
				}
			} else {
				try await wait {
					let records = try self.records()
					return records.contains("published:\(phase):requested")
					&& records.contains("dialog:\(phase):visible")
					&& records.contains("published:\(phase):drained")
				}
				if phase == "blank-stale" {
					try await wait { self.engine.client.snapshot(child.id)?.navigation.title == "Arx External destination" }
				} else if phase == "blank-source-loss" {
					try await wait { self.engine.client.snapshot(source)?.navigation.title == "Arx External destination" }
				}
			}
			guard
				engine.contentHostFixtureView(child.id) === childView,
				engine.client.snapshot(child.id) != nil,
				selected(host) == child.id,
				Set(tabs(host).map(\.id)) == originalTabs.union([child.id])
			else { throw Failure.publishedChildWasDestroyed }

			// Cleanup is a production close action for this exact fixture-owned tab.
			closeSelected(host)
			try await wait { !self.tabs(host).contains(where: { $0.id == child.id })
				&& self.engine.client.snapshot(child.id) == nil }
			guard Set(tabs(host).map(\.id)) == originalTabs else { throw Failure.unexpectedTabs }
			select(source, host: host)
			try await wait { self.engine.isAttached(source) && view.window === window }
		}

		internal func privateContinuation(window: @MainActor (UUID) -> NSWindow?) async throws {
			phase = "blank-private"
			let ordinary = store.workspace
			let profile = Profile.ID(rawValue: UUID())
			let host = UUID()
			let space = Space.ID(rawValue: UUID())
			let source = BrowserCore.Tab(
				id: .init(rawValue: UUID()),
				profileID: profile,
				restoration: .init(title: "Private blank source", url: try require(parts.url))
			)
			try engine.client.preparePrivateProfile(profile, nil)
			store.send(.event(.privateWindowReady(host, profile, space, linkedOpener: nil)))
			let organization = BrowserOrganization(
				profiles: [.init(id: profile, name: "Private blank fixture")],
				spaces: [
					.init(
						id: space,
						profileID: profile,
						name: "Private blank fixture",
						unpinnedTabs: [source.id],
						selectedTabID: source.id
					),
				],
				tabs: [source]
			)
			store.send(.windows(.element(id: host, action: .reconcile(organization))))

			// Reconciliation keeps the window's own selection; present the source.
			let paneID = try require(store.windows[id: host]?.viewer.activePaneID)
			store.send(.windows(.element(id: host, action: .present(source.id, in: paneID))))
			store.send(.windows(.element(id: host, action: .commandBar(.ui(.dismissed)))))
			try await wait { self.engine.isAttached(source.id) && window(host) != nil }
			let nativeWindow = try require(window(host))
			try await exercise("blank-private", source: source.id, host: host, window: nativeWindow)
			guard
				PublishedBlankChildSmoke.ordinaryShape(store.workspace) == PublishedBlankChildSmoke.ordinaryShape(ordinary),
				store.windows[id: host]?.isPrivate == true,
				store.history.snapshots[profile] == nil,
				store.history.queuedVisits[profile] == nil,
				store.history.lastNavigation[source.id] == nil,
				privateTabs.allSatisfy({ store.history.lastNavigation[$0] == nil })
			else { throw Failure.privatePersistence }

			store.send(.ui(.requestClosePrivateWindow(host)))
			try await wait { self.store.windows[id: host] == nil && self.engine.client.snapshot(source.id) == nil }
			guard
				PublishedBlankChildSmoke.ordinaryShape(store.workspace) == PublishedBlankChildSmoke.ordinaryShape(ordinary)
			else { throw Failure.privatePersistence }
			print("ARX_BLANK_CHILD_PRIVATE_SUCCESS")
		}

		internal func wait(_ condition: @MainActor () throws -> Bool) async throws {
			let deadline = ContinuousClock.now + .seconds(15)
			while try !condition() {
				guard ContinuousClock.now < deadline else { throw Failure.timedOut }
				try await Task.sleep(for: .milliseconds(25))
			}
		}

		private func tabs(_ host: UUID?) -> [BrowserCore.Tab] {
			if let host { return Array(store.windows[id: host]?.sidebar.organization.tabs ?? []) }
			return Array(store.workspace.tabs)
		}

		private func selected(_ host: UUID?) -> BrowserCore.Tab.ID? {
			if let host { return store.windows[id: host]?.viewer.item.tab?.id }
			return store.main.viewer.item.tab?.id
		}

		private func select(
			_ tab: BrowserCore.Tab.ID,
			host: UUID?
		) {
			if let host {
				store.send(.windows(.element(id: host, action: .sidebar(.ui(.sidebar(.select(.tab(tab.rawValue))))))))
			} else {
				store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(tab.rawValue)))))))
			}
		}

		private func closeSelected(_ host: UUID?) {
			if let host { store.send(.windows(.element(id: host, action: .ui(.closeTab)))) }
			else { store.send(.main(.ui(.closeTab))) }
		}

		private func records() throws -> Set<String> {
			let descriptor = open(receipt.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
			guard descriptor >= 0 else { throw Failure.invalidFixture }
			let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
			var info = stat()
			guard
				fstat(descriptor, &info) == 0,
				info.st_mode & S_IFMT == S_IFREG,
				info.st_uid == getuid(),
				info.st_mode & 0o777 == 0o600,
				(1...16384).contains(info.st_size),
				let data = try file.read(upToCount: 16385),
				data.count <= 16384,
				let text = String(data: data, encoding: .utf8)
			else { throw Failure.invalidFixture }
			try file.close()
			let records = Set(text.split(separator: "\n").map(String.init))
			guard !records.contains(where: { $0.hasPrefix("FAIL:") }) else { throw Failure.nativeFixture }
			return records
		}
	}

	/// Ordinary tabs keep updating their restored titles while their pages
	/// settle. Private work must not add, move or reassign ordinary state.
	private static func ordinaryShape(_ organization: BrowserOrganization) -> [String] {
		organization.tabs.map { "\($0.id.rawValue):\($0.profileID.rawValue)" }
			+ organization.profiles.map { "\($0.id.rawValue):\($0.favorites)" }
			+ organization.spaces.map { "\($0.id.rawValue):\($0.profileID.rawValue):\($0.savedItems):\($0.unpinnedTabs)" }
	}

	private static func require<T>(_ value: T?) throws -> T {
		guard let value else { throw Failure.missingSource }
		return value
	}

	private enum Failure: Error {
		case invalidFixture, missingSource, crossProfile, reconstructedChild, staleAttribution
		case publishedChildWasDestroyed, unexpectedTabs, privatePersistence, timedOut, nativeFixture
	}
}
#endif
