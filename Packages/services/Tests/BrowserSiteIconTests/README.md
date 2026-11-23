# BrowserSiteIconTests

`BrowserSiteIconStore` (DEV-809): icons survive a new store on the same directory, profiles never share entries, a live icon replaces the stored one, removing a profile deletes its file, retaining tab pages prunes the rest, eviction keeps the newest entries within bounds, and oversized or non-web entries are refused. All persistence uses disposable directories; no browser profile is opened.
