import Foundation

/// Open to an empty page at launch (DEV-1234): a launch shows the empty page, with no tab selected
/// in any space and every folder collapsed. Applied once, to what the launch loaded, before any
/// window shows it. A window opened while Arx runs is unaffected.
public enum LaunchEmptyPage {
	/// Empties `organization` and the saved windows in `preferences` when the setting is on, and
	/// leaves both as saved when it's off.
	///
	/// Only selection, expansion and what saved windows show change. No tab, folder or space moves,
	/// so an organization that validated before still does, and no selection can point at a tab its
	/// space doesn't hold. A window record from before windows kept their own open tabs (DEV-822)
	/// first gets the open tabs its panes would have given it, because restoring it reads them from
	/// those panes.
	///
	/// - Parameters:
	///   - mainWindowID: The identity launch gives the main window.
	///   - mainSpaceID: The space the main window opens on.
	public static func apply(
		to organization: inout BrowserOrganization,
		preferences: inout BrowserPreferences,
		mainWindowID: UUID,
		mainSpaceID: Space.ID
	) {
		guard preferences.opensEmptyPageAtLaunch else { return }

		// Without restoration launch drops the records, and the first change saves over them.
		if preferences.restoresWindowsAtStartup {
			preferences.windowPresentations = preferences.windowPresentations.keepingLegacyOpenTabs(
				in: organization,
				mainWindowID: mainWindowID,
				mainSpaceID: mainSpaceID
			)
		}
		organization = organization.emptiedForLaunch()
		preferences.windowPresentations = preferences.windowPresentations.map { $0.emptiedForLaunch() }
	}
}

extension BrowserOrganization {
	/// The same organization with no space's tab selected and every folder collapsed (DEV-1234).
	public func emptiedForLaunch() -> Self {
		var result = self
		for index in result.spaces.indices {
			result.spaces[index].selectedTabID = nil
		}
		for index in result.folders.indices {
			result.folders[index].isExpanded = false
		}
		return result
	}
}

extension BrowserWindowPresentation {
	/// The same window with each space's layout reduced to one empty pane (DEV-1234), so restoring
	/// it shows no tab and deselects the space's tab. Its geometry, widths, chat pins and the open
	/// tabs it keeps stay: they say where things are, not what's shown.
	public func emptiedForLaunch() -> Self {
		var result = self
		result.spaces = spaces.map { $0.emptiedForLaunch() }
		return result
	}
}

extension BrowserSpacePresentation {
	/// One empty pane, keeping the active pane's identity.
	public func emptiedForLaunch() -> Self {
		.init(
			id: id,
			panes: [.init(id: activePaneID, tabID: nil)],
			activePaneID: activePaneID,
			orientation: orientation
		)
	}
}

extension [BrowserWindowPresentation] {
	/// The records with each additional window's record from before DEV-822 (no `openTabs`) given
	/// the open tabs launch would infer for it from its panes, so emptying the panes keeps them.
	///
	/// Follows AppFeature's `restoreWindowPresentations` and `restoreLegacyOpenTabOwners` step by
	/// step: the open tabs records with a list keep come first, then the main window's shown tabs
	/// (or its selected tab when it has no record), then each additional window's active layout in
	/// order. A legacy window gets the open tabs its active panes show, then those its other layouts
	/// hold that no window shows. Records restoration drops are left as they are.
	internal func keepingLegacyOpenTabs(
		in organization: BrowserOrganization,
		mainWindowID: UUID,
		mainSpaceID: Space.ID
	) -> Self {
		var windowIDs: Set<UUID> = [mainWindowID]
		let additional = filter { saved in
			windowIDs.insert(saved.id).inserted && organization.spaces.ids.contains(saved.activeSpaceID)
		}
		guard additional.contains(where: { $0.openTabs == nil })
		else { return self }

		let openTabs: [Tab.ID] = organization.spaces.flatMap(\.unpinnedTabs)
		let open: Set<Tab.ID> = Set(openTabs)
		var owners: [Tab.ID: UUID] = [:]
		for record in additional {
			for tab in record.openTabs ?? [] where open.contains(tab) && owners[tab] == nil {
				owners[tab] = record.id
			}
		}
		let kept: [Tab.ID: UUID] = owners
		func keptElsewhere(_ windowID: UUID) -> Set<Tab.ID> {
			Set(kept.filter { $0.value != windowID }.keys)
		}

		var claimed: Set<Tab.ID> = []
		if let saved = first(where: { $0.id == mainWindowID }) {
			let restored = saved.restoredTabs(in: organization, excluding: keptElsewhere(mainWindowID))
			claimed.formUnion(restored?.shown ?? [])
		} else if
			let selected = organization.spaces[id: mainSpaceID]?.selectedTabID,
			organization.tabs[id: selected] != nil,
			kept[selected] == nil
		{
			claimed.insert(selected)
		}

		var legacy: [(id: UUID, shown: [Tab.ID], cached: [Tab.ID])] = []
		for record in additional {
			let restored = record.restoredTabs(in: organization, excluding: claimed.union(keptElsewhere(record.id)))
			claimed.formUnion(restored?.shown ?? [])
			if record.openTabs == nil {
				legacy.append((record.id, restored?.shown ?? [], restored?.cached ?? []))
			}
		}
		for window in legacy {
			for tab in window.shown where open.contains(tab) && owners[tab] == nil {
				owners[tab] = window.id
			}
		}
		for window in legacy {
			for tab in window.cached where !claimed.contains(tab) && open.contains(tab) && owners[tab] == nil {
				owners[tab] = window.id
			}
		}

		let legacyIDs: Set<UUID> = Set(legacy.map(\.id))
		return map { record in
			guard record.openTabs == nil, legacyIDs.contains(record.id)
			else { return record }

			var result = record
			result.openTabs = openTabs.filter { owners[$0] == record.id }
			return result
		}
	}
}

extension BrowserWindowPresentation {
	/// The tabs restoring this record shows in its active space and holds in all its layouts, or
	/// nil when none of its spaces is left.
	fileprivate func restoredTabs(
		in organization: BrowserOrganization,
		excluding claimed: Set<Tab.ID>
	) -> (shown: [Tab.ID], cached: [Tab.ID])? {
		var seen: Set<Space.ID> = []
		let layouts = spaces.compactMap { value -> BrowserSpacePresentation? in
			guard seen.insert(value.id).inserted else { return nil }

			return value.sanitized(in: organization, excluding: claimed)
		}
		guard let active = layouts.first(where: { $0.id == activeSpaceID }) ?? layouts.first
		else { return nil }

		let shown = active.panes.compactMap(\.tabID)
		let cached = (layouts.filter { $0.id != active.id } + [active]).flatMap { $0.panes.compactMap(\.tabID) }
		return (shown, cached)
	}
}
