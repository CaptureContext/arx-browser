# Arx language

## Profiles, spaces and tabs

| Term | Meaning |
| --- | --- |
| Profile | A browsing identity with its own cookies, site storage, permissions, and browsing history. |
| Space | A page of the sidebar: a named set of pinned tabs, folders and regular tabs that belongs to one profile. Several spaces can share a profile. Do not call it a workspace. |
| Space root | A space's top-level collection of pinned tabs and folders. |
| Folder | A named, ordered collection of pinned tabs and nested folders within one space. |
| Tab group | A named, collapsible run of a space's regular tabs, shown as one row holding them. Pinning it makes a folder. |
| Bookmark | A pinned tab or a favorite tab: a tab with a name and a saved URL that stays until the person removes it. |
| Pinned tab | A space bookmark: a bookmark that belongs to one space. |
| Favorite tab | A profile bookmark: a bookmark that belongs to a profile and shows in every space using that profile. |
| Favorite | A synonym for favorite tab. |
| Regular tab | A tab that is neither pinned nor a favorite. Do not call it a temporary tab or an unpinned tab. |
| Organization | How a person has arranged their browser: spaces, folders, tab groups, bookmarks and the order of tabs. Not the company that manages a Mac, which policy text calls "your organization". |
| Saved URL | The destination remembered by a bookmark. Browsing elsewhere does not change it. |
| Current URL | The destination currently displayed by a browsing session. |
| Browsing session | A page's ongoing browsing activity, including its current page and back/forward history. |
| Navigation history | The back/forward sequence belonging to one browsing session. |
| Browsing history | The record of visited pages belonging to a profile. |
| Tab Archive | A profile's searchable collection of closed or deliberately archived tab entries available for restoration. |
| Badge | A small mark on a tab's icon: the unread mark a site asks for, or the mark of a WebKit page. |

## Windows and controls

| Term | Meaning |
| --- | --- |
| Sidebar | The primary persistent browser control for viewing and organizing favorites, spaces, folders, and tabs. |
| SideMenu | The leading part of the sidebar, opened beside the spaces: Media, Downloads, History, Spaces and Tab Archive, each with its list. |
| SideMenu tabs | The column of items along the SideMenu's leading edge (Media, Downloads, History, Spaces, Tab Archive) that picks which list it shows. |
| Settings tabs | The items in the Settings window's sidebar, each opening one page of settings. |
| Command bar | The control opened over the window for entering URLs and searches, finding tabs and spaces, and invoking commands. |
| urlbar | The field at the top of the sidebar that shows the current page's address and holds its buttons. Not "URL bar" or "address bar". |
| Site menu | The menu opened from the urlbar's page settings button: the current site's permissions, settings and page actions. |
| Empty page | What a window shows when no tab is selected. |
| Media stack | The sidebar's controls for the media playing in tabs, stacked when more than one tab is playing. |
| Raised glass | The look of Arx's floating fields and pop-ups: a glass surface lifted above the content behind it. |
| Peek | A temporary presentation of a link or existing tab inside the current browser window. |
| LittleArx | An independent compact browser window associated with a destination profile and space. Written "Little Arx" in the app and the manual. |
| Promotion | Keeping a Peek or LittleArx session as a tab in a space. |
| Split View | A browser-window layout showing two tabs in separate panes. |
| Pane | One page presentation within a Split View. |
| Focused pane | The pane that supplies the page context for navigation and browser commands. |
| Viewport | The visible web-content area of a browser window or preview. |
| OS workspace | A desktop or full-screen workspace managed by macOS (a macOS Space), distinct from an Arx space. |

## Media and pages

| Term | Meaning |
| --- | --- |
| PiP | Arx's mini player: a video floating above other windows with media controls, attached to its source tab. Menu commands spell it out as Picture in Picture. Not "ArxPiP" or "Arx PiP". |
| PagePiP | A tab's live page moved into a floating window that behaves like PiP, where it can be clicked and typed in; distinct from PiP's video. |
| Page full screen | A page showing alone across the screen because the page asked for it (the HTML Fullscreen API, such as a video's full-screen button), distinct from a window's macOS full screen. |
| WebKit page | A page Arx shows with WebKit instead of Chromium, for sites whose protected video needs it. |
| Page snapshot | A captured view of a page's content and actionable elements at a particular moment. |
| Page capture | An image of a rendered page, its visible area, or a selected region. |
| Full-page capture | An image of the page's currently laid-out document, including content beyond the viewport. |
| Sound feedback | Short sounds Arx plays when an action finishes, such as copying or saving a capture or a download ending. |

## Links and search

| Term | Meaning |
| --- | --- |
| Air Traffic Control | Arx's feature for choosing where incoming URLs open. |
| Routing rule | An ordered URL match with a destination profile, space, and window mode. |
| Clean Copy | Copying a link with recognized tracking parameters removed while preserving its functional destination. Its command is Copy Clean Link. |
| Search shortcut | A named keyword that sends a query to a chosen site's search. |
| Bang | A search shortcut invoked by typing an exclamation mark before its keyword. |

## Sync

| Term | Meaning |
| --- | --- |
| iCloud sync | Keeping a person's organization and portable preferences the same on their Macs through their own iCloud account. |
| Sync category | A kind of data the person turns iCloud sync on or off for, such as profiles and spaces, preferences, history, or tabs from other devices. |
| Tabs from other devices | The regular tabs another Mac of the same person has open, listed so one can be opened as a new tab here. |

## Agents and development

| Term | Meaning |
| --- | --- |
| MCP server | Arx's connection point for external assistants to inspect and operate permitted browser context using Model Context Protocol. |
| MCP client | An external application that connects an assistant to Arx's MCP server. |
| Access grant | The user's permission for a connected client to perform specified operations on selected browser context for a defined duration. |
| Feature flag | An `ARX_*` environment or defaults value read at launch that turns an optimisation or behaviour on or off. Not a switch: switches are Chromium's command-line flags. |
