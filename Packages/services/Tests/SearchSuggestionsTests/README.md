# SearchSuggestionsTests

Covers `SearchSuggestionsClient`: each provider's request and query encoding, Google's language parameter, and the absence of cookies, credentials and caching, reading the `["query", [suggestions…]]` response and rejecting other shapes, and which launches may ask at all. No request reaches the network; live endpoint availability is checked separately. Kagi and Perplexity have no anonymous endpoint configured.
