# DefaultBrowserTests

Covers `DefaultBrowserClient.status()` and `makeDefault()` with test doubles for every result in DEV-699: accepted (with `https` following `http`, and with `https` asked for separately), declined (the prompt throws, or returns without a change, and isn't asked twice), already default and unavailable. Also covers which launches may use the system at all. The live Launch Services calls and macOS's confirmation aren't exercised here; they need the running app.
