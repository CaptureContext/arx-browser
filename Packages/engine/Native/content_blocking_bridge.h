#ifndef ARX_CONTENT_BLOCKING_BRIDGE_H_
#define ARX_CONTENT_BLOCKING_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

class Profile;

namespace arx {
// DEV-884. Arx's content blocking is Helium's uBlock Origin component
// (helium::kUBlockOriginComponentId), present in every regular profile.
//
// - On/off is the extension's own enabled state in each profile (a user-action
//   disable reason, which Helium keeps for uBlock across restarts).
// - Block cookie banners and the sites the person turned blocking off for are
//   written to uBlock's chrome.storage.local as `arxContentBlocking`
//   ({cookieBanners, trustedSites, phishingList}); `arx.js`, which
//   content_blocking_overlay.py adds to uBlock, applies them to uBlock's list
//   selection and trusted sites. phishingList (DEV-923) turns the Phishing URL
//   Blocklist on once, next to uBlock's default badware and malware lists.
// - A site with blocking off is a per-site ALLOW rule of Chromium's Ads content
//   setting (ContentSettingsType::ADS), which the site settings bridge reads and
//   writes as "ads"; changes reach uBlock at once.
//
// Main thread. A profile gets this the first time one of its pages, or one of
// its private children's pages, is created, and keeps it until it's destroyed.
void EnsureContentBlocking(Profile* profile);

// Applies to every profile that has it now and to every later one. May be
// called before the engine runs; both default to on and off respectively.
void SetContentBlocking(bool enabled, bool block_cookie_banners);

// Helium's uBlock Origin component (helium::kUBlockOriginComponentId).
inline constexpr char kContentBlockerID[] = "blockjmkbacgjkknlgpkjjiijinjdanf";
}  // namespace arx

// DEV-1019: Hide Element. uBlock's element picker on a page, and the elements
// hidden on sites in a page's profile, which live in uBlock's My filters. The
// browser asks arx.js through uBlock's chrome.storage.local, as with the
// settings: `arxElementPicker` = {tabId, request} opens the picker on that tab,
// `arxShowHiddenElement` = {filter, request} takes a filter out of My filters,
// and arx.js keeps `arxHiddenElements` = {hostname: [filter]} current.
// Ordinary pages only, while uBlock is on in their profile. Exported outside the
// ABI table, so the app still runs on engines built before them. Main thread.

// `json` is the profile's `arxHiddenElements` object ("{}" when there's none),
// borrowed for the call.
typedef void (*ArxHiddenElementsCallback)(void* context, const char* json, size_t length);

extern "C" {
// Opens uBlock's element picker on `page`, an http(s) page whose site has
// blocking on (not trusted, so a picked filter applies). False when it can't.
__attribute__((visibility("default")))
bool ArxEngineStartElementPicker(uint64_t page);

// Reads the elements hidden in `page`'s profile. False, and no callback, when
// it can't; otherwise `done` runs exactly once, later, on the main thread.
__attribute__((visibility("default")))
bool ArxEngineCopyHiddenElements(uint64_t page, ArxHiddenElementsCallback done, void* context);

// Reads arx.js's `arxElementPickerStatus` in `page`'s profile: what it made of
// the last picker ask (see content_blocking_overlay.py), for the extensions
// smoke. As ArxEngineCopyHiddenElements, with that object as `json`.
__attribute__((visibility("default")))
bool ArxEngineCopyElementPickerStatus(uint64_t page, ArxHiddenElementsCallback done, void* context);

// Extensions smoke only: adds `filters`, lines separated by newlines (at most
// 16), to My filters in `page`'s profile, through arx.js's `arxFixtureFilters`.
// Refused outside the extension fixture run.
__attribute__((visibility("default")))
bool ArxEngineAddFixtureFilters(uint64_t page, const char* filters);

// DEV-1201: Arx's own element picker. Adds `filter`, `host##selector` for the
// site of `page`'s committed http(s) URL as the browser names it, to My filters
// in `page`'s profile through arx.js's `arxHideElement`, and the filters reload.
// Refused on a trusted site, for another site, or for a selector that is more
// than a plain CSS selector (a scriptlet, an HTML filter or an action operator).
// A null `filter` writes nothing and says whether the page's site would take one.
__attribute__((visibility("default")))
bool ArxEngineHideElement(uint64_t page, const char* filter);

// Takes `filter`, one line of My filters as `arxHiddenElements` lists it, out
// of My filters in `page`'s profile. The page shows the element after a reload.
__attribute__((visibility("default")))
bool ArxEngineShowHiddenElement(uint64_t page, const char* filter);
}

#endif  // ARX_CONTENT_BLOCKING_BRIDGE_H_
