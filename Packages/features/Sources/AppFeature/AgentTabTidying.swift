import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// The tabs agents open (DEV-1022), with `ARX_AGENT_TABS` on. Each remembers the client that
/// opened it, and goes to the archive once nothing has used it for Settings' delay, counting only
/// time the Mac is awake. A tab stays while it's on screen or selected in its space, while an
/// agent acts on it, while a form on it has something typed in, or when its page asks to stay.
/// A tab the person picks in the sidebar or keeps, or pins, renames or moves out of the open
/// tabs, is theirs from then on.
@Reducer
internal struct AgentTabTidying {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.suspendingClock)
	private var clock

	@Dependency(\.browserEngine)
	private var engine

	/// How often an agent tab's unused time grows. A suspending clock stops while the Mac sleeps.
	internal static let interval: Duration = .seconds(60)

	private enum Cancellation {
		case ticker
	}

	internal var body: some ReducerOf<Self> {
		Pullback(\.startAgentTabs) { state in
			guard state.automation.agentTabsEnabled else { return .none }
			state.trackAgentTabs()
			return .run { [clock] send in
				for await _ in clock.timer(interval: Self.interval) {
					await send(.tidyAgentTabs)
				}
			}
			.cancellable(id: Cancellation.ticker, cancelInFlight: true)
		}

		Pullback(\.tidyAgentTabs) { state in
			guard state.automation.agentTabsEnabled else { return .none }
			state.trackAgentTabs()

			// A tab the person pinned or renamed is theirs from then on. One the agent pinned or
			// renamed itself, through MCP, stays the agent's while it's as the agent left it: the
			// sweep can't tell who pinned, and an agent's own pin lost its client a minute later
			// (engine batch 8's AutomationSmoke, organization.moveFolder).
			let adopted = state.automation.agentTabs.compactMap { id, record -> BrowserCore.Tab.ID? in
				guard let tab = state.workspace.tabs[id: id] else { return nil }

				return state.isPersonsOrganization(tab, record: record) ? id : nil
			}
			let adopting = state.keepAgentTabs(adopted)

			// A tab in use counts no unused time: its delay starts when the use ends.
			let inUse = state.agentTabsInUse
			for id in state.automation.agentTabs.keys {
				if inUse.contains(id) {
					state.automation.agentTabs[id]?.idle = .zero
				} else {
					state.automation.agentTabs[id]?.idle += Self.interval
				}
			}
			guard let delay = state.automationPreferences.agentTabCleanup.delay else { return adopting }

			let due = state.automation.agentTabs
				.filter { id, tab in tab.idle >= delay && state.isTidyable(id) }
				.mapValues(\.uses)
			guard !due.isEmpty else { return adopting }

			// Each looked at starts over: one that stays waits a whole delay before the next look.
			for id in due.keys { state.automation.agentTabs[id]?.idle = .zero }
			let policy = state.automation.agentTabsPolicy
			return .merge(adopting, .run { [engine] send in
				var drafted: Set<BrowserCore.Tab.ID> = []
				for id in due.keys where await Self.holdsDraft(id, engine: engine) {
					drafted.insert(id)
				}
				await send(.automation(.event(.agentTabsChecked(due, drafted: drafted, policy: policy))))
			})
		}

		Pullback(\.automation.event.agentTabsChecked) { state, value in
			let (due, drafted, policy) = value

			// Only those still due go: one picked, kept, shown or used meanwhile stays, and so
			// does everything once Settings' delay changed.
			guard
				policy == state.automation.agentTabsPolicy,
				state.automationPreferences.agentTabCleanup.delay != nil
			else { return .none }
			let tidied = due.filter { id, uses in
				!drafted.contains(id) && state.isTidyable(id, unusedSince: uses)
			}
			guard !tidied.isEmpty else { return .none }

			state.automation.agentTabsArchiving.merge(tidied) { _, new in new }
			return .send(.main(.archiveInactiveTabs(Array(tidied.keys))))
		}

		Pullback(\.automation.ui.agentTabCleanup) { state, cleanup in
			guard state.automationPreferences.agentTabCleanup != cleanup else { return .none }
			state.automationPreferences.agentTabCleanup = cleanup

			// Decisions taken under the old delay are dropped.
			state.automation.agentTabsPolicy &+= 1
			state.automation.agentTabsArchiving = [:]
			return state.saveWorkspace()
		}

		Pullback(\.main.delegate.keepAgentTab) { state, id in
			state.keepAgentTab(id)
		}

		// Picking an agent's tab in the sidebar makes it the person's, after the window has
		// shown it.
		Pullback(\.main.sidebar.ui.sidebar) { state, action in
			guard let id = state.pickedAgentTab(action) else { return .none }
			return .send(.automation(.event(.agentTabKept(id))))
		}

		Pullback(\.windows) { state, action in
			switch action {
			case let .element(_, .delegate(.keepAgentTab(id))):
				return state.keepAgentTab(id)

			case let .element(_, .sidebar(.ui(.sidebar(action)))):
				guard let id = state.pickedAgentTab(action) else { return .none }
				return .send(.automation(.event(.agentTabKept(id))))

			default:
				return .none
			}
		}

		Pullback(\.automation.event.agentTabKept) { state, id in
			state.keepAgentTab(id)
		}
	}

	/// Whether a form on the tab's page has something typed into it. The engine checks every
	/// frame, cross-origin ones too, when it can (DEV-1084); otherwise the draft probe reads the
	/// page from its main frame. A page the engine can't read (unloaded, private, WebKit or off
	/// the web) has nothing to lose; one it couldn't read now (busy or slow) is treated as holding
	/// a draft, and looked at again later.
	internal static func holdsDraft(
		_ id: BrowserCore.Tab.ID,
		engine: BrowserEngineClient
	) async -> Bool {
		switch await engine.formEdits(id) {
		case .clean?:
			return false
		case .typed?, .unknown?:
			return true
		case nil:
			break
		}

		do {
			let outcome = try await engine.evaluateScript(id, draftProbe, 1_024, 2_000) { true }
			guard case let .value(json) = outcome else { return false }
			return json == "true"
		} catch .unavailable, .unsupported, .stale {
			return false
		} catch {
			return true
		}
	}

	/// True when a field's value differs from the page's own, cleared ones included, a file is
	/// chosen for upload, or an editable area has text, focused or not: what a person typed and
	/// hasn't sent. An editor that holds text it was given counts too, which keeps a tab rather
	/// than lose a draft. The fallback for an engine without the all-frames check, and for WebKit
	/// pages: the engine's check (`form_edits_bridge.mm`) follows the same rules in each frame.
	internal static let draftProbe: String = """
	// The page, its open shadow roots and the frames it can reach: a cross-origin frame can't be
	// read, and relies on its page's own before-unload check.
	const roots = [];
	const gather = (root) => {
	  roots.push(root);
	  for (const element of root.querySelectorAll('*')) {
	    if (element.shadowRoot) gather(element.shadowRoot);
	    if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
	      let inner = null;
	      try { inner = element.contentDocument; } catch (_) {}
	      if (inner) gather(inner);
	    }
	  }
	};
	gather(document);
	// Passwords, card details and one-time codes read as empty here, so one shown keeps the tab.
	// As the developer world redacts them: a password field, or one whose autocomplete names a
	// password, card number, security code, expiry or one-time code. One that was a password field
	// and shows its text now, with no such autocomplete, can't be told apart here.
	const protectedField = (field) => {
	  if (field.disabled || field.type === 'hidden' || !field.checkVisibility || !field.checkVisibility()) return false;
	  const complete = (field.getAttribute('autocomplete') || '').toLowerCase();
	  return field.type === 'password'
	    || ['password', 'cc-number', 'cc-csc', 'cc-exp', 'one-time-code'].some((token) => complete.includes(token));
	};
	const typed = (field) => {
	  if (field.disabled || field.readOnly) return false;
	  if (field.tagName === 'SELECT') {
	    const options = Array.from(field.options);
	    if (field.multiple) return options.some((option) => option.selected !== option.defaultSelected);
	    // Without a default, a single choice starts at its first option that can be chosen.
	    // The last option marked selected is the one a single choice starts at.
	    const initial = options.map((option) => option.defaultSelected).lastIndexOf(true);
	    // A list box (size above 1) starts with nothing chosen; an option in a disabled group can't
	    // be chosen either.
	    const usable = (option) => !option.disabled && !(option.parentElement && option.parentElement.tagName === 'OPTGROUP' && option.parentElement.disabled);
	    const start = initial >= 0 ? initial : field.size > 1 ? -1 : options.findIndex(usable);
	    return field.selectedIndex !== start;
	  }
	  if (protectedField(field)) return true;
	  const type = (field.type || '').toLowerCase();
	  if (type === 'checkbox' || type === 'radio') return field.checked !== field.defaultChecked;
	  // A file chosen for upload can't come back once the page closes (DEV-1092).
	  if (type === 'file') return !!field.files && field.files.length > 0;
	  if (['hidden', 'submit', 'button', 'reset', 'image'].includes(type)) return false;
	  // A range or color input has a value of the browser's own before anyone touches it.
	  if (type === 'range' || type === 'color') {
	    const initial = document.createElement('input');
	    for (const name of ['type', 'min', 'max', 'step', 'value'])
	      if (field.hasAttribute(name)) initial.setAttribute(name, field.getAttribute(name));
	    return field.value !== initial.value;
	  }
	  // A number half typed ("-", "1e") reads as empty but is held as bad input.
	  if (field.validity && field.validity.badInput) return true;
	  // A changed value counts, a cleared default too (DEV-1092); then an empty field doesn't.
	  if (field.value !== field.defaultValue) return true;
	  if (field.value.trim() === '') return false;
	  // A page that keeps its fields' default in step with what's typed, as React does, hides an
	  // edit: a filled field counts, except a search box, which results pages fill themselves.
	  const search = type === 'search' || field.getAttribute('role') === 'searchbox' || field.closest('[role=search]')
	    || ['q', 'query', 'search', 's'].includes((field.name || '').toLowerCase());
	  return !search;
	};
	return roots.some((root) =>
	  Array.from(root.querySelectorAll('input, textarea, select')).some(typed)
	  || Array.from(root.querySelectorAll('[contenteditable]')).some((area) => area.isContentEditable && area.textContent.trim() !== '')
	);
	"""
}

extension AppFeature.State {
	/// Starts tracking the agent tabs it doesn't track yet, from this launch or an earlier one,
	/// and forgets those that closed or became the person's.
	internal mutating func trackAgentTabs() {
		guard automation.agentTabsEnabled else { return }

		var tracked: [BrowserCore.Tab.ID: AgentTab] = [:]
		for tab in workspace.tabs {
			guard let clientID = tab.automationClientID else { continue }

			if let existing = automation.agentTabs[tab.id], existing.clientID == clientID {
				tracked[tab.id] = existing
			} else {
				tracked[tab.id] = .init(clientID: clientID)
			}
		}
		if tracked != automation.agentTabs { automation.agentTabs = tracked }
		automation.agentTabsArchiving = automation.agentTabsArchiving.filter { tracked[$0.key] != nil }
	}

	/// Records a tab a client just opened, or took over, in this connection.
	internal mutating func recordAgentTab(
		_ id: BrowserCore.Tab.ID,
		clientID: UUID,
		sessionID: UUID
	) {
		guard automation.agentTabsEnabled else { return }
		let uses = automation.agentTabs[id].map { $0.uses + 1 } ?? 0
		automation.agentTabs[id] = .init(clientID: clientID, sessionID: sessionID, uses: uses)
	}

	/// Whether the person pinned, unpinned or renamed the agent's tab: its pin or name differs from
	/// what the agent's own changes left, or, when the agent made none, it has one at all.
	internal func isPersonsOrganization(
		_ tab: BrowserCore.Tab,
		record: AgentTab
	) -> Bool {
		guard let left = record.agentOrganization else {
			return tab.savedDestination != nil || tab.customTitle != nil
		}

		return AgentTab.AgentOrganization(tab) != left
	}

	/// Notes the pin and name an agent's own change left on its client's tabs, so the tidying sweep
	/// doesn't take them for the person's (`AgentTab.agentOrganization`). Only for a tab that was
	/// still as the agent left it: a pin or name the person made meanwhile stays theirs, and the
	/// next sweep makes the tab the person's.
	internal mutating func noteAgentOrganization(
		from previous: BrowserOrganization,
		to current: BrowserOrganization,
		clientID: UUID
	) {
		guard automation.agentTabsEnabled else { return }

		for (id, record) in automation.agentTabs where record.clientID == clientID {
			guard
				let tab = current.tabs[id: id],
				tab.automationClientID == clientID,
				let before = previous.tabs[id: id]
			else { continue }

			let left = AgentTab.AgentOrganization(tab)
			let earlier = AgentTab.AgentOrganization(before)
			guard
				earlier != left,
				earlier == record.agentOrganization ?? AgentTab.AgentOrganization.untouched
			else { continue }

			automation.agentTabs[id]?.agentOrganization = left
		}
	}

	/// Agent tabs that came on screen or left it (DEV-1093): their unused time starts over then,
	/// not at the next check, and a tidying decision taken before is dropped. A tab glanced at
	/// with Next Tab between two checks still waits a whole delay.
	internal mutating func agentTabsShownOrHidden(_ ids: Set<BrowserCore.Tab.ID>) {
		guard !automation.agentTabs.isEmpty else { return }

		for id in ids where automation.agentTabs[id] != nil {
			automation.agentTabs[id]?.idle = .zero
			automation.agentTabs[id]?.uses += 1
		}
	}

	/// An agent acted on the tab, or read it: its unused time starts over.
	internal mutating func agentUsedTab(_ id: BrowserCore.Tab.ID) {
		guard automation.agentTabs[id] != nil else { return }
		automation.agentTabs[id]?.idle = .zero
		automation.agentTabs[id]?.uses += 1
	}

	/// Agent tabs something uses now: on screen, selected in their space, or the target of an
	/// agent's request, reads included.
	internal var agentTabsInUse: Set<BrowserCore.Tab.ID> {
		let tracked = Set(automation.agentTabs.keys)
		guard !tracked.isEmpty else { return [] }

		var used = tabsOnScreen.union(workspace.spaces.compactMap(\.selectedTabID)).union(tabsInAgentUse)
		used.formUnion(automation.presence.filter { $0.value.isActive }.keys)
		return used.intersection(tracked)
	}

	/// Whether the tab is still an agent's and nothing holds it: an open tab, as the agent left
	/// it, and nothing using it now, nor since the decision counted `unusedSince` uses.
	internal func isTidyable(
		_ id: BrowserCore.Tab.ID,
		unusedSince uses: Int? = nil
	) -> Bool {
		guard
			let record = automation.agentTabs[id],
			uses.map({ $0 == record.uses }) ?? true,
			let tab = workspace.tabs[id: id],
			tab.automationClientID == record.clientID,
			tab.savedDestination == nil,
			tab.customTitle == nil,
			// A WebKit page can't be read for drafts, nor asked before it closes.
			!webKitTabs.contains(id),
			workspace.spaces.contains(where: { $0.unpinnedTabs.contains(id) }),
			!agentTabsInUse.contains(id)
		else { return false }

		return true
	}

	/// A tab from an earlier connection of the same client, on the same page in the same space,
	/// that nothing holds: the client's next run takes it over instead of opening another.
	/// Another client's tab and the person's own never are.
	internal func reusableAgentTab(
		clientID: UUID,
		sessionID: UUID,
		url: URL,
		spaceID: Space.ID
	) -> BrowserCore.Tab.ID? {
		guard
			automation.agentTabsEnabled,
			let page = AgentTabs.page(url),
			let space = workspace.spaces[id: spaceID]
		else { return nil }

		return space.unpinnedTabs.last { id in
			isReusableAgentTab(id, clientID: clientID, sessionID: sessionID, page: page)
		}
	}

	/// Whether the client's open may take over the tab now: one it left on `url`'s page in a
	/// connection that has ended, which nothing holds. `reuseReady` asks again right before the
	/// takeover, so of two opens that chose the same tab, only the first gets it (DEV-1097).
	internal func isReusableAgentTab(
		_ id: BrowserCore.Tab.ID,
		clientID: UUID,
		sessionID: UUID,
		url: URL
	) -> Bool {
		guard
			automation.agentTabsEnabled,
			let page = AgentTabs.page(url)
		else { return false }

		return isReusableAgentTab(id, clientID: clientID, sessionID: sessionID, page: page)
	}

	private func isReusableAgentTab(
		_ id: BrowserCore.Tab.ID,
		clientID: UUID,
		sessionID: UUID,
		page: String
	) -> Bool {
		guard
			let record = automation.agentTabs[id],
			record.clientID == clientID,
			record.sessionID != sessionID,
			record.sessionID.map({ automation.sessions[$0] == nil }) ?? true,
			isTidyable(id),
			let tab = workspace.tabs[id: id]
		else { return false }

		return AgentTabs.page(tab.restoration.url) == page
	}

	/// The agent's tab a sidebar action picks: a click on its row or Favorite tile, whether it
	/// selects on release (`select`) or as the button goes down (`selectOnPress`, DEV-994), or on
	/// its member of a Split View group (DEV-1099).
	fileprivate func pickedAgentTab(_ action: SidebarAction) -> BrowserCore.Tab.ID? {
		switch action {
		case let .select(item), let .selectOnPress(item):
			agentTabID(item)

		case let .splitGroup(.focus(_, tab)):
			agentTabID(.tab(tab))

		default:
			nil
		}
	}

	/// The tab a sidebar item names, when it's an agent's.
	fileprivate func agentTabID(_ item: SidebarItem.ID) -> BrowserCore.Tab.ID? {
		guard
			automation.agentTabsEnabled,
			case let .tab(rawValue) = item
		else { return nil }

		let id = BrowserCore.Tab.ID(rawValue: rawValue)
		return workspace.tabs[id: id]?.automationClientID == nil ? nil : id
	}

	/// The tab becomes the person's: it forgets the client that opened it and is never tidied.
	internal mutating func keepAgentTab(_ id: BrowserCore.Tab.ID) -> Effect<AppFeature.Action> {
		keepAgentTabs([id])
	}

	internal mutating func keepAgentTabs(_ ids: [BrowserCore.Tab.ID]) -> Effect<AppFeature.Action> {
		let kept = ids.filter { workspace.tabs[id: $0]?.automationClientID != nil }
		guard !kept.isEmpty else { return .none }

		var organization = workspace
		for id in kept {
			organization.tabs[id: id]?.automationClientID = nil
			automation.agentTabs[id] = nil
			automation.agentTabsArchiving[id] = nil
		}
		return BrowserAutomation().commit(organization, for: nil, state: &self)
	}
}
