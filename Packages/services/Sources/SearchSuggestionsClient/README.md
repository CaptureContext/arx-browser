# SearchSuggestionsClient

Asks the profile's search engine for search suggestions for the text typed in the command bar. `CommandBarFeature` uses it as `@Dependency(\.searchSuggestions)`.

## Behaviour

- **`fetch(query, engine)`:** one request to the selected engine's public suggestion endpoint. Google, DuckDuckGo, Bing, Brave, Ecosia and Startpage use their own services. Kagi and Perplexity return no remote suggestions; there is no fallback to Google. Google includes `client=firefox` and the system language as `hl`, with an ephemeral session: no cookies, credentials or cache. It returns the suggestions in the provider's order, or throws for anything other than a 200 response in the expected `["query", [suggestions…]]` shape.
- **`isAvailable`:** false for test runs (XCTest environment keys), headless runs (`--headless`), smoke fixtures (`ARX_ENGINE_PROFILE` or `--arx-…` options) and when `ARX_SKIP_REMOTE_SUGGESTIONS` is set. The command bar never asks while it's false.
- The profile setting and private windows are the command bar's business: this client doesn't know about either.

## Testing

`testValue` and `previewValue` are unavailable and return nothing, so no test or preview sends a request. `SearchSuggestionsTests` covers the request, the response parsing and the availability rules.

## Provider formats

The services use the OpenSearch JSON array format. Chromium's [provider definitions](https://chromium.googlesource.com/external/search_engines_data/+/bb68ee4c8974244152fcdc91fef6c944811b0577%5E%21/) include Brave and Startpage, and its [suggestion parser](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/omnibox/browser/search_suggestion_parser.cc) reads the suggestion list at index 1. Brave's [own browser integration](https://github.com/brave/brave-ios/issues/3745) specifies `rich=false`, which Arx also sends to request plain suggestions. HTTP errors and invalid response shapes show local results only.
