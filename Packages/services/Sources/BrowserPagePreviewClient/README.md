# BrowserPagePreviewClient

Pictures and site details for hover cards of tabs whose page isn't loaded (DEV-730, DEV-1142).

## Boundaries

Depends on BrowserCore and dependency support. It owns no renderer: pictures of pages come from the capture client in AppFeature, which hands finished JPEGs to the store. Site details are fetched outside Chromium with `URLSession`. A profile's cookies reach a request only as `PageFetchCredentials`, which the caller builds from the engine's cookie reader (DEV-1142).

## Public surface

`BrowserPagePreviewClient` is the dependency AppFeature uses: `picture`, `store`, `retain`, `removeSince` (clearing a profile's history), `removeProfiles`, `details` and `image`. `live(directory:)` backs it with the two types below.

`BrowserPagePreviewStore` keeps the last picture of each page per profile, so a card keeps one after its tab unloads. Each profile has its own folder, `<directory>/<profile UUID>/`, with one JPEG per page named by the SHA-256 of its address; the file's modification date is when the picture was taken. It holds at most 256 pictures / 32 MiB per profile, evicting the oldest, and accepts only http(s) pages and JPEGs up to 512 KiB. `retain(_:in:)` drops pages no tab points at, `remove(_:since:)` deletes pictures taken since a moment (or all), and `remove(_:)` deletes removed profiles. A picture carries when its capture started; one started before its profile's last deletion is refused, so a capture still in flight during Clear History never recreates the folder. Profiles are sandboxes: nothing is read across folders. Private windows never reach the store; AppFeature checks before every read and write.

`PageDetailsFetcher` reads a page's Open Graph / Twitter card / `<title>` and description from its `<head>`, and its published picture, with an ephemeral session that keeps no cookies, cache or credentials and sends no referrer. Without `PageFetchCredentials` it sends no cookie. With them (DEV-1142), a request to the page's own host (exact host, ignoring case; same-site would need the public suffix list) carries the `Cookie` header built from the cookies the profile would send that address, read again for every redirect hop, and every other host, a picture's or a redirect's, gets none. A reply's `Set-Cookie` goes nowhere. Only http(s) addresses without credentials are fetched, redirects stay on http(s), password prompts are cancelled, the document is read up to `</head>` or `<body>` outside comments and script or style bodies (at most 512 KiB) and a picture at most 4 MiB.

`PagePictureCodec` decodes bounded images to card size and encodes JPEGs off the main actor.

## Testing

BrowserPagePreviewTests cover the store's profile isolation, history clearing, pruning and bounds, the parser, and the fetcher's requests through a stub protocol (no cookies, no referrer, refused redirects and oversize bodies), the Open Graph and Twitter pictures, a page without one, a relative picture after a redirect, and the profile's cookies reaching only the page's host (DEV-1142).
