# SidebarFeature

Sidebar state, projections and transactional organization edits shared with the preview.

Requires macOS 27 and Swift 6.4. Features use core, services, AppUI and lower-level features; services never import features. Verify with `make test-all`.

Renaming stores a custom tab title independently of Chromium navigation metadata. The sidebar and command bar use this name, and pinning, unpinning, duplication, profile transfers, and workspace persistence preserve it.

Space projections include every profile’s spaces in durable order. Favorites are computed independently per page; switching profiles never carries a favorite from another profile. The window's sidebar reads `sidebarSpaceSummaries` for every space and `sidebarSpace(_:)` for each mounted space's page, so building it doesn't grow with other spaces' tabs; `sidebarSpaces` builds every space with its tabs, for the Library's Spaces page (DEV-937). Persisted space icons are shared by the heading and bottom navigation.

Favorites are profile-owned saved entries. Same-profile space selection keeps the current favorite identity and URL; AppFeature focuses an existing window/pane owner. Reset and removal request MainFeature's native close approval before committing. Reset restores saved metadata and unloads the session while retaining the favorite; removal deletes the saved entry with Undo. Explicit Unpin retains the current identity and moves it to the active same-profile space. Renaming, reordering, and Update Saved URL are undoable and persist with the profile's ordered collection.

Drops across profile boundaries delegate explicit dragged IDs, placement, and destination to MainFeature. Same-profile reordering remains a local transactional edit; invalid placements report a general move error rather than attributing every failure to folder cycles.

`gatherForSplit(_:joining:)` (DEV-1006) brings tabs into the list a Split View shares before they join it, beside its tabs: the target's group's list, else the target's, else (for a Favorite target) the first added tab's. An open tab moved into Pinned or a folder is pinned, a pinned tab moved into the open tabs is unpinned, and a tab of another space of the profile moves over, each through `move` beside the split, so it leaves its folder, tab group and old selection as any such drop does. A Favorite of the profile stays in the grid; a tab or Favorite of another profile throws and nothing changes. `canJoinSplit` answers whether a tab can join a split in a space without editing.

The sidebar shows a Split View group as one row in whichever list holds its tabs: open tabs, Pinned or a folder (`rows(_:)`). The row lists only the group's tabs in that list; its Favorites stay highlighted in the grid, so a group of one tab and Favorites shows that tab's own row.

Selecting a tab (`select`) moves to its space and expands a collapsed space, but leaves its folders collapsed (DEV-1110): the sidebar shows the tab beneath the nearest one. `reveal` still expands a folder and its ancestors, for the command bar's folder results and new folders. With `ARX_COLLAPSED_FOLDER_SHOWS_SELECTION` off, `select` expands the tab's folders as before.

Folder context and keyboard intents support ungroup, explicit subtree deletion, immediate or recursive opening, and updating saved URLs. Ungroup and saved URL changes use the existing undo stack; opening and deletion delegate native session work to MainFeature.

Move selection is an ordered identity list, separate from the active tab. Batch drops delegate to MainFeature for captured transaction planning and cross-profile disclosure. Transfer Undo metadata prevents falling through to unapproved restoration.

`undo` is the window's ⌘Z history (DEV-1030), newest last, at most `undoLimit` steps. Each `OrganizationUndo` holds the workspace before it and, once sealed, after it. `pushUndo` starts the window's own step and ends the one before; what the window changes meanwhile without a step of its own belongs to the open step. A close, a pin or Favorite reset (`commitTabClose`, `edit(sealed:)`) and a bulk close record a step that's done as it's made (`pushSealedUndo`), so a tab selected afterwards isn't part of it (DEV-1198). With `windowUndo` (`ARX_WINDOW_UNDO`), `sealUndo` ends it before a change from elsewhere (and drops a cross-profile move's step, whose exact reverse, which asks each page first, can no longer apply), and `appendUndo` adds a step another window, Settings or an agent made, or a window move's. `ui.undo` takes back the newest step that still has something left (`BrowserOrganization.reverting`), passing over one with nothing left or whose time is up; a step of this window's selects its space's previous tab again. An agent's step says whose it was, and one that can't go back says so. Without `windowUndo`, `sealUndo` clears the history and `ui.undo` restores the newest step's workspace whole, as before. Either way `delegate.undid` reports the step, which for a window move (`windowMove`, DEV-1156) gives the tabs back.

Copy and Share context actions reuse that ordered selection when the clicked tab is selected; an unselected clicked tab acts alone. Folders are skipped without expanding their contents, repeated tab identities are removed, and distinct tabs with equal URLs remain separate. AppFeature checks the captured tab list against the invoking sidebar before using any URL; stale or foreign targets cancel the whole action. Explicit pane and URL-bar commands remain single-page actions.

`commitTabClose` applies the shared metadata-only close/reset edit after the owning feature has obtained before-unload approval and disposed the native page. It preserves the existing saved-entry reset and Undo behavior for both UI and authorized automation callers.

Saved-tab presentation includes a profile-and-saved-page URL icon key. It never substitutes the current restoration URL or fetches SavedDestination.iconURL. Favorite Update Saved URL and Undo naturally select another presentation key without adding binary image data to organization state.

`tabAudio` and `defaultTabAudio` (DEV-800) carry each tab's sound into `tabItem`'s `SidebarItem.audio`: the app sets them from its media state, chat tabs get none, and private windows get nil, so their rows show no speaker and no Mute Tab.

`unloadedTabs` (DEV-873) holds the tabs whose page Arx unloaded to free memory; `tabItem` sets `SidebarItem.isUnloaded` for them, and their rows fade until the tab is shown. AppFeature's tab unloading keeps it; private windows get none.

`State.message` is the window's notice text. Every write, even the same text again, makes a new `SidebarNotice` (`State.notice`) with a new `id`, so MainFeature's notice toast can time each one in full (DEV-777).

`tabAgents` (DEV-899) holds the MCP clients acting on tabs, kept by the app from its automation state; each row shows a small badge until `SidebarItem.Agent.fadesAt`.

Tab groups (DEV-911): `openTabItems` shows each `TabGroup` of the space as one row, `SidebarItem.isTabGroup` with `id` `.folder(group)` and its tabs as `children`, renamed and folded by the folder actions `.rename` and `.toggle`. `groupTabs` gathers the open tabs among the given rows (a Split View row brings all its tabs) into a new group named New Group where the first is and clears the selection; `ungroupTabGroup` and `pinTabGroup` (a pinned folder of the group's name) are single edits. With independent windows a group can span windows, and both act only on the tabs this window shows (`windowTabGroupMembers`); the other windows keep theirs grouped (DEV-1160). A single tab's move leaves its group first and joins the group it was dropped in: on the group's row, on the line just under it, or beside one of its tabs (`resolvingTabGroupTarget`); above the group's row is outside it. The sidebar sends a dragged row as a one-item `moveItems`, so one involving a tab group (its tab, or a drop on a group's rows) goes the same way. Other drops take the tree move, whose plan takes the moved tabs out of their groups, and a drop on a group's rows lands as a plain open-tab target.

DEV-907: `tabItem` sets `SidebarItem.unread` from `unreadBadges`, the app's last report for a live page, or else from the tab's saved title, so a frozen or unloaded tab shows what it last had; chat tabs show none. DEV-1258: whether it shows is resolved from the tab's own choice, its site's (`unreadBadgeOverrides`), its profile's (`Profile.unreadBadges`) and the browser default (`showsUnreadBadges`); `SidebarItem.unreadBadges` carries the tab's own choice and what it inherits, for its menu.

`webKitTabs` (DEV-877) holds the tabs WebKit shows, kept by the app from the page engines; their icons carry a small Safari mark.

Independent windows (DEV-822): `openTabFilter` (`OpenTabFilter`, kept by the app) picks which open tabs the window shows. `openTabItems`, `windowOpenTabs`, `windowTabOrder` and `windowShows(_:)` read it, so the rows, Next Tab, ⌘1–9, neighbour selection, Close Other Tabs, Close Tabs Below, Archive All and New Group see only the window's own open tabs, while Favorites and pinned tabs show everywhere. The organization itself stays whole; drops keep their tab-ID anchors.

Pin reset shake (DEV-1225, `ARX_PIN_RESET_SHAKE`): a reset (`event.closeApproved` with `reset`, or `noteReset` from a bulk reset) adds one to the tab's count in `resetPulses`, while `shakesResetPins` is on. The counts only grow: a row shakes when its count goes up, and one that appears with a count already there stays still.

Tab icons (DEV-1251): `ui.sidebar.changeIcon` opens the tab's icon picker (`iconPickerTabID`, shown as `SidebarItem.isPickingIcon`), `.dismissIconPicker` closes it, and `.setIcon` sets or, with nil, resets `Tab.icon` as an edit ⌘Z takes back. Moves and duplicates keep the icon; closing or archiving drops it (Tab Archive keeps none), and ⌘Z after a close puts the tab back with it. A space with no icon presents `SpaceIcon.dot`.
