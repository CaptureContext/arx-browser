import AppUI
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import DownloadsFeature
import Foundation
import PageReaderClient
import _ComposableArchitecture

@Reducer
public struct ViewerItemFeature {
	@ObservableState
	public struct State: Equatable {
		public var tab: BrowserCore.Tab?
		public var navigation: BrowserNavigation
		public var failure: String?

		/// Transfers this tab's pages started, from the downloads queue (DEV-1116).
		public var tabDownloads: [BrowserDownload]

		/// The shown transfer once it left the downloads list (DEV-1116), and its last record when
		/// this item saw one.
		public var removedDownloadID: BrowserDownload.ID?
		public var removedDownload: BrowserDownload?

		/// Why the Downloading page's last action didn't work, such as a file that couldn't open.
		public var downloadMessage: String?

		/// The live transfer the tab's navigation became while it has no page (DEV-1116).
		public var download: BrowserDownload? {
			navigation.download.flatMap { download in tabDownloads.first { $0.id == download.id } }
		}

		public var generation: Int

		/// Whether this item started observing `tab` and hasn't been suspended or cleared since.
		/// A space switch keeps such a pane as it is instead of showing its page again.
		public var isObserving: Bool

		/// The newest history selection. Only its effect may navigate.
		public var historySelection: Int

		/// The find bar's text while it's open.
		public var findQuery: String?

		/// Use Selection for Find keeps its text without opening the find bar.
		public var findSeed: String?

		/// Counts ⌘F: each one focuses the find field, and on a bar that's already open selects its
		/// text, wherever focus had gone, as Safari and Chrome do (DEV-1222).
		public var findFocusRequests: Int

		/// The page's zoom as a percentage, shown briefly after a zoom command (DEV-726).
		public var zoomBadge: Int?

		/// The main-frame document reading mode and the article check are about (DEV-1065), kept
		/// while the same tab is shown again; 0 until the engine says.
		public var document: UInt64

		/// DEV-1226: the main-frame document that is the engine's own error page for a failed
		/// navigation, which shows the failure and a Reload button itself, so Arx's generic card
		/// doesn't; 0 for none. Kept while the same tab is shown again, as `document` is.
		public var engineErrorDocument: UInt64

		/// DEV-1009: the hang the person chose to wait on; a later one asks again.
		public var waitedHang: UInt32

		/// DEV-1009: the page stopped answering, and the person hasn't chosen to wait on this hang.
		public var asksAboutHang: Bool {
			failure == nil && navigation.isUnresponsive && navigation.unresponsive != waitedHang
		}

		/// Reading mode laid over the page while it's open (DEV-1028).
		public var reader: ReaderOverlay.Phase?

		/// While reading mode is open, the Find bar searches its article (DEV-1066): the latest
		/// request, and the article's matches for it.
		public var readerFind: ReaderFind
		public var readerFindResult: BrowserNavigation.FindResult?

		/// The page looks like it has an article, so the address offers reading mode.
		public var isReadable: Bool

		/// The page last checked for an article, without its fragment: each page is checked once.
		public var readabilityChecked: String?

		/// The page whose article check has answered, without its fragment: until it does, the
		/// URL bar holds the room of its page button (DEV-1254).
		public var readabilityAnswered: String?

		/// The sidebar URL bar's page button, by `URLBarPageButton`'s rule (DEV-1254).
		public var urlBarPageButton: URLBarPageButton?

		public init(
			tab: BrowserCore.Tab? = nil,
			navigation: BrowserNavigation = .init(),
			failure: String? = nil,
			generation: Int = 0,
			historySelection: Int = 0
		) {
			self.tab = tab
			self.navigation = navigation
			self.failure = failure
			self.tabDownloads = []
			self.removedDownloadID = nil
			self.removedDownload = nil
			self.downloadMessage = nil
			self.generation = generation
			self.isObserving = false
			self.historySelection = historySelection
			self.findQuery = nil
			self.findSeed = nil
			self.findFocusRequests = 0
			self.zoomBadge = nil
			self.waitedHang = 0
			self.reader = nil
			self.readerFind = .init()
			self.readerFindResult = nil
			self.isReadable = false
			self.readabilityChecked = nil
			self.readabilityAnswered = nil
			self.urlBarPageButton = nil
			self.document = 0
			self.engineErrorDocument = 0
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)
		case show(BrowserCore.Tab?)
		case suspend

		@CasePathable
		public enum UI: Sendable {
			case command(BrowserEngineClient.Command)
			case selectHistory(
				tabID: BrowserCore.Tab.ID,
				generation: Int,
				history: [BrowserNavigation.Entry],
				entryID: Int
			)
			case retry

			/// DEV-1009: leaves a page that stopped answering; the engine checks it again.
			case waitForPage

			/// Opens the suggested `http` address of a loopback `https` page whose server speaks plain HTTP.
			case openPlainHTTP
			case findPresented
			case findChanged(String)
			case findSeeded(String)
			case findStepped(forward: Bool)
			case findDismissed

			/// A button of the Downloading page (DEV-1116).
			case download(BrowserDownloadingPage.Action)

			/// Opens reading mode, or closes it when it's open (DEV-1028).
			case readerToggled
			case readerClosed

			/// A link in the article: reading mode closes and the page follows it.
			case readerLinkOpened(URL)

			/// The article's matches for the Find request with this serial (DEV-1066).
			case readerFound(serial: UInt64, BrowserNavigation.FindResult?)
		}

		@CasePathable
		public enum Event: Sendable {
			case navigation(BrowserCore.Tab.ID, Int, BrowserNavigation)
			case failed(BrowserCore.Tab.ID, Int, String)
			case historySelectionStarted(BrowserCore.Tab.ID, Int, selection: Int)

			/// A zoom command left the page at this factor.
			case zoomed(BrowserCore.Tab.ID, Int, factor: Double)
			case zoomBadgeExpired

			/// The tab's transfers changed in the downloads queue (DEV-1116).
			case downloads(BrowserCore.Tab.ID, Int, [BrowserDownload])

			/// The tab's transfers, read from the queue right after a navigation named one this
			/// item hadn't seen: one missing from it was removed from the list.
			case downloadsRead(BrowserCore.Tab.ID, Int, [BrowserDownload])

			/// A Downloading page action failed, with the reason to show.
			case downloadActionFailed(BrowserCore.Tab.ID, Int, String)

			/// Whether the tab's page, at this address, looks like it has an article.
			case readabilityChecked(BrowserCore.Tab.ID, URL, document: UInt64, Bool)

			/// The article read from the tab's page at this address, or nil when it has none.
			case articleRead(BrowserCore.Tab.ID, URL, ReaderArticle?)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case navigation(BrowserCore.Tab.ID, BrowserNavigation)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.browserDownloads)
	private var downloads

	@Dependency(\.pageReader)
	private var pageReader

	/// How long after a page loads it's checked for an article, so its own scripts can settle.
	public static let readabilityDelay: Duration = .milliseconds(500)

	/// How long the zoom badge stays after the last zoom command.
	public static let zoomBadgeDuration: Duration = .milliseconds(1500)

	private enum Cancellation: Hashable {
		/// Every observation of this item, cancelled before a newer `show` or `suspend`.
		case events

		/// One observation epoch, so a stale observation can be stopped without touching a newer one.
		case observation(Int)

		/// Every history selection of this item, cancelled before a newer selection, `show` or `suspend`.
		case history

		/// One history selection, so a stale selection can be stopped without touching a newer one.
		case historySelection(Int)

		/// The zoom badge's timer; each zoom command restarts it.
		case zoomBadge

		/// Checking the page for an article, and reading it for reading mode.
		case readability
		case reader
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.show) { state, tab in

			// Hang numbers are a page's own: a Wait never carries over to another page.
			state.waitedHang = 0
			var stopsReading: Effect<Action> = .none
			if tab?.id != state.tab?.id {
				state.findQuery = nil
				state.findSeed = nil
				Self.closeReader(&state)
				Self.forgetReadability(&state)
				state.document = 0
				state.engineErrorDocument = 0
				stopsReading = .merge(.cancel(id: Cancellation.readability), .cancel(id: Cancellation.reader))
			}
			state.zoomBadge = nil
			guard state.generation < Int.max else {
				guard tab == nil else { return .none }
				state.isObserving = false
				state.tab = nil
				state.navigation = .init()
				state.failure = nil
				state.tabDownloads = []
				state.removedDownloadID = nil
				state.removedDownload = nil
				state.downloadMessage = nil
				return .merge(.cancel(id: Cancellation.events), .cancel(id: Cancellation.history))
			}
			state.tab = tab
			state.navigation = .init(
				url: tab?.restoration.url,
				title: tab?.restoration.title ?? ""
			)
			state.failure = nil
			state.tabDownloads = []
			state.removedDownloadID = nil
			state.removedDownload = nil
			state.downloadMessage = nil
			state.generation += 1
			state.isObserving = tab != nil
			guard let tab else {
				return .merge(
					.cancel(id: Cancellation.events),
					.cancel(id: Cancellation.history)
				)
			}
			let generation = state.generation

			// A chat tab (DEV-761) shows the profile's chat, not a page: nothing to load.
			guard !tab.isChat else {
				return .merge(
					.cancel(id: Cancellation.events),
					.cancel(id: Cancellation.history)
				)
			}

			let observation: Effect<Action> = .run { [engine] send in
				let events = await engine.events(tab.id)
				do {
					try Task.checkCancellation()
					try await engine.open(tab)
					for await navigation in events {
						try Task.checkCancellation()
						await send(.event(.navigation(tab.id, generation, navigation)))
					}
				} catch is CancellationError {
					return
				} catch {
					await send(.event(.failed(tab.id, generation, String(describing: error))))
				}
			}
			.cancellable(id: Cancellation.observation(generation))
			.cancellable(id: Cancellation.events)

			// DEV-1116: a navigation that became a download shows the transfer; only this tab's
			// transfers reach the reducer, and only when they change.
			// The first queue always reaches the reducer, so an observation that registered after a
			// newer show is stopped by its own generation, as the navigation observation is.
			let transfers: Effect<Action> = .run { [downloads] send in
				var last: [BrowserDownload]?
				for await queue in await downloads.events() {
					let current = Self.transfers(of: tab.id, in: queue)
					guard current != last else { continue }
					last = current
					await send(.event(.downloads(tab.id, generation, current)))
				}
			}
			.cancellable(id: Cancellation.observation(generation))
			.cancellable(id: Cancellation.events)

			// `cancelInFlight` cancels when the effect's task registers, which happens off the
			// main actor. Back-to-back shows can register out of order, so an older observation
			// would cancel this one and every event for the current generation would be dropped.
			// Cancel synchronously in reducer order instead; an older observation that registers
			// later is stopped by its first stale event.
			return .concatenate(.cancel(id: Cancellation.events), .merge(observation, transfers))
				.merge(with: .cancel(id: Cancellation.history))
				.merge(with: stopsReading)
		}

		Pullback(\.suspend) { state in
			state.zoomBadge = nil
			state.isObserving = false
			if state.generation < Int.max {
				state.generation += 1
			} else {
				state.tab = nil
			}
			return .merge(.cancel(id: Cancellation.events), .cancel(id: Cancellation.history))
		}

		Pullback(\.event.navigation) { state, value in
			let (id, generation, navigation) = value
			guard state.generation == generation
			else { return .cancel(id: Cancellation.observation(generation)) }

			guard state.tab?.id == id else { return .none }

			// Another page, or a new document at the same address (a reload, Arx's, the page's own
			// or AppleScript's, DEV-1065): reading mode was about the one before it. Moving to a
			// fragment keeps it, and so does a frame in the page loading.
			let newDocument = navigation.document != 0 && state.document != 0
			&& navigation.document != state.document
			var reading: Effect<Action> = .none
			if Self.page(navigation.url) != Self.page(state.navigation.url) || newDocument {
				Self.closeReader(&state)
				Self.forgetReadability(&state)
				reading = .merge(.cancel(id: Cancellation.readability), .cancel(id: Cancellation.reader))
			}
			let previousDocument = state.document
			if navigation.document != 0 { state.document = navigation.document }
			state.navigation = navigation
			state.failure = Self.failure(of: navigation, after: previousDocument, &state.engineErrorDocument)

			let delegate: Effect<Action> = .merge(
				.send(.delegate(.navigation(id, navigation))),
				reading,
				checkReadability(&state)
			)

			// DEV-1116: the engine names a transfer only once the queue has it, so the queue read
			// now tells one that's still coming from one removed while this tab wasn't shown.
			guard
				let shown = navigation.download?.id,
				state.download == nil,
				state.removedDownloadID != shown
			else { return delegate }

			return .merge(
				delegate,
				.run { [downloads] send in
					let queue = await downloads.snapshot()
					await send(.event(.downloadsRead(id, generation, Self.transfers(of: id, in: queue))))
				}
			)
		}

		Pullback(\.event.downloads) { state, value in
			let (id, generation, transfers) = value
			guard state.generation == generation
			else { return .cancel(id: Cancellation.observation(generation)) }

			guard state.tab?.id == id else { return .none }

			// Remove from List, Move to Trash or clearing history took the shown transfer away.
			if
				let shown = state.navigation.download?.id,
				let last = state.tabDownloads.first(where: { $0.id == shown }),
				!transfers.contains(where: { $0.id == shown })
			{
				state.removedDownloadID = shown
				state.removedDownload = last
			}
			state.tabDownloads = transfers

			// The queue keeps only its newest update for this item, so it may skip every one that
			// had the shown transfer: a queue without it then can't tell an update that's still
			// coming from a removal. A fresh read can (DEV-1116).
			guard
				let shown = state.navigation.download?.id,
				state.removedDownloadID != shown,
				!transfers.contains(where: { $0.id == shown })
			else { return .none }

			return .run { [downloads] send in
				let queue = await downloads.snapshot()
				await send(.event(.downloadsRead(id, generation, Self.transfers(of: id, in: queue))))
			}
		}

		Pullback(\.event.downloadsRead) { state, value in
			let (id, generation, transfers) = value
			guard state.tab?.id == id, state.generation == generation else { return .none }

			// Only says whether the transfer was removed. The queue's own updates, which may be
			// newer than this read, stay the tab's transfers.
			guard
				let shown = state.navigation.download?.id,
				!transfers.contains(where: { $0.id == shown }),
				!state.tabDownloads.contains(where: { $0.id == shown })
			else { return .none }

			state.removedDownloadID = shown
			return .none
		}

		Pullback(\.event.downloadActionFailed) { state, value in
			let (id, generation, message) = value
			guard state.tab?.id == id, state.generation == generation else { return .none }
			state.downloadMessage = message
			return .none
		}

		Pullback(\.ui.download) { state, action in
			guard let tab = state.tab, let shown = state.navigation.download else { return .none }
			state.downloadMessage = nil
			let generation = state.generation

			switch action {
			case .retry:
				// The address the transfer came from, so its site decides again: a file, or a page.
				let removed = state.removedDownload?.id == shown.id ? state.removedDownload : nil
				let source = state.download?.url ?? removed?.url ?? tab.restoration.url
				return .send(.ui(.command(.navigate(source))))

			case .open, .reveal, .cancel, .resume:
				return .run { [downloads] send in
					do {
						switch action {
						case .open: try await downloads.open(shown.id)
						case .reveal: try await downloads.reveal(shown.id)
						case .cancel: try await downloads.cancel(shown.id)
						case .resume: try await downloads.setPaused(shown.id, false)
						case .retry: break
						}
					} catch {
						await send(.event(.downloadActionFailed(tab.id, generation, downloadFailureMessage(error))))
					}
				}
			}
		}

		Pullback(\.event.readabilityChecked) { state, value in
			let (id, url, document, isReadable) = value
			guard
				state.tab?.id == id,
				Self.page(url) == Self.page(state.navigation.url),
				document == state.document
			else { return .none }
			state.isReadable = isReadable
			state.readabilityAnswered = Self.page(url)
			return .none
		}

		Pullback(\.ui.readerToggled) { state in
			guard state.reader == nil else { return .send(.ui(.readerClosed)) }
			guard
				pageReader.isEnabled(),
				let id = state.tab?.id,
				let url = state.navigation.url,
				Self.isReadableAddress(url),
				state.navigation.engine != .webKit
			else { return .none }

			// The page's Find closes first: in reading mode, Find searches the article.
			var closesFind: Effect<Action> = .none
			if state.findQuery != nil {
				state.findQuery = nil
				closesFind = .send(.ui(.command(.stopFind)))
			}
			state.reader = .reading
			return .merge(
				closesFind,
				.run { [pageReader] send in
					let article = await pageReader.article(id)
					await send(.event(.articleRead(id, url, article)))
				}
				.cancellable(id: Cancellation.reader, cancelInFlight: true)
			)
		}

		Pullback(\.event.articleRead) { state, value in
			let (id, url, article) = value
			guard
				state.tab?.id == id,
				state.reader == .reading,
				Self.page(url) == Self.page(state.navigation.url)
			else { return .none }

			state.reader = article.map { .article($0) } ?? .unavailable
			if article != nil { state.isReadable = true }

			// Find opened while the article was read: with no article, it searches the page.
			guard article == nil, let query = state.findQuery else { return .none }

			let forward = state.readerFind.forward
			Self.closeReader(&state)
			state.findQuery = query
			guard !query.isEmpty else { return .none }
			return .send(.ui(.command(.find(query, forward: forward, newSession: true))))
		}

		Pullback(\.ui.readerClosed) { state in
			Self.closeReader(&state)
			return .cancel(id: Cancellation.reader)
		}

		Pullback(\.ui.readerLinkOpened) { state, url in

			// An email link goes to Mail and leaves the article where it is.
			guard url.scheme?.lowercased() != "mailto" else { return .send(.ui(.command(.navigate(url)))) }
			Self.closeReader(&state)
			return .merge(.cancel(id: Cancellation.reader), .send(.ui(.command(.navigate(url)))))
		}

		Pullback(\.event.failed) { state, value in
			let (id, generation, message) = value
			guard state.tab?.id == id, state.generation == generation else { return .none }
			state.failure = message
			return .none
		}

		Pullback(\.ui.findSeeded) { state, query in
			guard !query.isEmpty else { return .none }
			state.findSeed = query
			guard state.findQuery != nil else { return .none }
			return .send(.ui(.findChanged(query)))
		}

		Pullback(\.ui.findPresented) { state in
			let leaving = Self.leaveReaderWithoutArticle(&state)

			// Open or not, the field takes focus back from the page, the URL bar or the sidebar.
			state.findFocusRequests += 1
			guard state.findQuery == nil else { return leaving }
			state.findQuery = state.findSeed ?? ""
			guard let seed = state.findSeed, !seed.isEmpty else { return leaving }
			return .merge(leaving, .send(.ui(.findChanged(seed))))
		}

		Pullback(\.ui.findChanged) { state, query in

			// Only the open bar's field changes the query. Closing the bar ends its field's editing,
			// and SwiftUI writes the field's text back as it goes; taken, that write opened the bar
			// again, so Escape left it open with its query (DEV-1297).
			guard state.findQuery != nil else { return .none }
			state.findQuery = query
			state.findSeed = nil
			return Self.find(&state, query, forward: true, newSession: true)
		}

		Pullback(\.ui.findStepped) { state, forward in
			let leaving = Self.leaveReaderWithoutArticle(&state)
			if state.findQuery == nil, let seed = state.findSeed {
				state.findQuery = seed
				state.findSeed = nil
				return .merge(leaving, Self.find(&state, seed, forward: forward, newSession: true))
			}
			guard let query = state.findQuery, !query.isEmpty else {
				state.findQuery = state.findQuery ?? ""
				return leaving
			}
			return .merge(leaving, Self.find(&state, query, forward: forward, newSession: false))
		}

		Pullback(\.ui.findDismissed) { state in
			guard state.findQuery != nil else { return .none }
			state.findQuery = nil
			return Self.find(&state, "", forward: true, newSession: true)
		}

		Pullback(\.ui.readerFound) { state, value in
			let (serial, result) = value
			guard
				state.reader != nil,
				state.findQuery != nil,
				serial == state.readerFind.serial
			else { return .none }

			state.readerFindResult = result
			return .none
		}

		Pullback(\.ui.command) { state, command in
			guard let id = state.tab?.id else { return .none }
			let generation = state.generation

			// A reload brings a new document to the same address: the article read from the old
			// one goes, and the new one is checked again once it has loaded (DEV-1028).
			var leaving: Effect<Action> = .none
			switch command {
			case .reload, .reloadBypassingCache, .clearCacheAndReload:
				leaving = .merge(Self.leaveReader(&state), .cancel(id: Cancellation.readability))
				Self.forgetReadability(&state)

			default:
				break
			}

			return .merge(leaving, .run { [engine] send in
				do {
					try await engine.command(id, command)
					guard case .zoom = command, let factor = await engine.pageZoom(id)
					else { return }
					await send(.event(.zoomed(id, generation, factor: factor)))
				} catch {
					// A page the engine can't zoom stays as it is; zoom never replaces the page.
					if case .zoom = command { return }
					await send(.event(.failed(id, generation, String(describing: error))))
				}
			})
		}

		Pullback(\.event.zoomed) { state, value in
			let (id, generation, factor) = value
			guard state.tab?.id == id, state.generation == generation else { return .none }
			state.zoomBadge = PageZoom.percent(factor)
			return .run { [clock] send in
				try await clock.sleep(for: Self.zoomBadgeDuration)
				await send(.event(.zoomBadgeExpired))
			}
			.cancellable(id: Cancellation.zoomBadge, cancelInFlight: true)
		}

		Pullback(\.event.zoomBadgeExpired) { state in
			state.zoomBadge = nil
			return .none
		}

		Pullback(\.ui.selectHistory) { state, selection in
			let (id, generation, history, entryID) = selection
			let isKnownEntry = state.navigation.entries(in: .back).contains(where: { $0.id == entryID })
			|| state.navigation.entries(in: .forward).contains(where: { $0.id == entryID })

			guard
				state.tab?.id == id,
				state.generation == generation,
				state.navigation.history == history,
				isKnownEntry
			else { return .none }

			state.historySelection &+= 1
			let selection = state.historySelection

			let navigation: Effect<Action> = .run { [engine] send in
				do {
					// Both cancellation IDs are registered by now. Report in before touching the engine,
					// so a newer selection reduced before that registration still stops this one.
					await send(.event(.historySelectionStarted(id, generation, selection: selection)))
					try Task.checkCancellation()
					guard
						let snapshot = await engine.snapshot(id),
						snapshot.navigation.history == history
					else { return }
					try await engine.commandAuthorized(
						id,
						snapshot.revision,
						.historyEntry(entryID)
					) { !Task.isCancelled }
				} catch is CancellationError {
					return
				} catch AutomationFailure.staleTarget {
					return
				} catch {
					await send(.event(.failed(id, generation, String(describing: error))))
				}
			}
			.cancellable(id: Cancellation.historySelection(selection))
			.cancellable(id: Cancellation.history)

			// `cancelInFlight` cancels when the effect's task registers, which happens off the
			// main actor, so an older selection could cancel a newer one and navigate instead.
			// Cancel registered selections synchronously in reducer order; one that registers
			// later is stopped when it reports in.
			return .concatenate(.cancel(id: Cancellation.history), navigation)
		}

		Pullback(\.event.historySelectionStarted) { state, value in
			let (id, generation, selection) = value
			guard
				state.tab?.id == id,
				state.generation == generation,
				state.historySelection == selection
			else { return .cancel(id: Cancellation.historySelection(selection)) }

			return .none
		}

		Pullback(\.ui.openPlainHTTP) { state in
			guard case let .localServerExpectsHTTP(httpURL) = state.navigation.failure
			else { return .none }

			return .send(.ui(.command(.navigate(httpURL))))
		}

		Pullback(\.ui.waitForPage) { state in
			guard let tab = state.tab, state.navigation.isUnresponsive else { return .none }
			state.waitedHang = state.navigation.unresponsive
			return .run { [engine] _ in
				_ = await MainActor.run { engine.waitForPage(tab.id) }
			}
		}

		Pullback(\.ui.retry) { state in
			guard let tab = state.tab else { return .none }

			// The shown tab keeps the URL it was opened with, and a pinned tab reopens at its
			// saved destination. Retrying reloads the page that failed instead. `show` then
			// observes the page that is already open.
			var current = tab
			if let url = state.navigation.url, url.scheme != "about" {
				current.restoration.url = url
				current.savedDestination = nil
			}
			return .run { [engine, current] send in
				await engine.close(tab.id)

				// A failed reopen is reported by the observation `show` starts next.
				try? await engine.open(current)
				await send(.show(tab))
			}
		}

		// After every action, so the URL bar's page button follows whatever settled the page.
		Reduce { state, _ in
			state.urlBarPageButton = URLBarPageButton.next(
				after: state.urlBarPageButton,
				Self.urlBarSignals(state, readerIsEnabled: pageReader.isEnabled())
			)
			return .none
		}
	}
}

extension ViewerItemFeature {
	/// The transfers a tab's pages started, ordinary and private.
	private static func transfers(
		of id: BrowserCore.Tab.ID,
		in queue: DownloadQueue
	) -> [BrowserDownload] {
		(queue.downloads + queue.privateDownloads).filter { $0.sourceTabID == id }
	}

	/// The card for `navigation`'s failure, if any. DEV-1226: none over the engine's own error
	/// page, which already says the failure and offers Reload, unless the card says more (a local
	/// development fix, a stopped renderer). `engineErrorDocument` remembers that page's document,
	/// so a later event on it (its title, the tab shown again) doesn't bring the card back.
	internal static func failure(
		of navigation: BrowserNavigation,
		after previousDocument: UInt64,
		_ engineErrorDocument: inout UInt64
	) -> String? {
		guard let failure = navigation.failure else {
			engineErrorDocument = 0
			return nil
		}

		if navigation.committedErrorPage(after: previousDocument) {
			engineErrorDocument = navigation.document
		} else if navigation.document != engineErrorDocument || failure == .rendererStopped {
			engineErrorDocument = 0
		}
		guard engineErrorDocument == 0 || failure.addsToEngineErrorPage
		else { return nil }

		return Self.message(for: failure, rendererEnd: navigation.rendererEnd)
	}

	/// The page failure text. Loopback connection, certificate, and HTTPS-against-HTTP failures
	/// explain local development fixes for every user.
	public static func message(
		for failure: BrowserNavigation.Failure,
		rendererEnd: BrowserNavigation.RendererEnd? = nil
	) -> String {
		switch failure {
		case .rendererStopped:
			rendererEnd.map(Self.message(for:)) ?? String.localized(.appUI.viewer.rendererFailed)
		case let .localServerUnreachable(port):
			String.localized(.appUI.viewer.localServerUnreachable(port))
		case .localCertificateRejected:
			String.localized(.appUI.viewer.localCertificateRejected)
		case .localServerExpectsHTTP:
			String.localized(.appUI.viewer.localServerWithoutEncryption)
		case let .other(code):
			String.localized(.appUI.viewer.navigationFailed(code))
		}
	}
}

extension ViewerItemFeature {
	/// DEV-1016: why the renderer ended, or that it keeps ending, in which case Arx doesn't
	/// reload it by itself.
	public static func message(for end: BrowserNavigation.RendererEnd) -> String {
		if end.isRepeated {
			return end.cause == .outOfMemory || end.cause == .killed
			? String.localized(.appUI.viewer.rendererKeepsRunningOutOfMemory)
			: String.localized(.appUI.viewer.rendererKeepsCrashing)
		}
		if end.isShared, end.cause != .endedByArx { return String.localized(.appUI.viewer.rendererShared) }
		return switch end.cause {
		case .crashed: String.localized(.appUI.viewer.rendererCrashed)
		case .outOfMemory: String.localized(.appUI.viewer.rendererOutOfMemory)
		case .killed: String.localized(.appUI.viewer.rendererKilled)
		case .endedByArx: String.localized(.appUI.viewer.rendererEndedByArx)
		case .launchFailed: String.localized(.appUI.viewer.rendererLaunchFailed)
		case .other: String.localized(.appUI.viewer.rendererFailed)
		}
	}

	/// Once a page has loaded, it's checked for an article, once per page, for the address bar's
	/// reading mode button. Only web pages in the engine are: the engine reads no other.
	private func checkReadability(_ state: inout State) -> Effect<Action> {
		guard
			pageReader.isEnabled(),
			let id = state.tab?.id,
			!state.navigation.isLoading,
			let url = state.navigation.url,
			let page = Self.readabilityPage(of: state.navigation),
			state.readabilityChecked != page
		else { return .none }

		state.readabilityChecked = page
		let document = state.document
		return .run { [clock, pageReader] send in
			try await clock.sleep(for: Self.readabilityDelay)
			let isReadable = await pageReader.isReadable(id)
			await send(.event(.readabilityChecked(id, url, document: document, isReadable)))
		}
		.cancellable(id: Cancellation.readability, cancelInFlight: true)
	}

	/// Closes reading mode, if it's open, for something that acts on the page under it.
	private static func leaveReader(_ state: inout State) -> Effect<Action> {
		guard state.reader != nil else { return .none }
		closeReader(&state)
		return .cancel(id: Cancellation.reader)
	}

	/// Closes reading mode when it found no article, so Find searches the page under it
	/// (DEV-1028); with an article, or while reading one, Find searches that (DEV-1066).
	private static func leaveReaderWithoutArticle(_ state: inout State) -> Effect<Action> {
		state.reader == .unavailable ? leaveReader(&state) : .none
	}

	/// Reading mode goes, and the Find bar searching its article with it.
	private static func closeReader(_ state: inout State) {
		guard state.reader != nil else { return }
		state.reader = nil
		state.findQuery = nil

		// The next reader starts with no search.
		if !state.readerFind.query.isEmpty {
			state.readerFind = state.readerFind.next("", forward: true, newSession: true)
		}
		state.readerFindResult = nil
	}

	/// Searches reading mode's article while it's open (DEV-1066), else the page; an empty query
	/// ends the search.
	private static func find(
		_ state: inout State,
		_ query: String,
		forward: Bool,
		newSession: Bool
	) -> Effect<Action> {
		guard state.reader != nil else {
			let command: BrowserEngineClient.Command = query.isEmpty
			? .stopFind
			: .find(query, forward: forward, newSession: newSession)
			return .send(.ui(.command(command)))
		}
		state.readerFind = state.readerFind.next(query, forward: forward, newSession: newSession)
		if query.isEmpty { state.readerFindResult = nil }
		return .none
	}

	/// The page an article check is for: a web page in the engine that loaded without an error,
	/// without its fragment. Nil for any other, which gets no check.
	internal static func readabilityPage(of navigation: BrowserNavigation) -> String? {
		guard
			navigation.errorCode == nil,
			navigation.engine != .webKit,
			let url = navigation.url,
			isReadableAddress(url)
		else { return nil }

		return page(url)
	}

	/// The article check was about another page, or a document gone: the next one starts over.
	private static func forgetReadability(_ state: inout State) {
		state.isReadable = false
		state.readabilityChecked = nil
		state.readabilityAnswered = nil
	}

	/// What `URLBarPageButton`'s rule reads about the page (DEV-1254). A page is settled once it
	/// has loaded and its article check has answered, or it gets none. Arx has no way to pin an
	/// extension to the URL bar yet, so no pin reaches the rule.
	internal static func urlBarSignals(
		_ state: State,
		readerIsEnabled: Bool
	) -> URLBarPageButton.Signals {
		let checked = readerIsEnabled ? readabilityPage(of: state.navigation) : nil
		let isSettled = !state.navigation.isLoading
		&& (checked == nil || state.readabilityAnswered == checked)

		return .init(
			isReading: state.reader != nil,
			isReadable: state.isReadable,
			isSettled: isSettled,
			pinnedExtensionID: nil
		)
	}

	/// A page's address without its fragment: moving within a page is the same page.
	internal static func page(_ url: URL?) -> String? {
		guard let url else { return nil }
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		components?.fragment = nil
		return components?.string ?? url.absoluteString
	}

	internal static func isReadableAddress(_ url: URL) -> Bool {
		["http", "https"].contains(url.scheme?.lowercased())
	}
}

extension BrowserCommand {
	/// The page's reading mode action for Reading Mode (DEV-1028).
	public var readerAction: ViewerItemFeature.Action.UI? {
		self == .readingMode ? .readerToggled : nil
	}

	/// The page's find action for a find command.
	public var findAction: ViewerItemFeature.Action.UI? {
		switch self {
		case .findInPage: .findPresented
		case .findNext: .findStepped(forward: true)
		case .findPrevious: .findStepped(forward: false)
		default: nil
		}
	}
}
