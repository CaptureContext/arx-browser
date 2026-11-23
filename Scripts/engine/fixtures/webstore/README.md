# Recorded Chrome Web Store package

`bcjindcccaagfpapjjmafapmmgkkhgoa.crx` is JSON Formatter 0.10.2 by Callum Locke, exactly as the Chrome Web Store served it on 2026-11-10:

```
https://clients2.google.com/service/update2/crx?response=redirect&prodversion=156.0.8078.47&acceptformat=crx3&x=id%3Dbcjindcccaagfpapjjmafapmmgkkhgoa%26installsource%3Dondemand%26uc
```

SHA-256 `5e0ebde71ee60f997a9f5fc0850e6ae4a9f67006dbf662f00507f99e957c2b21`, 20,840 bytes. It is a CRX3 signed with the developer's key and Google's Web Store publisher key, so `make webstore-install-smoke` verifies it with Chromium's real publisher-proof check without the network. Don't modify it: any change breaks the signature, which is the point of the smoke's "corrupt" variant.

JSON Formatter is BSD-3-Clause licensed (https://github.com/callumlocke/json-formatter). Its license is in `LICENSE` beside the package. The package is a test fixture only and never ships in Arx, so it isn't listed in `THIRD_PARTY_NOTICES.md`.

## A second version for the update smoke (DEV-776)

`make webstore-install-smoke` also updates the installed item when `bcjindcccaagfpapjjmafapmmgkkhgoa-next.crx` sits beside this package: a newer store version of the same item, recorded the same way. The store serves only an item's latest version (older `prodversion` values get 204, checked on 2026-11-11), so it can't be recorded until JSON Formatter publishes a version after 0.10.2. Until then the smoke runs the up-to-date and corrupt-package update phases and prints `ARX_WEBSTORE_UPDATE_SMOKE_NEWER_SKIPPED`. The redirect's file name shows the store's current version without downloading it:

```
curl -s -o /dev/null -w '%{redirect_url}\n' 'https://clients2.google.com/service/update2/crx?response=redirect&prodversion=156.0.8078.47&acceptformat=crx3&x=id%3Dbcjindcccaagfpapjjmafapmmgkkhgoa%26installsource%3Dondemand%26uc'
```

When it ends in something newer than `_0_10_2_0.crx`, download that URL to `bcjindcccaagfpapjjmafapmmgkkhgoa-next.crx` unmodified and record its SHA-256 and size here.
