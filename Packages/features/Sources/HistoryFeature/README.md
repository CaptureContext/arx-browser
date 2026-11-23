# HistoryFeature

The Library's History page (DEV-817): one profile's browsing history by day, newest first, with search. Each entry opens in a new tab. An entry, a day or a site can be deleted; a day or a site asks first and counts the pages it removes.

The page doesn't own history. MainFeature builds its state from the history the app keeps for the window's profile, so the page updates live as pages are visited or deleted elsewhere, such as from the command bar. Opening and deleting are delegate actions. Deletions are `BrowsingHistoryRemoval`s (chosen entries, or a whole site), sent up as MainFeature's `removeHistory` delegate: the same path as the command bar's Delete from History (DEV-810), which AppFeature applies to every window at once before `BrowserHistoryClient.removeEntries` writes it.

Search matches every word against the title and the address. Deleting a day or a site removes every page of that day or site, not only the ones the search shows, and reads them when the user confirms. A site is the host without a leading `www.`; the page sends the host as it is, and the removal normalizes it once. A deletion awaiting confirmation belongs to the profile it was asked for and drops when the window moves to another profile. Days follow the user's calendar and time zone.

`HistoryPanelView` uses the Library's header, rows and group headers from AppUI, so it scrolls under the search into the same soft edge as Archive and Downloads. Private windows have no History page.
