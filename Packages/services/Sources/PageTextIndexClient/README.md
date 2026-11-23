# PageTextIndexClient

The words of the pages a profile visited, for history search (DEV-1068). `PageTextIndexClient` (`pageTextIndex`) keeps them in one SQLite file per profile, `<profile UUID>.text.sqlite` in the profile's History folder beside its history file: a `pages` table (address, last visit) and an FTS5 index of each page's title and text (`unicode61`, accents removed).

- `save` keeps a page's text, at most `maximumCharacters` (10,000) characters of it and 1,000 of its title, replacing what the page had. Past `maximumPages` (history's 2,000) the oldest pages go.
- `search` asks for pages with every query word as the start of a word (`"word"*`), best first (`rank`), each with `snippet` of its text around the match as its passage.
- `clear` deletes the profile's file, as Clear History does; `clearSince` removes pages visited at or after a moment, and `retain` keeps only the pages history kept after Delete from History. Both then merge the index (`optimize`), and `secure_delete` overwrites what was removed, so deleted text doesn't stay in the file.
- Each removal carries the generation history moved to, and a page read before it is never saved after it. Removals run in their own tasks, so one can arrive after a newer one that doesn't cover it, such as a narrower range (DEV-1098). It still applies, to the pages read before it: the store remembers the generation each page saved in this run was read at, and every removal leaves the pages read at its generation or later. A late `clear` then removes the other pages instead of deleting the file. A read of a page from before the text already saved for it is dropped, and a late removal that keeps a page still merges the index, so the words that page replaced go from the file too.

At most that is about 19 MB per 1,000 pages, so under 40 MB for a profile's 2,000 (measured by `PageTextIndexTests` with prose-like text from a 20,000-word vocabulary); real pages are usually shorter.

Nothing is kept for private windows: AppFeature's `ProfileHistory` saves a page's text only beside the visit it records, which it never does for a private page. Nothing leaves the Mac.

Depends on BrowserCore, `_Dependencies` and the system's SQLite. AppFeature reads pages into it; CommandBarFeature searches it.
