import AppUI
import BrowserCore
import BrowserWorkspaceClient
import Foundation
import PageTextIndexClient
import SearchSuggestionsClient
import _ComposableArchitecture

@Reducer
public struct CommandBarFeature {
	public enum Intent: Equatable, Sendable {
		case selectTab(BrowserCore.Tab.ID)
		case selectSpace(Space.ID)
		case revealFolder(Folder.ID)
		case open(URL)
		case openHistory(HistorySelection)
		case command(BrowserCommand)

		/// A command listed so it can be found, which can't run here (DEV-1262): a proxy link
		/// command on a page no proxy link rule matches. Choosing it does nothing.
		case disabledCommand(BrowserCommand)
		case newFolder
		case toggleSidebar
		case undo
		case useShortcut(String)

		/// Actions from ⌘K's panel (DEV-810), carried out by the host.
		case openInNewTab(URL)
		case openInPeek(URL)
		case openInLittleArx(URL)
		case copyURL(URL)

		/// The calculator's result (DEV-895). The bar copies it itself and closes.
		case copyText(String)

		/// A Settings row, by its destination's stable ID (DEV-1015). The host opens Settings there.
		case openSettings(String)
	}

	public enum Mode: Equatable, Sendable {
		case newTab
		case currentTab
		case commands

		/// Show History (⌘Y): only the profile's history, newest first (DEV-795).
		case history
	}

	public struct Entry: Equatable, Sendable {
		public var presentation: CommandBarResult
		public var intent: Intent
		public var destination: Destination?

		/// Other words that find it besides its title and subtitle, such as a setting's keywords.
		public var keywords: [String]

		/// How strongly history ranks it (`HistoryFrecency`, DEV-1015): the host lists history in
		/// this order, and the address match prefers the higher score. Zero for anything else.
		public var frecency: Double

		/// A search, not a page: what's typed searched with the profile's search engine, one of its
		/// suggestions, or a site's search through a bang. Its actions say Search, not Open
		/// (DEV-1319).
		public var isSearch: Bool

		public init(
			presentation: CommandBarResult,
			intent: Intent,
			destination: Destination? = nil,
			keywords: [String] = [],
			frecency: Double = 0,
			isSearch: Bool = false
		) {
			self.presentation = presentation
			self.intent = intent
			self.destination = destination
			self.keywords = keywords
			self.frecency = frecency
			self.isSearch = isSearch
		}
	}

	/// The identity described by a frozen result's destination label.
	public enum Destination: Equatable, Sendable {
		case tab(Profile.ID, BrowserOrganization.TabLocation)
		case space(Profile.ID)
		case folder(Space.ID, Profile.ID)
	}

	public struct Execution: Equatable, Sendable {
		public var entry: Entry
		public var mode: Mode
		public var presentationID: Int

		/// The chosen result as listed, when one of its actions replaced its intent (DEV-810), so
		/// the host can check the result still stands: a tab not since moved, a history entry
		/// not since removed.
		public var origin: Entry?

		/// The entry opens an address typed in the field, in full or completed inline, or a
		/// history result taken from it, so its visit counts as typed (DEV-1015).
		public var isTypedAddress: Bool

		public init(
			entry: Entry,
			mode: Mode,
			presentationID: Int,
			origin: Entry? = nil,
			isTypedAddress: Bool = false
		) {
			self.entry = entry
			self.mode = mode
			self.presentationID = presentationID
			self.origin = origin
			self.isTypedAddress = isTypedAddress
		}
	}

	@ObservableState
	public struct State: Equatable {
		public var isPresented: Bool
		public var query: String
		public var selectedID: String?
		public var mode: Mode
		public var candidates: [Entry] {
			didSet {
				addressIndex = .init(candidates)
				matcher = .init()
			}
		}

		/// `candidates`' page addresses, for the page the typed text leads toward.
		public private(set) var addressIndex: AddressMatchIndex

		/// The last filter's results over `candidates`.
		public private(set) var matcher: CandidateMatcher

		/// Helium's bundled !bang list, consulted after `shortcuts`.
		public var bangs: BangCatalog
		public var siteSearchKeyword: String?
		public var prefilledQuery: String?
		public var focusRequest: Int
		public var searchEngine: SearchEngine

		/// Whether typed text may go to the search provider for suggestions. Set by the window
		/// from its profile's setting; never in a private window.
		public var suggestsRemotely: Bool

		/// The provider's suggestions for `suggestionsQuery`, shown only while it's the typed text.
		public var suggestions: [String]
		public var suggestionsQuery: String?
		internal var suggestionRequest: SuggestionRequest?

		/// The profile whose visited pages' words history search reads, or nil, as in a private
		/// window (DEV-1068). Set by the window.
		public var pageTextProfileID: Profile.ID?

		/// The profile whose stored site icons the bangs show, or nil, as in a private window,
		/// whose bangs keep the magnifying glass (DEV-1311). Set by the window.
		public var bangIconProfileID: Profile.ID?

		/// History pages whose words matched `pageTextQuery`, best first, with their passages.
		public var pageTextHits: [PageTextHit]
		public var pageTextQuery: String?
		internal var pageTextRequest: SuggestionRequest?

		/// Whether text + Tab may start a chat. Off in private windows, which have no chat.
		public var isChatAvailable: Bool

		/// What the host can do besides a result's own action, for ⌘K's panel (DEV-810).
		public var actionAvailability: CommandBarFeature.ActionAvailability

		/// ⌘K's actions for the highlighted result, while they're shown.
		public var actionPanel: CommandBarFeature.ActionPanel?

		/// The Command Bar shortcut as the Actions button names it; ⌘K unless rebound, nil
		/// when turned off.
		public var actionsShortcut: String?

		/// The Copy URL shortcut, ⇧⌘C unless rebound: in an open bar the host sends it to the
		/// highlighted result's Copy URL.
		public var copyURLShortcut: String?

		/// The app's other key bindings, Command Bar's included. A result action whose key is one
		/// of them shows and answers to none, so the app's binding always wins (DEV-810).
		public var reservedShortcuts: Set<String>

		/// Bumped when the panel closes, so the field takes focus back without the bar
		/// counting as presented again.
		public var inputRefocusRequest: Int

		/// The user's search shortcuts, shared with Settings and every other command bar.
		@SharedReader
		public var shortcuts: [SearchShortcut]

		/// App-wide behaviour, for Delete in an empty field (DEV-750).
		@SharedReader
		public var general: GeneralPreferences

		/// Whether typed addresses with any scheme open (DEV-1189): the `ARX_SCHEME_ADDRESSES`
		/// feature flag, read once.
		public var opensSchemeAddresses: Bool

		/// The app that opens each scheme typed so far, or nil for none, asked once per scheme.
		public var schemeApps: [String: String?]

		public init(
			isPresented: Bool = false,
			query: String = "",
			selectedID: String? = nil,
			mode: Mode = .newTab,
			candidates: [Entry] = [],
			bangs: BangCatalog = .empty,
			siteSearchKeyword: String? = nil,
			searchEngine: SearchEngine = .google
		) {
			self.isPresented = isPresented
			self.query = query
			self.selectedID = selectedID
			self.mode = mode
			self.candidates = candidates
			self.addressIndex = .init(candidates)
			self.matcher = .init()
			self._shortcuts = SharedReader(.searchShortcuts)
			self._general = SharedReader(.general)
			self.opensSchemeAddresses = FeatureFlag.schemeAddresses.isOn()
			self.schemeApps = [:]
			self.bangs = bangs
			self.siteSearchKeyword = siteSearchKeyword
			self.prefilledQuery = nil
			self.focusRequest = 0
			self.searchEngine = searchEngine
			self.suggestsRemotely = false
			self.suggestions = []
			self.suggestionsQuery = nil
			self.suggestionRequest = nil
			self.pageTextProfileID = nil
			self.bangIconProfileID = nil
			self.pageTextHits = []
			self.pageTextQuery = nil
			self.pageTextRequest = nil
			self.isChatAvailable = false
			self.actionAvailability = .all
			self.actionPanel = nil
			self.actionsShortcut = "⌘K"
			self.copyURLShortcut = "⇧⌘C"
			self.reservedShortcuts = []
			self.inputRefocusRequest = 0
		}

		/// The typed text worth asking the provider about: not a prefilled address, a keyword
		/// search, a `!bang`, anything with a scheme, or a filter for Show History, which never
		/// leaves this Mac.
		internal var suggestionText: String? {
			let text: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
			guard
				suggestsRemotely,
				mode != .history,
				siteSearchKeyword == nil,
				!text.isEmpty,
				!text.hasPrefix("!"),
				query != prefilledQuery,
				!Self.hasScheme(text),
				// An address, typed or completed from history, stays on this Mac.
				Self.destination(text, searchEngine: searchEngine) == searchEngine.url(for: text)
			else { return nil }

			return text
		}

		/// `mailto:…`, `data:…`, `file:/…`, `https://…` and the like: text that starts with a URI
		/// scheme directly followed by more, even if spaces come later. Such text is an address,
		/// never sent for suggestions. `note: milk` isn't one: a space follows its colon.
		public static func hasScheme(_ text: String) -> Bool {
			guard
				let colon = text.firstIndex(of: ":"),
				let first = text.first,
				first.isASCII,
				first.isLetter
			else { return false }

			let afterColon = text.index(after: colon)
			guard afterColon < text.endIndex, !text[afterColon].isWhitespace
			else { return false }

			return text[..<colon].allSatisfy { character in
				character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
			}
		}

		/// At most this many provider suggestions are listed.
		private static let suggestionLimit: Int = 4

		/// Searches for the provider's suggestions for the current text, minus the text itself,
		/// which the search entry already covers.
		private func suggestionEntries(_ text: String) -> [Entry] {
			guard suggestionsQuery == text else { return [] }
			return suggestions
				.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
				.prefix(Self.suggestionLimit)
				.compactMap { suggestion in
					guard let url = searchEngine.url(for: suggestion) else { return nil }
					return Entry(
						presentation: .init(
							id: "suggestion-" + suggestion,
							title: suggestion,
							subtitle: searchEngine.title,
							actionTitle: String.localized(.appUI.command.search),
							symbol: "magnifyingglass"
						),
						intent: .open(url),
						isSearch: true
					)
				}
		}

		/// The text Tab sends to a new chat: typed text that isn't a keyword, a `!bang` or an
		/// unedited address.
		public var chatPrompt: String? {
			let text: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
			guard

				// Show History only filters history; Tab starts nothing there.
				mode != .history,
				isChatAvailable,
				siteSearchKeyword == nil,
				!text.isEmpty,
				!text.hasPrefix("!"),
				query != prefilledQuery
			else { return nil }

			return text
		}

		/// The typed text, when it's an enabled search shortcut's keyword or a `!keyword` that a
		/// shortcut or a bundled bang answers: Tab scopes a site search to it instead of starting a
		/// chat. A bundled bang needs its `!`, since thousands of them are ordinary words such as
		/// "price" or "define" (DEV-1321).
		public var pendingShortcutKeyword: String? {
			let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

			// Show History has no site searches: Return always opens a listed history entry.
			guard mode != .history else { return nil }
			if let bang = typedBangKeyword { return bang }
			guard shortcuts.contains(where: { $0.id == keyword && $0.isEnabled }) else { return nil }
			return keyword
		}

		/// The keyword of a typed `!keyword`, with nothing after it but spaces, when a shortcut or
		/// a bundled bang answers it: `!yt` then Return, Tab or Space enters its scoped search,
		/// as a shortcut's keyword and Tab does (DEV-1321).
		public var typedBangKeyword: String? {
			let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
			guard
				siteSearchKeyword == nil,
				text.hasPrefix("!"),
				!text.contains(where: \.isWhitespace)
			else { return nil }

			return bangs.target(for: String(text.dropFirst()), shortcuts: shortcuts)?.id
		}

		/// Whether the "Ask an agent ⇥" hint shows: exactly when Tab would start a chat (DEV-751).
		public var showsAgentHint: Bool {
			pendingShortcutKeyword == nil && chatPrompt != nil
		}

		/// What can be done with the current page, offered while the address field is empty.
		private static let pageActions: [BrowserCommand] = [
			.reload, .copyURL, .closeTab, .pinTab, .duplicateTab, .newSplit, .toggleLibrary,
		]

		public var pageActionEntries: [Entry] {
			guard mode == .currentTab, siteSearchKeyword == nil, query.isEmpty else { return [] }
			return Self.pageActions.compactMap { action in
				candidates.first { $0.intent == .command(action) }
			}
		}

		/// The site a scoped search searches (`!yt` then Return, or a keyword then Tab), for the
		/// field's icon (DEV-1311). Unlike a bang's row, the field may fetch it from the site when
		/// the profile has none stored; leaving the scope stops that. Nil in a private window.
		public var scopeSiteIcon: SidebarItem.SiteIcon? {
			guard
				let keyword = siteSearchKeyword,
				let target = bangs.target(for: keyword, shortcuts: shortcuts)
			else { return nil }

			return siteIcon(for: target)
		}

		/// The site behind the address being shown, when it is one of the listed pages.
		public var addressSiteIcon: SidebarItem.SiteIcon? {
			guard mode == .currentTab else { return nil }
			return candidates.lazy
				.compactMap(\.presentation.siteIcon)
				.first { $0.pageURL.absoluteString == query }
		}

		public var isAddress: Bool {
			mode == .currentTab && URL(string: query)?.scheme != nil
		}

		/// The result whose page address the query is being typed toward, as in Safari.
		/// It leads the results and is highlighted, so Return opens it, but the field shows only
		/// what was typed: there's no inline completion (DEV-1223).
		///
		/// It needs a typed query: never before the first edit of a prefilled address, while a
		/// keyword search is active or for a `!bang`.
		public var addressMatchID: String? {
			guard

				// Show History lists history only; a match could pick an open tab instead.
				mode != .history,
				siteSearchKeyword == nil,
				query != prefilledQuery
			else { return nil }

			return addressIndex.entryID(matching: query)
		}

		/// The command whose alias is exactly the typed text.
		public var aliasMatch: Entry? {
			guard
				mode != .history,
				query != prefilledQuery,
				siteSearchKeyword == nil,
				let alias = CommandAlias.normalized(query)
			else { return nil }

			return candidates.first { $0.presentation.alias == alias }
		}

		/// The command or Settings row whose title is exactly the typed text, ignoring case and
		/// accents (DEV-1015). It leads, above history and search suggestions, so Return runs it.
		public var exactMatch: Entry? {
			let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
			guard
				mode != .history,
				query != prefilledQuery,
				siteSearchKeyword == nil,
				!text.isEmpty
			else { return nil }

			return candidates.first { entry in
				entry.isCommandOrSetting
				&& entry.presentation.title.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
			}
		}

		public var entries: [Entry] {
			let actions = pageActionEntries
			if !actions.isEmpty { return actions }
			let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
			if mode == .history {
				let listed = historyEntries(text)
				return listed + pageTextEntries(excluding: listed)
			}
			if
				let keyword = siteSearchKeyword,
				let target = bangs.target(for: keyword, shortcuts: shortcuts)
			{
				// Before a query, Return opens the site's front page (DEV-1321).
				let entry = text.isEmpty ? frontPageEntry(target) : shortcutEntry(target, query: text)
				return entry.map { [$0] } ?? []
			}
			if text.hasPrefix("!") { return bangEntries(text) }

			// An `arx://` page is a command, offered only where it's enabled, and so are
			// `chrome://downloads`, `history` and `extensions` (DEV-1189).
			if let command = Self.internalCommand(text) ?? schemeAddressCommand {
				return candidates.filter { $0.intent == .command(command) }
			}

			// Chromium's diagnostic pages, as `arx://` or `chrome://` (DEV-898). Developer pages
			// need developer mode; without it the address offers nothing, not a search.
			if let typed = DiagnosticPage.typed(text) {
				guard typed.page.isAvailable(developerModeEnabled: general.developerModeEnabled)
				else { return [] }

				return [.init(
					presentation: .init(
						id: "diagnostic-" + typed.page.host,
						title: DiagnosticPage.displayAddress(for: typed.url) ?? typed.page.address.absoluteString,
						subtitle: String.localized(.appUI.diagnostics.pageSubtitle),
						actionTitle: String.localized(.appUI.command.action),
						symbol: "stethoscope"
					),
					intent: .open(typed.url)
				)]
			}
			let filter = query == prefilledQuery ? "" : text
			var result: [Entry] = matches(filter)

			// What leads, in this order: a command whose alias is exactly what's typed, so Return
			// runs it; a command or Settings row titled exactly that (DEV-1015); the page the text
			// leads toward, so Return opens it; then the calculator's result and what "new …"
			// can create (DEV-895).
			var leading: [Entry] = []
			if let entry = aliasMatch { leading.append(entry) }
			if let entry = exactMatch, !leading.contains(where: { $0.presentation.id == entry.presentation.id }) {
				leading.append(entry)
			}
			if
				let matchID = addressMatchID,
				let entry = candidates.first(where: { $0.presentation.id == matchID }),
				!leading.contains(where: { $0.presentation.id == entry.presentation.id })
			{
				leading.append(entry)
			}

			// "new" alone lists every target, but after what else it finds, such as New Tab.
			let isBareVerb = QuickCreate.verbs.contains(filter.lowercased())
			let created = filter.isEmpty ? [] : quickCreateEntries(filter)
			if !filter.isEmpty {
				leading += [calculatorEntry(filter)].compactMap { $0 } + (isBareVerb ? [] : created)
			}
			result.removeAll { entry in leading.contains { $0.presentation.id == entry.presentation.id } }

			// Pages found only by their words come after what matched by title or address.
			result += pageTextEntries(excluding: leading + result)

			// ⌘T and the address field list the provider's suggestions first; ⌘K keeps its actions
			// first. A suggestion of exactly what's typed is left out: that's the plain search below.
			let typed = typedEntries(text)
			let suggested = suggestionEntries(text)
			if mode == .commands {
				result.append(contentsOf: suggested)
			} else {
				result.insert(contentsOf: suggested, at: 0)
			}
			if isBareVerb { result += created }

			// DEV-978: opening what's typed, when it's a link, then searching for it, are always
			// among the first 5 rows, right after what leads; in ⌘K after its first commands. A
			// prefilled address isn't typed: it keeps its row at the end, as it was.
			guard !typed.isEmpty, query != prefilledQuery else { return leading + result + typed }

			var rows = leading + result
			let latest = Self.typedRowsWithin - typed.count

			// An address with a scheme opens on Return in every mode, ahead of any match (DEV-1189).
			let position = if schemeAddress != nil {
				leading.count
			} else {
				mode == .commands ? min(rows.count, latest) : min(leading.count, latest)
			}
			rows.insert(contentsOf: typed, at: max(0, position))
			return rows
		}

		/// The typed link and the plain search come within this many rows (DEV-978).
		internal static let typedRowsWithin: Int = 5

		/// Opening what's typed when it's a link, then the profile's search engine searching for
		/// exactly that (DEV-978). Text that isn't a link has only the search. A prefilled address
		/// keeps only its own row.
		private func typedEntries(_ text: String) -> [Entry] {
			guard let url = Self.destination(text, searchEngine: searchEngine) else { return [] }

			// Text that isn't a link has only its search, in this row.
			let isSearch = url == searchEngine.url(for: text)
			let open: Entry = schemeAddress.map { address in
				schemeAddressEntry(text, url: address.url, kind: address.kind)
			} ?? .init(
				presentation: .init(
					id: Self.typedAddressID,
					title: text,
					subtitle: url.absoluteString,
					actionTitle: String.localized(isSearch ? .appUI.command.search : .appUI.command.action),
					symbol: "magnifyingglass"
				),
				intent: .open(url),
				isSearch: isSearch
			)
			guard
				query != prefilledQuery,
				let search = searchEngine.url(for: text),
				search != open.pageURL
			else { return [open] }

			return [
				open,
				.init(
					presentation: .init(
						id: "search-typed",
						title: text,
						subtitle: search.absoluteString,
						actionTitle: String.localized(.appUI.command.search),
						symbol: "magnifyingglass"
					),
					intent: .open(search),
					isSearch: true
				),
			]
		}

		private static let priorityCount: Int = 4

		/// The candidates matching `filter`, before searches, the address match and an alias lead.
		/// Computed once per filter and candidate set, however often `entries` is read (DEV-946).
		private func matches(_ filter: String) -> [Entry] {
			// Read on a cached answer too, so whoever observes `entries` hears when the candidates
			// change: the matcher replaced with them compares equal.
			let candidates = self.candidates
			return matcher.results(for: .init(mode: mode, filter: filter)) {
				// A stable bucket pass instead of a sort, and matching stops once the visible limit
				// is filled.
				var buckets: [[Int]] = .init(repeating: [], count: Self.priorityCount)
				for (index, candidate) in candidates.enumerated() {
					buckets[priority(of: candidate)].append(index)
				}
				let alias = filter.lowercased()
				let matches: (Int) -> Bool = { [mode] index in
					let entry = candidates[index]

					// Settings rows only answer typed text (DEV-1015): there are too many to list.
					guard !filter.isEmpty else { return (mode == .commands && !entry.isSetting) || entry.isDestination }

					return entry.presentation.title.localizedCaseInsensitiveContains(filter)
					|| entry.presentation.subtitle.localizedCaseInsensitiveContains(filter)
					|| entry.presentation.alias?.hasPrefix(alias) == true

					// Keywords can be whole phrases, so a letter or two finds nothing in them, as in
					// Settings' own search.
					|| (filter.count >= 3 && entry.keywords.contains { $0.localizedCaseInsensitiveContains(filter) })
				}
				return Self.pairingHistoryWithOpenTabs(
					buckets.joined(),
					candidates: candidates,
					limit: filter.isEmpty ? 8 : 30,
					where: matches
				)
			}
		}

		/// The first `limit` matching entries, in order, except that a history result for a page
		/// open as a tab comes right after that tab (DEV-810): Return on the tab switches to it,
		/// and on the history result opens the page again. Matching stops at the limit.
		private static func pairingHistoryWithOpenTabs(
			_ ordered: some Sequence<Int>,
			candidates: [Entry],
			limit: Int,
			where matches: (Int) -> Bool
		) -> [Entry] {
			let tabURLs: Set<URL> = .init(candidates.lazy.filter(\.isOpenTab).compactMap(\.pageURL))
			var following: [URL: [Int]] = [:]
			if !tabURLs.isEmpty {
				for (index, entry) in candidates.enumerated() where entry.isHistory {
					guard let url = entry.pageURL, tabURLs.contains(url) else { continue }
					following[url, default: []].append(index)
				}
			}

			var result: [Entry] = []
			var listed: Set<String> = []
			for index in ordered {
				guard result.count < limit else { break }
				let entry = candidates[index]
				guard !listed.contains(entry.presentation.id), matches(index) else { continue }

				result.append(entry)
				listed.insert(entry.presentation.id)
				guard
					entry.isOpenTab,
					let url = entry.pageURL,
					let history = following.removeValue(forKey: url)
				else { continue }

				for paired in history where result.count < limit {
					let pairedEntry = candidates[paired]
					guard !listed.contains(pairedEntry.presentation.id), matches(paired) else { continue }
					result.append(pairedEntry)
					listed.insert(pairedEntry.presentation.id)
				}
			}
			return result
		}

		/// The history the bar was given, in its order, matching `filter` when there is one.
		private func historyEntries(_ filter: String) -> [Entry] {
			// Read on a cached answer too; see `matches(_:)`.
			let candidates = self.candidates
			return matcher.results(for: .init(mode: .history, filter: filter)) {
				Array(
					candidates.lazy
						.filter(\.isHistory)
						.filter { entry in
							filter.isEmpty
							|| entry.presentation.title.localizedCaseInsensitiveContains(filter)
							|| entry.presentation.subtitle.localizedCaseInsensitiveContains(filter)
						}
						.prefix(Self.historyLimit)
				)
			}
		}

		private static let historyLimit: Int = 50

		/// At most this many history pages found only by their words are listed.
		public static let pageTextLimit: Int = 5

		/// The typed text history's page text is searched for: three characters or more, and not
		/// an address the bar was opened with (DEV-1068).
		internal var pageTextFilter: String? {
			guard query != prefilledQuery, actionPanel == nil else { return nil }
			let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
			return text.count >= 3 ? text : nil
		}

		/// History pages found only by their words (DEV-1068), best first by `HistoryFrecency`,
		/// each with the passage that matched as its subtitle. Pages already listed aren't again.
		private func pageTextEntries(excluding listed: [Entry]) -> [Entry] {
			guard let text = pageTextFilter, pageTextQuery == text, !pageTextHits.isEmpty else { return [] }

			let listedIDs = Set(listed.map(\.presentation.id))
			let listedURLs = Set(listed.compactMap(\.pageURL))
			var passages: [URL: String] = [:]
			for hit in pageTextHits where passages[hit.url] == nil { passages[hit.url] = hit.passage }
			let found = candidates.compactMap { entry -> Entry? in
				guard
					entry.isHistory,
					!listedIDs.contains(entry.presentation.id),
					let url = entry.pageURL,
					!listedURLs.contains(url),
					let passage = passages[url]
				else { return nil }

				var entry = entry
				entry.presentation.subtitle = passage
				return entry
			}
			return Array(found.sorted { $0.frecency > $1.frecency }.prefix(Self.pageTextLimit))
		}

		/// Lower values are listed first; results never exceed `priorityCount - 1`.
		private func priority(of entry: Entry) -> Int {
			switch (mode, entry.intent) {
			case (.commands, .command), (.commands, .newFolder), (.commands, .toggleSidebar), (.commands, .undo):
				return 0
			case (.commands, .selectSpace), (.commands, .revealFolder):
				return 1
			case (.commands, _):
				return 2
			case (_, .selectTab):
				return entry.isFavorite ? 1 : 0
			case (_, .open), (_, .openHistory):
				return 2
			default:
				return 3
			}
		}

		/// Bundled bangs suggested after the user's own matching shortcuts.
		private static let bundledSuggestionLimit: Int = 6

		private func shortcutEntry(
			_ target: BangTarget,
			query: String
		) -> Entry? {
			guard let url = try? target.destination(for: query) else { return nil }
			return .init(
				presentation: .init(
					id: "bang-" + target.id,
					title: target.name,
					subtitle: url.absoluteString,
					actionTitle: String.localized(.appUI.search.searchSite),
					symbol: "magnifyingglass",
					siteIcon: siteIcon(for: target),
					siteIconFetch: .storedOnly
				),
				intent: .open(url),
				isSearch: true
			)
		}

		/// A scoped search's row before a query: the site's front page, its homepage if it has one
		/// (DEV-1321).
		private func frontPageEntry(_ target: BangTarget) -> Entry? {
			guard let url = (try? target.destination(for: "")) ?? target.site else { return nil }
			return .init(
				presentation: .init(
					id: "front-" + target.id,
					title: target.name,
					subtitle: url.absoluteString,
					actionTitle: String.localized(.appUI.command.open),
					symbol: "globe",
					siteIcon: siteIcon(for: target),
					siteIconFetch: .storedOnly
				),
				intent: .open(url)
			)
		}

		/// The icon stored for the front page of the site a bang searches, in the window's
		/// profile (DEV-1311). Its rows only read it; the field fetches it once the bang's
		/// scoped search starts (`scopeSiteIcon`).
		private func siteIcon(for target: BangTarget) -> SidebarItem.SiteIcon? {
			guard
				let profileID = bangIconProfileID,
				let site = target.site
			else { return nil }

			return .init(profileID: profileID.rawValue, pageURL: site)
		}

		private func bangEntries(_ text: String) -> [Entry] {
			let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
			let keyword = parts.first.map(String.init)?.lowercased() ?? ""
			let query = parts.count > 1 ? String(parts[1]) : ""
			if let target = bangs.target(for: keyword, shortcuts: shortcuts) {
				// With a query it searches at once; without one, choosing it enters its scoped
				// search, for a shortcut and a bundled bang alike (DEV-1321).
				if !query.isEmpty, let entry = shortcutEntry(target, query: query) { return [entry] }
				return [.init(
					presentation: .init(
						id: "use-" + target.id,
						title: target.name,
						subtitle: String.localized(.appUI.search.queryRequired),
						actionTitle: String.localized(.appUI.search.searchSite),
						symbol: "magnifyingglass",
						siteIcon: siteIcon(for: target),
						siteIconFetch: .storedOnly
					),
					intent: .useShortcut(target.id)
				)]
			}
			let owned: [BangTarget] = shortcuts
				.filter { $0.isEnabled && $0.id.hasPrefix(keyword) }
				.map { BangTarget.shortcut($0) }
			let bundled: [BangTarget] = bangs
				.matches(prefix: keyword, limit: Self.bundledSuggestionLimit + shortcuts.count)
				.filter { match in !shortcuts.contains { $0.id == match.keyword } }
				.prefix(Self.bundledSuggestionLimit)
				.map { BangTarget.bundled(keyword: $0.keyword, $0.bang) }
			var entries = (owned + bundled).map { target in
				Entry(
					presentation: .init(
						id: "use-" + target.id,
						title: "!" + target.keyword + " · " + target.name,
						actionTitle: String.localized(.appUI.search.searchSite),
						symbol: "magnifyingglass",
						siteIcon: siteIcon(for: target),
						siteIconFetch: .storedOnly
					),
					intent: .useShortcut(target.id)
				)
			}
			if let url = Self.destination(text, searchEngine: searchEngine) {
				entries.append(.init(
					presentation: .init(
						id: "search-original",
						title: String.localized(.appUI.search.original),
						subtitle: String.localized(.appUI.search.unknown),
						actionTitle: String.localized(.appUI.command.search),
						symbol: "magnifyingglass"
					),
					intent: .open(url),
					isSearch: true
				))
			}
			return entries
		}

		/// Arx's own pages, typed as addresses: `arx://extensions` (DEV-633).
		public static func internalCommand(_ text: String) -> BrowserCommand? {
			guard
				let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
				components.scheme?.lowercased() == "arx",
				["", "/"].contains(components.path),
				components.query == nil,
				components.fragment == nil
			else { return nil }

			return switch components.host?.lowercased() {
			case "extensions": .extensions
			default: nil
			}
		}

		public static func destination(
			_ text: String,
			searchEngine: SearchEngine = .google
		) -> URL? {
			guard !text.isEmpty else { return nil }
			if let url = URL(string: text), isWebURL(url) { return url }

			// DEV-978: `localhost`, with a port or a path, is a local server, which speaks plain HTTP,
			// whatever dots its path has.
			if
				Self.isLocalhost(text),
				let url = URL(string: "http://" + text),
				url.host()?.lowercased() == "localhost"
			{
				return url
			}

			let looksLikeHost = text.contains(".")
			&& !text.contains(where: \.isWhitespace)
			&& !text.contains("://")

			if looksLikeHost, let url = URL(string: "https://" + text), url.host() != nil { return url }
			return searchEngine.url(for: text)
		}

		/// Takes the app's key bindings: the Actions and Copy URL keys, and every other command's
		/// key as reserved, so the app's own binding always wins.
		public mutating func useShortcuts(_ bindings: [ShortcutBinding]) {
			actionsShortcut = bindings.shortcut(for: .commandBar)?.display
			copyURLShortcut = bindings.shortcut(for: .copyURL)?.display
			reservedShortcuts = Set(
				BrowserCommand.allCases
					.filter { $0 != .copyURL }
					.compactMap { bindings.shortcut(for: $0)?.display }
			)
		}

		/// `localhost`, `localhost:3000` or `localhost/path`, in any case, with nothing before it.
		private static func isLocalhost(_ text: String) -> Bool {
			let lowered = text.lowercased()
			guard lowered.hasPrefix("localhost"), !text.contains(where: \.isWhitespace) else { return false }

			let rest = lowered.dropFirst("localhost".count)
			return rest.isEmpty || rest.hasPrefix(":") || rest.hasPrefix("/")
		}

		private static func isWebURL(_ url: URL) -> Bool {
			["https", "http"].contains(url.scheme ?? "") && url.host() != nil
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)
		case present(Mode, String, [Entry])

		/// The window's profile allows or stops remote suggestions. Stopping drops any shown
		/// and cancels a pending request, even while the bar is open.
		case allowSuggestions(Bool)
		case useSearchEngine(SearchEngine)

		/// The window closed the bar without going through it: cancels a request not yet sent.
		case stopSuggestions

		@CasePathable
		public enum UI: Sendable {
			case queryChanged(String)
			case highlighted(String?)
			case selected(String)
			case dismissed
			case tabPressed

			/// ⌫ in an already-empty field, outside text composition: removes a search scope,
			/// then closes the bar like Esc when the setting allows it.
			case deletedWhenEmpty

			/// ⌘K or the Actions button while the bar is open: shows or hides the highlighted
			/// result's actions (DEV-810).
			case actionsToggled
			case actionQueryChanged(String)
			case actionHighlighted(String?)
			case actionSelected(String)

			/// Runs the panel's or the highlighted result's action with this ID: its key pressed
			/// in the bar or the panel, or the host's Copy URL binding.
			case actionRequested(String)

			/// Esc in the panel: closes it and leaves the bar open.
			case actionsDismissed

			/// ⌘-click on a result: what ⌘↩ does with it highlighted (DEV-1319). Open as is while
			/// the typed text can be an address, else the result's Open in New Tab, else nothing.
			case commandClicked(String)
		}

		@CasePathable
		public enum Event: Sendable {
			/// The provider's suggestions for the typed text.
			case suggestionsLoaded(query: String, engine: SearchEngine, [String])

			/// History pages whose words matched the typed text (DEV-1068).
			case pageTextFound(query: String, [PageTextHit])
		}

		@CasePathable
		public enum Delegate: Sendable {
			case execute(Execution)
			case dismissed

			/// Text + Tab: the parent opens the chat panel and sends the text to a new chat.
			case startChat(String)

			/// Delete from History in ⌘K's panel. The bar has already dropped the results;
			/// the parent removes the entries from the profile's history.
			case removeHistory(Profile.ID, BrowsingHistoryRemoval)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.searchSuggestions)
	private var searchSuggestions

	@Dependency(\.pageTextIndex)
	private var pageTextIndex

	@Dependency(\.commandBarClipboard)
	private var clipboard

	@Dependency(\.commandBarSchemeApps)
	private var schemeApps

	private enum Cancellation: Hashable {
		case suggestions
		case pageText
	}

	/// Typing pauses this long before history's page text is searched (DEV-1068).
	public static let pageTextDelay: Duration = .milliseconds(120)

	/// Typing pauses this long before the text goes to the provider.
	public static let suggestionDelay: Duration = .milliseconds(150)

	public init() {}

	/// Asks the provider about the typed text after a short pause, replacing any earlier request.
	private func requestSuggestions(_ state: inout State) -> Effect<Action> {
		state.suggestionRequest?.invalidate()
		state.suggestionRequest = nil
		guard
			searchSuggestions.isAvailable,
			state.searchEngine.suggestionEndpoint != nil,
			let text = state.suggestionText
		else {
			state.suggestions = []
			state.suggestionsQuery = nil
			return .cancel(id: Cancellation.suggestions)
		}

		// The shown suggestions already fit; a request for text typed since is out of date.
		guard text != state.suggestionsQuery else { return .cancel(id: Cancellation.suggestions) }

		let engine = state.searchEngine
		let request = SuggestionRequest()
		state.suggestionRequest = request
		let fetch: Effect<Action> = .run { [searchSuggestions, clock] send in
			try await clock.sleep(for: Self.suggestionDelay)
			guard request.canSend else { return }
			let suggestions = try await searchSuggestions.fetch(text, engine)
			guard request.canSend else { return }
			await send(.event(.suggestionsLoaded(query: text, engine: engine, suggestions)))
		} catch: { _, _ in

			// Suggestions are a convenience: a failed request leaves the list as it is.
		}
		.cancellable(id: Cancellation.suggestions)

		// `cancelInFlight` cancels when the task registers, off the main actor, so an older
		// request could cancel this one and leave the list for older text. Cancel in reducer
		// order instead; an older request that registers late was invalidated above.
		return .concatenate(.cancel(id: Cancellation.suggestions), fetch)
	}

	/// Drops suggestions and cancels a request that hasn't gone out, whenever the bar closes
	/// or stops allowing them.
	private func stopSuggestions(_ state: inout State) -> Effect<Action> {
		state.suggestionRequest?.invalidate()
		state.suggestionRequest = nil
		state.suggestions = []
		state.suggestionsQuery = nil
		return .cancel(id: Cancellation.suggestions)
	}

	/// Searches history's page text for the typed text after a short pause (DEV-1068). An answer
	/// for text typed since is dropped when it arrives.
	private func requestPageText(_ state: inout State) -> Effect<Action> {
		state.pageTextRequest?.invalidate()
		state.pageTextRequest = nil
		guard
			pageTextIndex.isAvailable,
			let profileID = state.pageTextProfileID,
			let text = state.pageTextFilter
		else { return stopPageText(&state) }
		guard text != state.pageTextQuery else { return .cancel(id: Cancellation.pageText) }

		let request = SuggestionRequest()
		state.pageTextRequest = request
		let search: Effect<Action> = .run { [pageTextIndex, clock] send in
			try await clock.sleep(for: Self.pageTextDelay)
			guard request.canSend else { return }
			let hits = await pageTextIndex.search(profileID, text, State.pageTextLimit * 4)
			guard request.canSend else { return }
			await send(.event(.pageTextFound(query: text, hits)))
		}
		.cancellable(id: Cancellation.pageText)

		// Cancelled in reducer order, as suggestions are: an older search registering late
		// can't cancel this one, and was invalidated above.
		return .concatenate(.cancel(id: Cancellation.pageText), search)
	}

	private func stopPageText(_ state: inout State) -> Effect<Action> {
		state.pageTextRequest?.invalidate()
		state.pageTextRequest = nil
		state.pageTextHits = []
		state.pageTextQuery = nil
		return .cancel(id: Cancellation.pageText)
	}

	/// Closes the bar the way Esc does; the parent restores what it covered.
	private func close(_ state: inout State) -> Effect<Action> {
		state.isPresented = false
		state.actionPanel = nil
		return .merge(stopSuggestions(&state), stopPageText(&state), .send(.delegate(.dismissed)))
	}

	public var body: some ReducerOf<Self> {
		Pullback(\.stopSuggestions) { state in
			stopSuggestions(&state)
		}

		Pullback(\.allowSuggestions) { state, isAllowed in
			state.suggestsRemotely = isAllowed
			return isAllowed ? .none : stopSuggestions(&state)
		}

		Pullback(\.useSearchEngine) { state, engine in
			guard state.searchEngine != engine else { return .none }
			state.searchEngine = engine
			let stop = stopSuggestions(&state)
			return .concatenate(stop, requestSuggestions(&state))
		}

		Pullback(\.present) { state, value in

			// A request for the text this presentation replaces must not go out.
			let stop = stopSuggestions(&state)
			(state.mode, state.query, state.candidates) = value
			state.learnSchemeApp(for: state.query, appName: schemeApps.appName)
			state.isPresented = true
			state.actionPanel = nil
			state.prefilledQuery = state.mode == .currentTab ? state.query : nil
			state.focusRequest += 1
			state.siteSearchKeyword = nil
			state.selectedID = state.entries.first?.presentation.id
			return .merge(stop, stopPageText(&state))
		}

		Pullback(\.ui.queryChanged) { state, query in

			// `!yt` then Space enters YouTube's scoped search, as Return and Tab do (DEV-1321).
			if
				state.mode != .history,
				query.last?.isWhitespace == true,
				state.query == query.trimmingCharacters(in: .whitespaces),
				let keyword = state.typedBangKeyword
			{
				state.enterSiteSearchScope(keyword)
				return stopSuggestions(&state)
			}
			state.learnSchemeApp(for: query, appName: schemeApps.appName)
			state.edit(query)
			return .merge(requestSuggestions(&state), requestPageText(&state))
		}

		Pullback(\.event.pageTextFound) { state, value in
			let (query, hits) = value
			guard query == state.pageTextFilter else { return .none }
			state.pageTextHits = hits
			state.pageTextQuery = query
			if state.selectedID == nil { state.selectedID = state.entries.first?.presentation.id }
			return .none
		}

		Pullback(\.event.suggestionsLoaded) { state, value in
			let (query, engine, suggestions) = value
			guard state.isPresented, state.suggestionText == query, state.searchEngine == engine else { return .none }

			state.suggestions = suggestions
			state.suggestionsQuery = query
			if state.selectedID == nil { state.selectedID = state.entries.first?.presentation.id }
			return .none
		}

		Pullback(\.ui.highlighted) { state, id in

			// The panel belongs to the result it opened on; the pointer passing over the
			// list behind it moves nothing.
			guard state.actionPanel == nil else { return .none }
			state.selectedID = id
			return .none
		}

		Pullback(\.ui.tabPressed) { state in

			// Keyword + Tab stays with the user's shortcuts.
			guard let keyword = state.pendingShortcutKeyword else {
				// Any other typed text goes to a new chat.
				guard let prompt = state.chatPrompt
				else { return .none }

				state.isPresented = false
				state.query = ""
				return .merge(stopSuggestions(&state), .send(.delegate(.startChat(prompt))))
			}
			state.enterSiteSearchScope(keyword)
			return stopSuggestions(&state)
		}

		Pullback(\.ui.dismissed) { state in

			// Esc closes the actions first, then the bar.
			if state.closeActionPanel() { return .none }
			if state.removeSiteSearchScope() { return .none }
			return close(&state)
		}

		Pullback(\.ui.deletedWhenEmpty) { state in
			guard
				state.isPresented,
				state.query.isEmpty,
				// The scope goes first, as a chip would, whatever the setting; the next ⌫ closes.
				state.siteSearchKeyword != nil || state.general.closesCommandBarOnEmptyDelete
			else { return .none }

			// Exactly what Esc does, including the cleanup hosts run for `ui.dismissed`,
			// such as closing an empty split pane.
			return .send(.ui(.dismissed))
		}

		Pullback(\.ui.selected) { state, id in
			guard
				state.isPresented,
				let entry = state.entries.first(where: { $0.presentation.id == id })
			else { return .none }
			state.actionPanel = nil
			return run(entry, state: &state)
		}

		Pullback(\.ui.actionsToggled) { state in
			guard state.isPresented else { return .none }
			if state.closeActionPanel() { return .none }

			guard let entry = state.selectedEntry ?? state.entries.first else { return .none }
			state.selectedID = entry.presentation.id
			state.actionPanel = .init(
				entryID: entry.presentation.id,
				selectedID: state.actions(for: entry).first?.id
			)
			return .none
		}

		Pullback(\.ui.actionQueryChanged) { state, query in
			guard state.actionPanel != nil else { return .none }
			state.actionPanel?.query = query
			let actions = state.actionPanelActions
			if !actions.contains(where: { $0.id == state.actionPanel?.selectedID }) {
				state.actionPanel?.selectedID = actions.first?.id
			}
			return .none
		}

		Pullback(\.ui.actionHighlighted) { state, id in
			guard state.actionPanel != nil else { return .none }
			state.actionPanel?.selectedID = id
			return .none
		}

		Pullback(\.ui.actionsDismissed) { state in
			_ = state.closeActionPanel()
			return .none
		}

		Pullback(\.ui.actionSelected) { state, id in

			// Open as is runs exactly what ⌘↩ runs (DEV-1319).
			if id == State.openURLID { return requestAction(id, state: &state) }
			guard
				state.isPresented,
				let entry = state.actionPanelEntry,
				let action = state.actionPanelActions.first(where: { $0.id == id })
			else { return .none }

			return perform(action, on: entry, state: &state)
		}

		// An action's own key, straight from the bar or the panel (DEV-810).
		Pullback(\.ui.actionRequested) { state, id in
			requestAction(id, state: &state)
		}

		Pullback(\.ui.commandClicked) { state, id in
			guard
				state.isPresented,
				state.entries.contains(where: { $0.presentation.id == id })
			else { return .none }

			// The clicked result, not the panel's: as if it were highlighted and ⌘↩ pressed.
			state.actionPanel = nil
			state.selectedID = id
			guard let action = state.actionID(forShortcut: State.Shortcut.newTab) else { return .none }
			return requestAction(action, state: &state)
		}
	}

	/// Runs the action `id` of the panel's or the highlighted result: its key, or ⌘-click.
	private func requestAction(
		_ id: String,
		state: inout State
	) -> Effect<Action> {
		// ⌘↩: what's typed, as an address (DEV-1189), Open as is in the actions (DEV-1319).
		if id == State.openURLID {
			guard
				state.isPresented,
				state.openURLTakesCommandReturn,
				let entry = state.openURLEntry
			else { return .none }

			state.actionPanel = nil
			return run(entry, state: &state)
		}
		guard
			state.isPresented,
			let entry = state.actionPanelEntry ?? state.selectedEntry,
			let action = state.actions(for: entry).first(where: { $0.id == id })
		else { return .none }

		return perform(action, on: entry, state: &state)
	}

	/// Runs one of a result's actions: through the host, or a history removal here.
	private func perform(
		_ action: ResultAction,
		on entry: Entry,
		state: inout State
	) -> Effect<Action> {
		switch action.kind {
		case let .run(intent, destination):
			// The field takes focus back in case the bar stays open, as for a site search.
			_ = state.closeActionPanel()
			var chosen = entry
			chosen.intent = intent
			chosen.destination = destination
			return run(chosen, origin: chosen == entry ? nil : entry, state: &state)

		case let .removeHistory(profileID, removal):
			_ = state.closeActionPanel()
			state.removeResults(removal, profileID: profileID)
			return .send(.delegate(.removeHistory(profileID, removal)))
		}
	}

	/// Carries out a chosen result: a shortcut scopes the field, anything else goes to the host.
	private func run(
		_ entry: Entry,
		origin: Entry? = nil,
		state: inout State
	) -> Effect<Action> {
		// A disabled command stays listed and the bar stays open (DEV-1262).
		if case .disabledCommand = entry.intent { return .none }
		if case let .useShortcut(keyword) = entry.intent {
			state.enterSiteSearchScope(keyword)
			return stopSuggestions(&state)
		}
		if case let .copyText(text) = entry.intent {
			return .merge(
				close(&state),
				.run { [clipboard] _ in await clipboard.copy(text) }
			)
		}

		// What runs must load a page; the result it ran on says whether that was asked for.
		let isTypedAddress = entry.opensPage && state.isTypedAddress(origin ?? entry)
		state.isPresented = false

		return .merge(
			stopSuggestions(&state),
			.send(.delegate(.execute(.init(
				entry: entry,
				mode: state.mode,
				presentationID: state.focusRequest,
				origin: origin,
				isTypedAddress: isTypedAddress
			))))
		)
	}
}

extension CommandBarFeature.State {
	/// Whether `entry` was asked for, as a typed address is (DEV-1015): the typed text's own
	/// link, the page the typed text leads toward, or a history result taken from the field.
	/// A search isn't an address, and a prefilled address wasn't typed. Whether what runs loads
	/// a page is the caller's to check.
	internal func isTypedAddress(_ entry: CommandBarFeature.Entry) -> Bool {
		guard query != prefilledQuery else { return false }
		if entry.isHistory || entry.presentation.id == addressMatchID { return true }

		// ⌘↩'s Open URL opens exactly what's typed (DEV-1189).
		if entry.presentation.id == Self.openURLID { return true }
		guard entry.presentation.id == "destination", case let .open(url) = entry.intent else { return false }

		let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
		return url != searchEngine.url(for: text)
	}

	/// Hides ⌘K's panel and gives the field its focus back. Returns whether it was open.
	fileprivate mutating func closeActionPanel() -> Bool {
		guard actionPanel != nil else { return false }

		actionPanel = nil
		inputRefocusRequest += 1
		return true
	}

	/// Drops results that a history removal took, keeping the highlight in place.
	fileprivate mutating func removeResults(
		_ removal: BrowsingHistoryRemoval,
		profileID: Profile.ID
	) {
		let before = entries
		let index = before.firstIndex { $0.presentation.id == selectedID } ?? 0
		candidates.removeAll { $0.isRemoved(by: removal, profileID: profileID) }
		let after = entries
		guard !after.contains(where: { $0.presentation.id == selectedID }) else { return }

		let remains: (CommandBarFeature.Entry) -> Bool = { entry in
			after.contains { $0.presentation.id == entry.presentation.id }
		}

		// The next result that's left, or else the one before.
		let remaining = before[index...].first(where: remains) ?? before[..<index].last(where: remains)
		selectedID = remaining?.presentation.id ?? after.first?.presentation.id
	}

	/// Leaves a keyword search for the plain field. Returns whether there was one.
	/// Scopes the field to the site `keyword` searches: a shortcut's keyword then Tab, or a
	/// `!keyword` then Return, Tab or Space, or its row chosen (DEV-1321).
	fileprivate mutating func enterSiteSearchScope(_ keyword: String) {
		actionPanel = nil
		siteSearchKeyword = keyword
		query = ""
		prefilledQuery = nil
		selectedID = entries.first?.presentation.id
	}

	fileprivate mutating func removeSiteSearchScope() -> Bool {
		guard siteSearchKeyword != nil else { return false }

		siteSearchKeyword = nil
		query = ""
		selectedID = entries.first?.presentation.id
		return true
	}

	fileprivate mutating func edit(_ query: String) {
		let matched = addressMatchID

		// Typing in the field again changes the results, so the actions for one of them go.
		self.actionPanel = nil
		self.query = query
		self.prefilledQuery = nil

		// An exact alias is highlighted over a page it also starts, so Return runs its command.
		if let alias = aliasMatch {
			self.selectedID = alias.presentation.id
			return
		}

		// So is a command or Settings row titled exactly what's typed (DEV-1015).
		if let exact = exactMatch {
			self.selectedID = exact.presentation.id
			return
		}
		if let matchID = addressMatchID {
			self.selectedID = matchID
			return
		}

		// The calculator's result or a create row leads as soon as it appears (DEV-895), so
		// Return acts on it however the text was typed.
		let entries = self.entries
		if let first = entries.first, first.isInstant {
			self.selectedID = first.presentation.id
			return
		}

		// Return opens a typed address with a scheme rather than searching for it (DEV-1189).
		if schemeAddress != nil, entries.contains(where: { $0.presentation.id == Self.typedAddressID }) {
			self.selectedID = Self.typedAddressID
			return
		}

		// A page the text no longer leads toward takes its highlight with it; any other
		// highlight stays.
		if selectedID == matched || !entries.contains(where: { $0.presentation.id == selectedID }) {
			self.selectedID = entries.first?.presentation.id
		}
	}
}

extension CommandBarFeature.Entry {
	/// Tabs and pages, as opposed to commands and spaces, which only appear on a text match.
	internal var isDestination: Bool {
		switch intent {
		case .selectTab, .open, .openHistory: true
		default: false
		}
	}

	/// A history entry: the profile's recorded history, or a private page's own back stack.
	internal var isHistory: Bool {
		switch intent {
		case .openHistory: true
		case .open: presentation.id.hasPrefix("history-")
		default: false
		}
	}

	/// A command, by title, or a Settings row: what an exact title match puts first (DEV-1015).
	internal var isCommandOrSetting: Bool {
		switch intent {
		case .command, .disabledCommand, .newFolder, .toggleSidebar, .undo, .openSettings: true
		default: false
		}
	}

	/// Loads a page in a tab the host knows, so choosing it is a visit history can count as
	/// typed: not switching to a tab, Peek, or Open in Little Arx, whose window is made later.
	internal var opensPage: Bool {
		switch intent {
		case .open, .openHistory, .openInNewTab: true
		default: false
		}
	}

	/// A Settings row (DEV-1015).
	internal var isSetting: Bool {
		if case .openSettings = intent { return true }
		return false
	}

	/// The calculator's result or a quick-create row (DEV-895).
	internal var isInstant: Bool {
		presentation.id == CommandBarFeature.State.calculatorEntryID || presentation.id.hasPrefix("create-")
	}

	internal var isFavorite: Bool {
		if case .tab(_, .favorite) = destination { return true }
		return false
	}

	/// Every command enabled in `context`, as the command bar lists them. The menu bar enables the
	/// same commands, so each of its commands can be found in the bar too (DEV-1014), apart from
	/// `omittedCommands(in:)`. A command `isListedDisabled(in:)` is listed too, disabled
	/// (DEV-1262).
	public static func commands(
		in context: BrowserCommandContext,
		bindings: [ShortcutBinding],
		aliases: [CommandAlias] = []
	) -> [Self] {
		let omitted = omittedCommands(in: context.host)
		return BrowserCommand.allCases
			.filter { !omitted.contains($0) }
			.compactMap { command in
				if command.isEnabled(in: context) {
					return .command(command, bindings: bindings, aliases: aliases)
				}
				guard command.isListedDisabled(in: context) else { return nil }

				var entry: Self = .command(command, bindings: bindings, aliases: aliases)
				entry.intent = .disabledCommand(command)
				entry.presentation.isEnabled = false
				return entry
			}
	}

	/// Commands the menu bar offers that the command bar leaves out on purpose: Little Arx's own
	/// bar doesn't offer another Little Arx.
	public static func omittedCommands(in host: BrowserCommandContext.Host) -> Set<BrowserCommand> {
		host == .little ? [.littleArx] : []
	}

	public static func command(
		_ command: BrowserCommand,
		bindings: [ShortcutBinding],
		aliases: [CommandAlias] = []
	) -> Self {
		.init(
			presentation: .init(
				id: "command-" + command.rawValue,
				title: command.title,
				subtitle: command.subtitle,
				actionTitle: String.localized(.appUI.command.action),
				symbol: command.symbol,
				shortcut: bindings.shortcut(for: command)?.display,
				alias: aliases.alias(for: command)
			),
			intent: .command(command)
		)
	}
}
