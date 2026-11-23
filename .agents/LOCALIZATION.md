# Localization

How Arx's interface text is written, translated and checked (DEV-1291). Read it before you add or change any text a person sees, and before you translate.

Languages: English is the source. Polish (`pl`), Russian (`ru`), Ukrainian (`uk`), German (`de`), French (`fr`), Spanish as in Spain (`es`), Japanese (`ja`) and Simplified Chinese (`zh-Hans`) are planned. A language ships only when its translation is complete and passes the check; see [Shipping a language](#shipping-a-language).

## Where the strings live

- **`Packages/design-system/Sources/AppUI/Resources/AppUI.xcstrings`** holds the app's interface and accessibility text: one entry per key, keys named by feature (`sidebar.closeTabs`, `menu.copy`), English in `en`, plurals as Xcode's plural variations. AppUI's `.packageresources` makes the package-resources plugin (`Forks/package-resources-cli`) generate typed accessors from it, one per key, split at the dots: `.appUI.sidebar.closeTabs(count)`. Code reads them through PackageResources (`.build/checkouts/swift-package-resources/Sources/PackageResources/XCStringResource.swift`): `String.localized(.appUI.menu.copy)`, `Text(localized: .appUI.common.done)`, `LocalizedStringResource.localized(…)`. Each looks the key up in AppUI's resource bundle, table `AppUI`. Features in other packages use AppUI's accessors; they have no catalogs of their own.
- **`Containers/macOS/InfoPlist.xcstrings`** holds the app's Info.plist usage descriptions (the text in macOS's camera, microphone, location, Bluetooth, local network, passkey and automation prompts). Its English must equal `.xcodegen/macOS.yml` and `Scripts/core/privacy.py` word for word; `make check` compares them.
- **`Localization/languages.json`** says which languages ship. **`Localization/sources.json`** is written by the import and records which English each translation was made from.
- **`.agents/localization/glossary.<lang>.md`**: the required terms for each language, with its rules (address, punctuation, the word for an Arx space). The glossary wins over any other choice.

macOS chooses one language for the whole app from the languages the main bundle declares (`CFBundleLocalizations` in `.xcodegen/macOS.yml`), and every bundle inside follows it: AppUI's strings, AppKit's own items (Services, Start Dictation, Enter Full Screen), Sparkle and, as far as we know, the Chromium engine. A language missing from that list is never shown, however complete. A key missing from the chosen language's table shows **as the bare key**, not as English, which is why a shipped language must have a value for every key (see [Untranslated entries](#untranslated-entries)).

## What goes through the catalog

Every string a person reads in Arx's own interface goes through AppUI's catalog: labels, buttons, menus, tooltips, VoiceOver labels and hints, alerts, notifications, errors shown to the person, empty states, onboarding, Settings and its search keywords. Never put a user-facing literal in Swift (`Text("…")`, `Button("…")`, `String(localized: "…")` in a package without a catalog, which is never translated). Build sentences in the catalog with placeholders, not by joining pieces in code; join lists with `ListFormatter` or `.formatted(.list(type: .and))`; format numbers, dates, durations and byte counts with Foundation's formatters for the current locale, never `en_US_POSIX` or a fixed suffix.

Deliberately **not translated**, written in English for every language:

- Log lines, `os_log`/`Logger`, smoke-test markers, Copy Diagnostics text, crash and problem report contents.
- The MCP server's tool, argument and error text, its instructions (`BrowserMCPServer/AutomationInstructions.swift`), the agent skills (`AgentToolsClient/Skill/**`) and the `arx` command line: agents read them, and they are versioned as one text.
- The Feature Flags page (Settings › Advanced › Feature Flags, keys `featureFlags.*`): short-lived switches for people testing betas, named after `ARX_*` variables. Its entries are marked `"shouldTranslate": false`.
- The AppleScript dictionary (`Containers/macOS/Arx.sdef`): its terms are code.
- Test fixtures, previews' sample data, and anything only a developer build shows.
- Product and brand names (below), symbols, URLs, keyboard symbols.

Mark a new catalog entry that must stay English with `"shouldTranslate": false`. The tools skip it, and the check requires its English copy in every shipped language.

## The naming rule

**Translations follow the conventions of localized software for naming.** A menu item, button, setting or system concept is named the way Apple names it in that language in macOS and in Safari. For browser concepts Apple has no term for, use the way Chrome names it in that language, then Firefox. Never invent a literal translation where the platform already has a term: Tab, Window, Favorites, Bookmarks, History, Downloads, Private window, Picture in Picture, Split View, Full Screen, Settings, Extensions, Passwords, Profile, Sidebar, Reader, Find, Reload, Pin Tab, Mute, Copy Link, Quit and the like are in the glossary in Apple's words. The standard menu titles (the app menu, File, Edit, View, History, Window, Help) and their standard items are exactly what macOS and Safari show in that language, Apple's ellipsis and capitalization included: German "Ablage" and "Darstellung", Polish "Plik", Japanese "ファイル", French "Fichier".

When unsure of a platform term: the glossary first; if it isn't there, Apple's term in that language (Safari's and macOS's menus, System Settings, support.apple.com/<locale>/guide/safari and /guide/mac-help); then Chrome's. Add the term to the glossary when you settle it.

## Per-language conventions

| Language | Address (as Apple's macOS) | Capitals | Punctuation | Plural categories | Arx space | macOS Spaces (Apple) |
| --- | --- | --- | --- | --- | --- | --- |
| de | informal du | nouns capitalized, otherwise sentence case | „…“, a space before … in menu items ("Drucken …") | one, other | Raum | Spaces |
| es | informal tú (Spain) | sentence case | “…”, ¿ ¡, … with no space | one, other (many optional) | sección | Spaces, un Space |
| fr | formal vous | sentence case | « … » and a non-breaking space before : ; ! ? and inside guillemets; … with no space | one, other (many optional) | section | Spaces, un espace |
| ja | polite です・ます, no pronoun | — | full-width 、。：（）！？, 「」, ＞ in menu paths, no space between Japanese and Latin | other | スペース | 操作スペース |
| pl | informal ty (pronouns dropped) | sentence case | „…”, … with no space | one, few, many, other | strefa | przestrzenie |
| ru | formal Вы, capitalized | sentence case | «…», … with no space | one, few, many, other | раздел | пространства Spaces |
| uk | formal ви, lowercase | sentence case | «…», apostrophe ʼ (U+02BC) | one, few, many, other | розділ | простори |
| zh-Hans | informal 你 | — | full-width ，。：；！？（）, “”, a half-width space between Chinese and Latin | other | 分区 | 空间 |

- **Title case** is English only. Every other language writes menu items and buttons in sentence case (German capitalizes its nouns, as always).
- **Ellipsis**: the single character `…` (U+2026), never three dots, wherever English has one (a command that asks for more before acting).
- **Plurals**: the catalog's plural variations, with every category the language requires. Japanese and Chinese have one form, `other`, with a counter word ("%lld 個のタブ", "%lld 个标签页"). Slavic languages need all four. French and Spanish may add `many` for large round numbers. Every category keeps the number's placeholder.
- **Placeholders** (`%@`, `%lld`, `%d`, `%1$@`, `%%`) are kept exactly, the same ones as many times as in English. When the grammar needs a different order, number them to the English order: English "Close %lld tabs in %@" becomes "In %2$@ %1$lld Tabs schließen". Unnumbered placeholders must stay in the English order. Never translate the text inside a placeholder or add one.
- **Untouched**: keyboard symbols (⌘ ⌥ ⌃ ⇧ ↩ ⇥ ⌫), `›` in Settings paths (translate the names between them as the Settings tabs are named), URLs, file names, product and brand names.
- **Length**: German, French, Spanish, Polish, Russian and Ukrainian run 20 to 30 percent longer than English. Buttons, menu items, segmented controls, sidebar rows and Settings tabs are narrow: use Apple's short forms (German "Tab", not "Registerkarte") and keep labels to a few words. The `hint` in an export names narrow kinds of text.
- **Address**: use the language's form consistently, including in error messages and onboarding.

## Arx's own terms

From [LANGUAGE.md](LANGUAGE.md). Coined names that act as product names stay in English in every language, in Latin script, never transliterated, never declined (Slavic languages inflect a noun in front instead: "в окне Little Arx"). Descriptive feature names are translated with the platform's words. The glossaries hold the exact forms; this table is the decision.

| Term | Decision | Why |
| --- | --- | --- |
| Arx | English everywhere | the brand |
| Little Arx | English everywhere | a named product window built on the brand |
| Peek | English everywhere | a coined feature name, short, and comparable browsers keep such names (Firefox View) |
| Air Traffic Control | English everywhere | a coined name and a metaphor a literal translation would lose |
| Runway | English everywhere | the profile picker's coined name, paired with Air Traffic Control |
| bang (`!g`) | English everywhere | DuckDuckGo and Kagi keep "bang" in every language |
| WebKit, Chromium, MCP, iCloud, Touch ID, Safari, Chrome, Google | English everywhere | product names |
| PiP | "PiP" everywhere except zh-Hans 画中画 | the common abbreviation; Apple's Chinese uses 画中画 even where English says PiP |
| PagePiP ("Page PiP") | the language's "page" plus PiP: Seiten-PiP, PiP de page, PiP de página, PiP strony, PiP страницы, PiP сторінки, ページPiP, 网页画中画 | describes what it is |
| Picture in Picture, Split View, Full Screen, Favorites, Pinned tab, Tab group, Profile, Sidebar, Reader | Apple's terms in that language (Split View stays English except zh-Hans 分屏浏览) | the naming rule |
| Space (an Arx space) | translated, never the word for macOS Spaces: de Raum, es sección, fr section, ja スペース, pl strefa, ru раздел, uk розділ, zh-Hans 分区 | Apple's word for Spaces is taken in every language; where it keeps "Spaces" in English (de, es, fr) the English is taken too |
| Tab Archive | translated: Tab-Archiv, Pestañas archivadas, Onglets archivés, タブアーカイブ, Archiwum kart, Архив вкладок, Архів вкладок, 标签页归档 | a descriptive list name |
| Clean Copy, Copy Clean Link | translated (Copy Clean Link: Bereinigten Link kopieren, Copier le lien propre, …) | a command must say what it does; Firefox translates "Copy Link Without Site Tracking" |
| Proxy Link | translated with the language's word for proxy: Proxy-Link, Lien proxy, Enlace proxy, Łącze proxy, Прокси-ссылка, Проксі-посилання, プロキシリンク, 代理链接 | descriptive |
| Command bar, Site menu, Media, Empty page, Routing rule, Search shortcut, Badge, Live Calendar, Reading Mode, Battery Saver | translated (Chrome's terms for Reading mode and Energy Saver) | descriptive or Chrome's |
| Incognito | Chrome's term in that language | Arx's private windows are named after Chrome's |
| Chrome Web Store | as Google names it in that language (Интернет-магазин Chrome, Chrome ウェブストア, …) | Google localizes it |
| OS workspace (a macOS Space in our English) | Apple's word for Spaces | it is the macOS concept |

Where Apple localizes a product name, use Apple's form: zh-Hans Finder is 访达, Dock 程序坞, Mission Control 调度中心.

## Adding or changing a string

1. Add the entry to `AppUI.xcstrings` in English with `"extractionState": "manual"` and `"generatesSymbol": false`, as the others; use plural variations for counts; add a `"comment"` when the context isn't obvious from the key (what the placeholder is, where it shows). Use the accessor in code.
2. Changing English: edit the `en` value only. The translations made from the old English become **stale**: `make localization-check` lists them, `make localization-export` exports them again with the current translation, and `make localization-check ARGS='--lang <code> --mark-stale'` sets them to `needs_review` in the catalog, as Xcode does when English is edited there. Don't delete them: until they are redone, a stale translation is better than the bare key.
3. Renaming a key: rename it in every language; the import's record follows on the next import.
4. When a language ships, the new or changed string must be translated into it before `make check` passes: export that language, translate the few entries, import them.
5. Run `make localization-check` (and `make check`).

## Untranslated entries

A shipped language needs a value for every key, including entries nobody translates (`shouldTranslate: false`, symbols such as "⌘K", addresses, and a value that is only one name the language keeps in English, such as a lone "Peek" or, in German, "Tabs"; a value with `…` is always translated, since languages place it differently). `make localization-check ARGS='--lang <code> --fill'` writes the English into those entries for that language; the check reports them as errors for a shipped language until it has. Refresh it the same way after their English changes.

## Commands

All run with the mise Python through Make; see `Scripts/localization.py`.

- `make localization-export ARGS='--lang <code> [--chunk-size N] [--out DIR] [--force]'`: writes every entry the language still needs (state `missing`, `needs_review`, `new`, `stale`, or `incomplete` plural categories) to `DIR/chunk-NNN.json` (default `build/localization/<code>/`, 120 entries a chunk), with `glossary.md` and `index.json`. Each entry has `key`, `english` (a string, or `{category: text}` for a plural), `state`, `comment` and `hint` when there are any, `categories` for plurals, `placeholders`, and `current` when a translation exists. It refuses a directory that still holds `*.translated.json` unless `--force`.
- `make localization-import ARGS='--lang <code> --from DIR [--validate-only]'`: reads every `*.translated.json` in DIR (or one file), shaped `{"translations": {"key": "text", "plural.key": {"one": "…", "other": "…"}}}`. It refuses the whole import, listing each key and why, when a key is unknown or marked shouldTranslate false, a value is empty, the placeholders aren't the English ones (as a multiset, and in order unless numbered), or the plural categories aren't the language's. Otherwise it writes each as `translated` and records its English in `Localization/sources.json`. It keeps the catalog's own formatting (indentation, `": "` or Xcode's `" : "`, key order, the final newline), so only the imported entries change, and importing twice changes nothing. Other languages are never touched. `--validate-only` checks and writes nothing.
- `make localization-check [ARGS='--lang <code> --github --mark-stale --fill --no-sources']`: per language, missing translations, needs_review and stale ones, placeholder and plural problems, values identical to English that aren't brand names, symbols or URLs, leading or trailing whitespace that differs from English, and glossary terms whose required translation doesn't appear (a warning: inflection makes it approximate); then, advisory, AppUI keys no Swift source names and Swift literals that look like interface text. Errors count only for shipped languages, and for `CFBundleLocalizations` and the InfoPlist catalog. `--github` prints workflow annotations, as `make style` does. `make check` runs the failing part for the shipped languages.

## Adding a language

1. Add its code to `PLURALS_REQUIRED` (and `PLURALS_OPTIONAL`, `INFLECTED`, `LANGUAGE_NAMES`) in `Scripts/localization.py` with its CLDR plural categories, and to `planned` in `Localization/languages.json`.
2. Write `.agents/localization/glossary.<code>.md` in the same shape as the others: the language rules (address, punctuation, plurals, Apple's word for macOS Spaces and the Arx space word), then the table `English | Translation | Kind | Status | Check | Note`. Status is `verified` (checked against Apple's shipped strings or a localized Apple, Google or Mozilla help page), `standard` (an established term not looked up), `decided` (an Arx term) or `unverified`. Check is `yes` when the advisory glossary check may use the row.
3. Export, translate (`.agents/localization/translator-brief.md`), import, check.

## Shipping a language

1. `make localization-check ARGS='--lang <code>'` reports nothing missing and no placeholder or plural problems; review the warnings.
2. `make localization-check ARGS='--lang <code> --fill'`.
3. Add the code to `shipped` in `Localization/languages.json` and to `CFBundleLocalizations` in `.xcodegen/macOS.yml`, then `make project` and `make check`.
4. Build Arx Dev, pick the language for it in System Settings › General › Language & Region › Applications, and look: menus, Settings, the sidebar, a permission prompt, a plural, and the engine's own pages (error pages, PDF viewer, JavaScript dialogs), which should follow the app's language once it is declared. Update the user manual if it says which languages Arx speaks.

## Outside the catalog

Known gaps, to fix as the code is touched (the localization ticket, DEV-1291, has the full audit):

- A lower package (services, core) has no catalog and can't import AppUI. It takes its text from the app instead: `AppRelocationClient.live(texts:)` and `WebKitPages.dialogButtons` are filled from AppUI's keys by AppFeature, and errors the person sees are mapped to catalog keys where they are shown (`downloadFailureMessage(_:)` in DownloadsFeature for `BrowserDownloadsClient.Failure`, whose `errorDescription` stays English for agents and logs).
- "Favorites" in exported bookmarks (`MigrationAssistant/BookmarksHTML.swift`) is a folder name inside the exported file, which another browser shows; it stays English.
- English shown from code: App Intents titles and descriptions (`AppFeature/ArxAppIntents.swift`, which has no strings table), AppleScript errors (`AppFeature/AppleScripting.swift`), the agent approval sheet's change summary (`AppFeature/AutomationApprovalView.swift`), the Tab Archive's restore errors (`BrowserCore/ArchivedTab.swift`), default file and folder names for exports and captures.
- Pieces joined in code with " · " or ", " where a catalog format or `ListFormatter` fits better: the media panel's subtitle (`AppUI/Sidebar/SidebarMediaPanel.swift`), the command bar's accessibility title (`AppUI/CommandBar/CommandBar.swift`), the chat composer's attachment row (`AppFeature/AppChats.swift`), Little Arx's subtitle (`AppFeature/AppLittleArxView.swift`), a global shortcut's keys (`AppFeature/AppSettingsView.swift`), the bang rows (`CommandBarFeature/CommandBarFeature.swift`), the downloads row's profile and space (`DownloadsFeature/DownloadsView.swift`), History's row (`HistoryFeature/HistoryPanelView.swift`), the problem report's parts (`FeedbackFeature/ProblemReportView.swift`), autofill cards (`SettingsFeature/AutofillDataView.swift`); and the command-bar calculator's `en_US_POSIX` result (`BrowserCore/CommandCalculator.swift`).
- Chromium's own UI (network error pages, certificate interstitials, the PDF viewer, DevTools, JavaScript dialogs, extension permission warnings) comes from the engine's locale packs. Arx sets no engine locale; Chromium takes the app's language, which is English until another one is declared.
