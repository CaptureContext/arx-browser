import AppUI
import BrowserCore
import ExtensionsFeature
import SwiftUI
import _ComposableArchitecture

/// The archive export's choices and progress. AppFeature owns them.
public struct SettingsBrowserDataExport {
	public var includesHistory: Bool
	public var includesArchivedTabs: Bool

	/// From 0 to 1 while an export runs.
	public var progress: Double?
	public var setIncludesHistory: (Bool) -> Void
	public var setIncludesArchivedTabs: (Bool) -> Void
	public var cancel: () -> Void

	public init(
		includesHistory: Bool = false,
		includesArchivedTabs: Bool = false,
		progress: Double? = nil,
		setIncludesHistory: @escaping (Bool) -> Void = { _ in },
		setIncludesArchivedTabs: @escaping (Bool) -> Void = { _ in },
		cancel: @escaping () -> Void = {}
	) {
		self.includesHistory = includesHistory
		self.includesArchivedTabs = includesArchivedTabs
		self.progress = progress
		self.setIncludesHistory = setIncludesHistory
		self.setIncludesArchivedTabs = setIncludesArchivedTabs
		self.cancel = cancel
	}
}

/// A steady window, so moving through the sidebar doesn't resize it.
public enum SettingsWindowSize {
	public static let width: CGFloat = 900
	public static let sidebarWidth: CGFloat = 220
	public static let height: CGFloat = 680
}

public struct SettingsView: View {
	@Bindable
	public var store: StoreOf<SettingsFeature>

	public let organization: BrowserOrganization
	public let shortcuts: [SettingsShortcut]
	public let openAutomation: () -> Void
	public let exportArchive: () -> Void
	public let exportBookmarks: () -> Void
	public let browserDataExport: SettingsBrowserDataExport
	public let importData: () -> Void

	/// Sites where agents sign in without asking, for every profile. AppFeature owns them.
	public let agentSignInSites: [AgentSignInSite]
	public let removeAgentSignInSite: (AgentSignInSite) -> Void

	/// Steps Settings can open on their own, in onboarding's order.
	public let onboardingSteps: [OnboardingStep]

	/// Opens onboarding at one step, or where it left off for `nil`.
	public let openOnboarding: (OnboardingStep?) -> Void

	/// The built-in assistant's chat settings, supplied by the app, which owns the chats.
	public let assistant: AnyView?

	/// The space in front and recent spaces, so Air Traffic Control's tester matches real routing.
	public let routingContext: SettingsRoutingContext

	@SwiftUI.State
	private var categoryQuery: String

	/// Opens the pane's own search from the start, as a snapshot does.
	private let isPaneSearchExpanded: Bool

	/// The search result ↑ and ↓ have moved to, which Return opens.
	@SwiftUI.State
	private var resultSelection: Int

	/// Whether a page itself has focus, rather than a control on it, so ← goes back.
	@FocusState
	private var isPageFocused: Bool

	/// The pane's scroll while a page covers it, so Back returns to it (`SettingsScrollRestore`).
	@SwiftUI.State
	private var paneScroll: SettingsPaneScroll

	/// How far the pane in front was last scrolled.
	@SwiftUI.State
	private var paneOffset: SettingsPaneOffsetReading

	public init(
		store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization = .init(),
		shortcuts: [SettingsShortcut] = [],
		openAutomation: @escaping () -> Void = {},
		exportArchive: @escaping () -> Void = {},
		exportBookmarks: @escaping () -> Void = {},
		browserDataExport: SettingsBrowserDataExport = .init(),
		importData: @escaping () -> Void = {},
		agentSignInSites: [AgentSignInSite] = [],
		removeAgentSignInSite: @escaping (AgentSignInSite) -> Void = { _ in },
		onboardingSteps: [OnboardingStep] = [],
		openOnboarding: @escaping (OnboardingStep?) -> Void = { _ in },
		assistant: AnyView? = nil,
		routingContext: SettingsRoutingContext = .init(),
		searchQuery: String = "",
		isPaneSearchExpanded: Bool = false
	) {
		self.store = store
		self.organization = organization
		self.shortcuts = shortcuts
		self.openAutomation = openAutomation
		self.exportArchive = exportArchive
		self.exportBookmarks = exportBookmarks
		self.browserDataExport = browserDataExport
		self.importData = importData
		self.agentSignInSites = agentSignInSites
		self.removeAgentSignInSite = removeAgentSignInSite
		self.onboardingSteps = onboardingSteps
		self.openOnboarding = openOnboarding
		self.assistant = assistant
		self.routingContext = routingContext
		self._categoryQuery = .init(initialValue: searchQuery)
		self.isPaneSearchExpanded = isPaneSearchExpanded
		self._resultSelection = .init(initialValue: 0)
		self._paneScroll = .init(initialValue: .init())
		self._paneOffset = .init(initialValue: .init())
	}

	public var body: some View {
		HStack(spacing: 0) {
			sidebar
			Divider()
			detail
		}

		// The window's title bar is transparent: the sidebar and the pane's bar lay themselves
		// out from the window's top edge instead of below the title bar's inset.
		.ignoresSafeArea(.container, edges: .top)
		.onChange(of: location) { old, new in navigated(from: old, to: new) }
		.overlay(alignment: .bottom) {
			if let error = store.organizationError, !store.organizationEditorIsPresented {
				Text(error).foregroundStyle(.red).padding()
			}
		}
		.sheet(isPresented: $store.organizationEditorIsPresented.sending(\.ui.organizationEditorPresented)) {
			OrganizationEditorView(store: store, organization: organization)
				.settingsControls()
		}
		.sheet(
			isPresented: Binding(
				get: { store.extensions.isPresented },
				set: { if !$0 { store.send(.extensions(.ui(.dismiss))) } }
			)
		) {
			ExtensionsView(store: store.scope(state: \.extensions, action: \.extensions))
				.settingsControls()
		}
		.sheet(
			isPresented: Binding(
				get: { store.savedPasswords != nil },
				set: { store.send(.ui(.savedPasswordsPresented($0))) }
			)
		) {
			if let passwords = store.scope(state: \.savedPasswords, action: \.savedPasswords) {
				SavedPasswordsView(
					store: passwords,
					agentSignInSites: agentSignInSites.filter { $0.profileID == passwords.profileID },
					removeAgentSignInSite: removeAgentSignInSite
				)
				.settingsControls()
			}
		}
		.sheet(
			isPresented: Binding(
				get: { store.autofillData != nil },
				set: { store.send(.ui(.autofillPresented($0))) }
			)
		) {
			if let autofill = store.scope(state: \.autofillData, action: \.autofillData) {
				AutofillDataView(store: autofill)
					.settingsControls()
			}
		}
		.sheet(
			isPresented: Binding(
				get: { store.siteSettings != nil },
				set: { store.send(.ui(.siteSettingsPresented($0))) }
			)
		) {
			if let siteSettings = store.scope(state: \.siteSettings, action: \.siteSettings) {
				SiteSettingsView(store: siteSettings)
					.settingsControls()
			}
		}
		.sheet(
			isPresented: Binding(
				get: { store.clearBrowsingData != nil },
				set: { store.send(.ui(.clearBrowsingDataPresented($0))) }
			)
		) {
			if let clearBrowsingData = store.scope(state: \.clearBrowsingData, action: \.clearBrowsingData) {
				ClearBrowsingDataView(store: clearBrowsingData)
					.settingsControls()
			}
		}
		.font(SettingsTypography.body)
		.settingsControls()
		.background(Color(nsColor: .windowBackgroundColor))
		.frame(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		.sheet(item: $store.panel.sending(\.ui.panelPresented)) { panel in
			SettingsDetailView(store: store, panel: panel)
				.settingsControls()
		}
	}

	/// What the sidebar's search finds: panes, and the settings, pages and sheets inside them.
	private var searchResults: [SettingsSearchEntry] {
		SettingsCategory.searchIndex
			.filter { $0.isAvailable(store.featureFlags) }
			.matching(categoryQuery)
	}

	private var isSearching: Bool {
		!categoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private var sidebar: some View {
		ScrollViewReader { proxy in
			ScrollView {
				VStack(spacing: 2) {
					if isSearching {
						searchResultList
					} else {
						ForEach(SettingsCategory.available) { category in
							sidebarRow(category)
						}
					}
				}
				.padding(.horizontal, 12)
				.padding(.bottom, 12)
			}
			.scrollIndicators(.hidden)

			// The categories scroll under the search, which stays put, and fade out
			// softly beneath it. The scroll view spans the whole sidebar, from the window's
			// top edge under the window controls (DEV-782, DEV-790).
			.arxScrollBar(background: SettingsBarStyle.sidebarBackground) {
				BrowserSearchField(
					placeholder: String.localized(.appUI.spaceIcon.search),
					query: $categoryQuery
				)
				.onKeyPress(.downArrow) { moveResultSelection(by: 1, proxy: proxy) }
				.onKeyPress(.upArrow) { moveResultSelection(by: -1, proxy: proxy) }
				.onSubmit { chooseSelectedResult() }
				.padding(.horizontal, 12)

				// Just below the window controls, as in System Settings.
				.padding(.top, SettingsMetrics.sidebarSearchTop)
				.padding(.bottom, 8)
			}
			.onChange(of: categoryQuery) { _, _ in resultSelection = 0 }
		}
		.frame(width: SettingsWindowSize.sidebarWidth)
		.frame(maxHeight: .infinity, alignment: .top)
		.background(SettingsBarStyle.sidebarBackground)
	}

	@ViewBuilder
	private var searchResultList: some View {
		let results = searchResults
		if results.isEmpty {
			Text(localized: .appUI.settingsSearch.noResults)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity)
				.padding(.top, 24)
		}
		ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
			searchResultRow(entry, isSelected: index == min(resultSelection, results.count - 1)) {
				resultSelection = index
			}
			.id(entry.id)
		}
	}

	/// `select` keeps ↑ ↓ and Return in step with the result a click opened.
	private func searchResultRow(
		_ entry: SettingsSearchEntry,
		isSelected: Bool,
		select: @escaping () -> Void
	) -> some View {
		Button {
			select()
			store.send(.ui(.searchResultChosen(entry.destination)))
		} label: {
			HStack(spacing: 10) {
				tile(entry.category, size: 20)
				VStack(alignment: .leading, spacing: 1) {
					Text(entry.title)
						.lineLimit(1)
					if let path = entry.path {
						Text(path)
							.font(SettingsTypography.caption)
							.foregroundStyle(.secondary)
							.lineLimit(2)
					}
				}
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.frame(minHeight: 30)
			.background(
				isSelected ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.clear),
				in: ArxControlShape()
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}

	private func moveResultSelection(
		by offset: Int,
		proxy: ScrollViewProxy
	) -> KeyPress.Result {
		let results = searchResults
		guard isSearching, !results.isEmpty else { return .ignored }
		resultSelection = min(max(min(resultSelection, results.count - 1) + offset, 0), results.count - 1)
		proxy.scrollTo(results[resultSelection].id)
		return .handled
	}

	private func chooseSelectedResult() {
		let results = searchResults
		guard isSearching, !results.isEmpty else { return }
		store.send(.ui(.searchResultChosen(results[min(resultSelection, results.count - 1)].destination)))
	}

	private func sidebarRow(_ category: SettingsCategory) -> some View {
		let isSelected = store.category == category
		return Button { store.send(.ui(.categorySelected(category))) } label: {
			HStack(spacing: 10) {
				tile(category, size: 20)
				Text(category.title)
					.lineLimit(1)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 8)
			.frame(height: 30)
			.background(
				isSelected ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.clear),
				in: ArxControlShape()
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}

	private func tile(
		_ category: SettingsCategory,
		size: CGFloat
	) -> some View {
		ArxGlyphTile(glyph: category.glyph, tint: category.tint, side: size)
	}

	/// The pane's bar, laid out like every header bar (DEV-790): its icon tile, title and
	/// description on the leading edge, always shown; the pane has no centered header of its own.
	/// A pane with a search of its own, such as Shortcuts, keeps it on the bar's trailing edge as
	/// a raised capsule that expands into a wide field (DEV-782). Profiles keeps its "+" there.
	private var navigationBar: some View {
		ArxHeaderBar(
			.none,
			icon: ArxHeaderBarIcon(glyph: store.category.glyph, tint: store.category.tint),
			title: store.category.title,
			subtitle: store.category.detail,
			height: SettingsMetrics.navigationBarHeight
		) {
			SettingsToolbarAddButton(
				SettingsAddTarget(category: store.category),
				store: store,
				organization: organization
			)
			paneSearch
		}
		.padding(.top, SettingsMetrics.navigationBarTopInset)
	}

	/// A page inside a pane, such as Assistant › AI Commands: the same pinned bar, with a raised
	/// Back tile (⌘[), the page's title and its pane as the trail under it. Search Shortcuts keeps
	/// the built-in bangs' search on the bar's trailing edge (DEV-782), and a list's page its "+".
	private func subpageBar(_ page: SettingsPage) -> some View {
		SettingsNavigationBar(
			.back { store.send(.ui(.pagePresented(nil))) },
			title: pageTitle(page),
			trail: [page.category.title],
			height: SettingsMetrics.navigationBarHeight
		) {
			SettingsToolbarAddButton(
				SettingsAddTarget(page: page),
				store: store,
				organization: organization
			)
			if page == .searchShortcuts {
				ArxHeaderSearch(
					String.localized(.appUI.search.bundledSearch),
					query: Binding(
						get: { store.bangQuery },
						set: { store.send(.ui(.bangQueryChanged($0))) }
					),
					isExpanded: isPaneSearchExpanded
				)
			}
		}
		.padding(.top, SettingsMetrics.navigationBarTopInset)
	}

	private var hasPaneSearch: Bool {
		store.category == .shortcuts
	}

	/// A pane's own search, such as Shortcuts': a button on the bar that expands into a field.
	@ViewBuilder
	private var paneSearch: some View {
		if hasPaneSearch {
			ArxHeaderSearch(
				String.localized(.appUI.settings.shortcutSearch),
				query: Binding(
					get: { store.shortcutQuery },
					set: { store.send(.ui(.shortcutQueryChanged($0))) }
				),
				isExpanded: isPaneSearchExpanded
			)
			.id(store.category)
		}
	}

	/// A page inside a pane replaces it under a Back bar; every pane scrolls whole.
	@ViewBuilder
	private var detail: some View {
		if let page = store.page, page.category == store.category {
			ScrollView {
				pageContent(page)
					.frame(maxWidth: 620, alignment: .leading)
					.padding(.horizontal, 24)
					.padding(.top, SettingsMetrics.contentTopInset)
					.padding(.bottom, 16)
					.frame(maxWidth: .infinity)
			}
			.arxScrollBar(background: SettingsBarStyle.background) { subpageBar(page) }

			// ← goes back once a row was opened from the keyboard, like ⌘[ on the Back tile; a
			// field that has focus keeps its arrows.
			.focusable()
			.focusEffectDisabled()
			.focused($isPageFocused)
			.onKeyPress(.leftArrow) {
				guard isPageFocused else { return .ignored }

				store.send(.ui(.pagePresented(nil)))
				return .handled
			}
			.onAppear { isPageFocused = true }
			.id(page)

		} else {
			ScrollViewReader { proxy in
				paneScrollView
					.task(id: store.highlightedAnchor) {
						guard let anchor = store.highlightedAnchor else { return }

						// Once the pane has laid out, in case the result switched panes.
						try? await Task.sleep(for: .milliseconds(60))
						withAnimation(.smooth) { proxy.scrollTo(anchor, anchor: anchor.scrollAlignment) }
					}
			}
			.environment(\.settingsHighlightedAnchor, store.highlightedAnchor)
		}
	}

	private var location: SettingsLocation {
		.init(category: store.category, page: store.page)
	}

	/// Saves the pane's scroll as a page opens over it, and forgets it for another pane.
	private func navigated(
		from old: SettingsLocation,
		to new: SettingsLocation
	) {
		guard SettingsScrollRestore.isEnabled else { return }

		paneScroll.navigated(from: old, to: new, lastOffset: paneOffset.value)
		if new.category != old.category {
			paneOffset.value = nil
		}
	}

	/// A profile's page is titled with its name.
	private func pageTitle(_ page: SettingsPage) -> String {
		guard
			page == .profile,
			let profile = organization.profiles[id: store.selectedProfileID]
		else {
			return page.title
		}

		return profile.name
	}

	private var paneScrollView: some View {
		ScrollView {
			LazyVStack(spacing: 0) {
				pane
					.frame(maxWidth: 620, alignment: .leading)
					.padding(.horizontal, 24)
					.padding(.top, SettingsMetrics.contentTopInset)
					.padding(.bottom, 24)
			}
			.frame(maxWidth: .infinity, alignment: .top)
		}

		// Back from a page starts the pane where it was (`SettingsScrollRestore`).
		.settingsPaneScroll($paneScroll, category: store.category, reading: paneOffset)

		// No opaque bar and no divider: rows blur under the bar's soft edge (DEV-790, DEV-807).
		.arxScrollBar(background: SettingsBarStyle.background) { navigationBar }
		.id(store.category)
	}

	@ViewBuilder
	private var pane: some View {
		switch store.category {
		case .arx: arxPane
		case .general: generalPane
		case .profiles: SettingsProfilesView(store: store, organization: organization)
		case .sync: syncPane
		case .assistant: assistantPane
		case .links: linksPane
		case .shortcuts: SettingsShortcutsView(store: store, shortcuts: shortcuts)
		case .appearance: appearancePane
		case .privacy: privacyPane
		case .developer: developerPane
		case .advanced: advancedPane
		case .experimental: experimentalPane
		}
	}
}
