# Translator brief: Arx into <lang>

You translate the interface of Arx, a web browser for the Mac, from English into <lang> (<language name>). Replace `<lang>` and `<dir>` below with the values you were given.

- Repository: the root of the Arx repository checkout you were given (run commands from here).
- Your chunks: `<dir>` (normally `build/localization/<lang>/`), files `chunk-001.json`, `chunk-002.json`, …

## Read first

1. `.agents/LOCALIZATION.md`: sections "The naming rule", "Per-language conventions" (your row) and "Arx's own terms".
2. `<dir>/glossary.md`: the required terms and the rules for <lang>. The glossary wins over any other choice.

## Do this for each chunk, one at a time, in order

1. Read `<dir>/chunk-NNN.json`. It has `entries`; each entry has:
   - `key`: the string's name. It tells you where the text appears (`menu.` a menu item, `settings.` Settings, `sidebar.` the sidebar, `onboarding.` first-run screens).
   - `english`: the text. A string, or for a count an object such as `{"one": "%lld tab", "other": "%lld tabs"}`.
   - `categories` (counts only): the plural forms <lang> needs. Give exactly these.
   - `comment`, `hint`: context. Follow them.
   - `placeholders`: the placeholders your text must contain.
   - `current` (sometimes): an earlier translation whose English has changed. Fix it to match the new English.
2. Write `<dir>/chunk-NNN.translated.json` next to it, as valid JSON in UTF-8, with every key of the chunk and nothing else:

   ```json
   {
     "translations": {
       "sidebar.title": "<translation>",
       "sidebar.closeTabs": {"one": "<…%lld…>", "few": "<…%lld…>", "many": "<…%lld…>", "other": "<…%lld…>"}
     }
   }
   ```

   A string entry gets a string. A count entry gets an object with exactly the `categories` listed, each with its own grammatical form.
3. Check it: `make localization-import ARGS='--lang <lang> --from <dir> --validate-only'`. It checks every translated chunk so far. If it lists problems, fix those keys and run it again until it prints `valid`. Never run it without `--validate-only`.

## Rules

- Name things as Apple does in macOS and Safari in <lang>. When unsure of a platform term, use the glossary; if it isn't there, use Apple's term for that language; then Chrome's. Never invent a literal translation where the platform has a term.
- Never translate the names the glossary keeps in English: Arx, Little Arx, Peek, Air Traffic Control, Runway, bang, PiP (except where the glossary says otherwise), WebKit, Chromium, MCP, iCloud, Touch ID, Safari, Chrome, Google. Do not transliterate them.
- An Arx "space" is the glossary's word for Space. Never use the word Apple uses for macOS Spaces.
- Keep every placeholder (`%@`, `%lld`, `%d`, `%1$@`, `%%`) exactly, as many times as in the English. If <lang> needs them in another order, number them by the English order: `%2$@ … %1$lld`.
- Keep keyboard symbols (⌘ ⌥ ⌃ ⇧ ↩ ⇥ ⌫), `›`, URLs and file names as they are. Translate the Settings names between `›` the way the glossary or the other entries name them.
- Use the address form, capitalization, quotation marks and punctuation from your row in LOCALIZATION.md: the ellipsis is the single character `…`; Japanese and Chinese use full-width punctuation; French puts a non-breaking space before `: ; ! ?`; only English uses Title Case.
- Keep leading and trailing spaces exactly as in the English. Keep line breaks (`\n`).
- Keep it short: menu items, buttons and Settings rows are narrow. Prefer Apple's short words.
- Translate every entry, even if the English looks like a name, unless the whole text is a kept name or a symbol: then copy it unchanged.
- Settings search keywords (`settingsSearch.keywords.*`) are comma-separated words, not a sentence: translate each word, keep the commas.
- Don't edit the catalog, the glossary or any other file. Only write `.translated.json` files in `<dir>`.

## Report when you finish

- Chunks done, and entries translated, out of the totals in `<dir>/index.json`.
- The last `--validate-only` result.
- Keys you were unsure about, each with one line saying why (a term not in the glossary, ambiguous English, a text likely too long).
