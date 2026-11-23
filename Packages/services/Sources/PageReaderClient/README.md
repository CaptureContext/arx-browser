# PageReaderClient

Reading mode's reader (DEV-1028). `PageReaderClient` (`pageReader`) says whether a page looks like it has an article and reads the article, both in the engine's developer world, which the page can't see. `isEnabled` is the `ARX_READING_MODE` feature flag (`ReadingMode` in BrowserCore).

`PageReaderScripts` are the scripts it runs:

- `probe` is Readability's `isProbablyReaderable`, which looks at the page's paragraphs without parsing it.
- `extract` parses a copy of the page with Readability, so the page is never touched, and cuts the article's markup down to text markup: scripts, styles, frames, forms, media and SVG go, unknown elements give way to their contents, and only plain attributes stay, with every `href`, `src`, `srcset` and `cite` made absolute and http(s), `mailto:` or a `data:` image only. It returns the article's details and the markup's first slice and keeps the rest on the developer world's global.
- `slice(from:)` reads the next slice, each well under the engine's 256 KB result, and the last one lets the markup go.

`PageReader` runs them with any `EvaluateScript`, asking a busy tab again a few times, and puts the `ReaderArticle` together from its slices. Nothing is read from private pages, WebKit pages or pages that aren't http(s): the engine refuses them.

## Readability

`Resources/Readability.js` and `Resources/Readability-readerable.js` are Mozilla Readability 0.6.0 (<https://github.com/mozilla/readability>, the `@mozilla/readability` npm package), under the Apache License 2.0 (`Resources/Readability-LICENSE.md`, and `Distribution/Licenses/Apache-2.0.txt`). They're the package's files with their comments and indentation taken out, so the extraction script fits the engine's 64 KB source limit: `python3 Scripts/strip_js.py` does that, and checks that every line it keeps is the original's, word for word. The originals' SHA-256 are `34dcab3d…f174` (`Readability.js`) and `a98d2880…de65` (`Readability-readerable.js`).

Depends on BrowserCore, BrowserEngineClient and `_Dependencies`. ViewerItemFeature reads with it.
