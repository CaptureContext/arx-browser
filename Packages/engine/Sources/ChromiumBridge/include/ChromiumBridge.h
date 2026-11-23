#ifndef ARX_CHROMIUM_BRIDGE_H
#define ARX_CHROMIUM_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ABI53 (DEV-906): next and previous track, the artist and artwork in media
// snapshots.
// ABI54 (DEV-949, DEV-948, DEV-950): page full screen and call media actions.
// ABI55 (DEV-885): web notifications' clicks, windows and page activation.
// ABI56 (DEV-971, DEV-851, DEV-968, DEV-973, DEV-963): private PDF reads for the
// app, link-menu downloads, the publisher in install reviews, private windows
// in chrome.windows and page permission prompts drawn by the app.
// 57 is DEV-996's translation world and 58 DEV-1009/1016's frozen pages and renderer ends;
// 59 is DEV-1065's main-frame document count, 60 DEV-1111/1118's hovered link for the
// app's link status, and 61 DEV-1101's page colors. 62 is overnight entry M's: the
// ⌘ keys a page used (DEV-1264, DEV-1073) and the native changes beside it. The
// coordinator assigns the batch's release ABI.
#define ARX_ENGINE_ABI_VERSION 62

// ABI22 extension windows. One ordinary page's place in an Arx window: the
// window's AppKit window number (0 = in no window), its position among that
// window's pages, whether it is the window's active page and whether it is
// shown (highlighted).
typedef struct {
  uint64_t page;
  int64_t window_number;
  int32_t index;
  bool active;
  bool highlighted;
} ArxExtensionTabPlacement;

// ABI22 sign-in prompts an unattended run refused for a page's current document.
typedef enum {
  ARX_USER_ACTION_WEB_AUTHENTICATION = 1u << 0,
  ARX_USER_ACTION_FEDERATED_SIGN_IN = 1u << 1,
} ArxUserActionRequest;

// ABI55 (DEV-885) what happened while a web notification click ran.
typedef enum {
  // A service worker's notification (registration.showNotification), rather
  // than one a page made with new Notification().
  ARX_NOTIFICATION_PERSISTENT = 1u << 0,
  // The site's page or service worker already brought a tab forward
  // (page_activation_requested) or opened one (notification_window_requested).
  ARX_NOTIFICATION_HANDLED = 1u << 1,
  // The page that made a non-persistent notification is gone; Chrome would
  // have opened the origin in a new tab.
  ARX_NOTIFICATION_PAGE_GONE = 1u << 2,
} ArxNotificationClickFlag;

// ABI50 (DEV-857) how an external_link_requested link started.
typedef enum {
  // The page's request carried a user gesture.
  ARX_EXTERNAL_LINK_USER_GESTURE = 1u << 0,
  // A client or server redirect reached the link (a sign-in callback's last hop).
  ARX_EXTERNAL_LINK_REDIRECT = 1u << 1,
  // The page is in a private (off-the-record) profile; profile_key is NULL.
  ARX_EXTERNAL_LINK_PRIVATE = 1u << 2,
} ArxExternalLinkFlag;

// ABI19 developer tools: one Arx-owned frontend per inspected page, in that
// page's exact browsing context; no remote debugging port. Docked in the page
// since ABI42 (DEV-733), or in its own window when DevTools' Dock side menu
// undocks it.
typedef enum {
  ARX_DEVTOOLS_OPENED = 0, ARX_DEVTOOLS_UNAVAILABLE = 1, ARX_DEVTOOLS_INVALID = 2,
} ArxDevToolsStatus;

// ABI42. Where an open DevTools is. PENDING: the frontend hasn't said yet; place
// it docked. The side is DevTools' own preference, kept per profile.
typedef enum {
  ARX_DEVTOOLS_DOCK_PENDING = 0,
  ARX_DEVTOOLS_DOCK_RIGHT = 1,
  ARX_DEVTOOLS_DOCK_LEFT = 2,
  ARX_DEVTOOLS_DOCK_BOTTOM = 3,
  ARX_DEVTOOLS_UNDOCKED = 4,
} ArxDevToolsDock;

// ABI42. view is the docked frontend's NSView, borrowed, or NULL when undocked.
// The frontend fills the page's area; the page goes at x, y, width, height
// inside it (DIP, origin top-left), which DevTools' divider changes. An empty
// size means the page fills the area.
typedef struct {
  ArxDevToolsDock dock;
  void *view;
  double x, y, width, height;
} ArxDevToolsLayout;

// ABI16 explicit durable retirement. Queued is not erasure. Paths and kernel
// boot identifiers remain private. Arrays/strings are borrowed during callback.
typedef enum {
  ARX_RETIREMENT_OK = 0, ARX_RETIREMENT_BUSY = 1, ARX_RETIREMENT_INVALID = 2,
  ARX_RETIREMENT_CORRUPT = 3, ARX_RETIREMENT_OWNERSHIP_CHANGED = 4,
  ARX_RETIREMENT_NOT_REGISTERED = 5, ARX_RETIREMENT_RETIRED = 6,
  ARX_RETIREMENT_STALE = 7, ARX_RETIREMENT_LIMIT = 8, ARX_RETIREMENT_IO = 9,
  ARX_RETIREMENT_PENDING = 10, ARX_RETIREMENT_VERIFIED = 11,
  ARX_RETIREMENT_UNAVAILABLE = 12,
} ArxProfileRetirementStatus;
typedef enum {
  ARX_RETIREMENT_ACTIVE = 0, ARX_RETIREMENT_AWAITING_STARTUP = 1,
  ARX_RETIREMENT_QUARANTINE_PENDING = 2, ARX_RETIREMENT_RESTART_REQUIRED = 3,
  ARX_RETIREMENT_VERIFICATION_PENDING = 4, ARX_RETIREMENT_ERASED = 5,
  ARX_RETIREMENT_BLOCKED = 6,
} ArxProfileRetirementProgress;
typedef struct {
  const char *profile_id, *request_id;
  bool legacy_storage;
  ArxProfileRetirementProgress progress;
} ArxProfileRetirementRecord;
typedef struct {
  uint64_t revision;
  bool durable;
  const ArxProfileRetirementRecord *records;
  size_t record_count;  // At most 128, including ordinary active profiles.
} ArxProfileRetirementSnapshot;

// Staged additive scroll API; release ABI number is assigned at the combined freeze.
// One physical axis and finite CSS-pixel delta in [-8192,8192]. Negative zero
// is canonicalized to zero. All reference mutations share replay/physical limits.
typedef enum { ARX_SCROLL_HORIZONTAL = 0, ARX_SCROLL_VERTICAL = 1 } ArxScrollAxis;
typedef enum {
  ARX_SCROLL_NOT_DISPATCHED = 0, ARX_SCROLL_DISPATCHED = 1,
  ARX_SCROLL_POSSIBLY_DISPATCHED = 2, ARX_SCROLL_UNCHANGED = 3,
} ArxScrollDisposition;
typedef enum {
  ARX_SCROLL_OK = 0, ARX_SCROLL_UNAVAILABLE = 1, ARX_SCROLL_NOT_READY = 2,
  ARX_SCROLL_UNSUPPORTED_DOCUMENT = 3, ARX_SCROLL_STALE = 4, ARX_SCROLL_NOT_INTERACTABLE = 5,
  ARX_SCROLL_NOT_AUTHORIZED = 6, ARX_SCROLL_BUSY = 7, ARX_SCROLL_LIMIT = 8,
  ARX_SCROLL_DUPLICATE = 9, ARX_SCROLL_CANCELLED = 10, ARX_SCROLL_TIMEOUT = 11,
  ARX_SCROLL_INVALID = 12, ARX_SCROLL_NO_CONTAINER = 13, ARX_SCROLL_INVALID_DELTA = 14,
} ArxScrollStatus;

// ABI30 file choosers. A page that opens a single or multiple file chooser
// within 3 seconds of an admitted pointer or keyboard action has it held for
// the app; any other chooser is cancelled, as before. accept is the page's
// comma-separated accept types, borrowed until the next call.
typedef struct {
  uint64_t token;
  bool multiple;
  const char *accept;
} ArxFileChooserInfo;
typedef enum {
  ARX_FILE_CHOOSER_OK = 0, ARX_FILE_CHOOSER_STALE = 1, ARX_FILE_CHOOSER_INVALID = 2,
} ArxFileChooserStatus;

// ABI31 page dialogs: a JavaScript dialog the page is showing, or Arx's
// permission sheet for it. message, default_prompt and origin are untrusted
// page data (origin and the permission message come from Chromium), at most
// 4096 bytes each, borrowed until the next call.
typedef enum {
  ARX_PAGE_DIALOG_ALERT = 1, ARX_PAGE_DIALOG_CONFIRM = 2, ARX_PAGE_DIALOG_PROMPT = 3,
  ARX_PAGE_DIALOG_BEFORE_UNLOAD = 4, ARX_PAGE_DIALOG_PERMISSION = 5,
} ArxPageDialogKind;
typedef struct {
  uint64_t token;
  ArxPageDialogKind kind;
  const char *message;
  const char *default_prompt;
  const char *origin;
} ArxPageDialog;
typedef enum {
  ARX_PAGE_DIALOG_OK = 0, ARX_PAGE_DIALOG_STALE = 1, ARX_PAGE_DIALOG_INVALID = 2,
} ArxPageDialogStatus;

// ABI56 (DEV-963) the person's answer to a site permission prompt the app
// draws: Allow, Allow Once (only where the prompt offers it), Block, or a
// dismissal (Cancel, Esc), which never blocks.
typedef enum {
  ARX_PAGE_PERMISSION_ALLOW = 0, ARX_PAGE_PERMISSION_ALLOW_ONCE = 1,
  ARX_PAGE_PERMISSION_BLOCK = 2, ARX_PAGE_PERMISSION_DISMISS = 3,
} ArxPagePermissionDecision;
// A location prompt's accuracy; NONE keeps the prompt's own choice.
typedef enum {
  ARX_PAGE_PERMISSION_ACCURACY_NONE = 0, ARX_PAGE_PERMISSION_ACCURACY_APPROXIMATE = 1,
  ARX_PAGE_PERMISSION_ACCURACY_PRECISE = 2,
} ArxPagePermissionAccuracy;

// ABI13 direct bounded form actions, sharing click receipts and physical slots.
// Payload UTF-8 is borrowed only for this call. It is never returned or logged.
// ABI27 pointer kinds carry real mouse input through the frame's own widget
// and use the same entry point, receipts and physical admission. Their payload
// is canonical ASCII "key=value;" fields in this order, each at most once:
// x, y, tx, ty, to, clicks, modifiers, steps. x/y and tx/ty are main-widget
// viewport points; a point needs the snapshot ID itself as the reference.
// "to" is a drag destination reference of the same snapshot. clicks is 1-3
// (click only), modifiers bits 1 shift, 4 alt, 8 meta (not hover), steps 1-32
// (drag only). The point must hit the reference, or for a point, the
// snapshot's document. A drag completes in the renderer; no platform drag
// session starts. Hover doesn't consume its snapshot: after a dispatched
// hover the snapshot stays current until the DOM version changes.
typedef enum {
  ARX_FORM_REPLACE_TEXT = 1, ARX_FORM_SELECT_VALUE = 2, ARX_FORM_KEYPRESS = 4,
  ARX_FORM_HOVER = 8, ARX_FORM_POINTER_CLICK = 16, ARX_FORM_DRAG = 32,
  // ABI28 keyboard input; both focus the reference first and consume the
  // snapshot. TYPE: UTF-8 text, 1-1024 bytes; each character is a guarded
  // keydown/keypress/keyup at the end of an input, textarea or contenteditable
  // reference, and editing stops once focus or the selection leaves it or
  // reaches password ancestry. LF is Enter (textarea and contenteditable).
  // KEY_CHORD: "<modifiers>:<key>" with bits 1 shift, 2 control, 4 alt,
  // 8 meta and a key name (Enter, Tab, Escape, Backspace, Delete, arrows,
  // Home, End, PageUp, PageDown, F1-F12) or one character. Control, Alt and
  // Meta chords reach page listeners with every default suppressed.
  ARX_FORM_TYPE = 64, ARX_FORM_KEY_CHORD = 128,
  // ABI29 explicit form state; both consume the snapshot and return
  // ARX_FORM_UNCHANGED, firing nothing, when the state already matches.
  // SELECT_VALUES: a JSON array of up to 64 exact option values (at most
  // 4096 bytes) that becomes the whole selection of a native multiple select;
  // each value must match one enabled option. SET_CHECKED: "1" or "0" for a
  // checkbox or radio (a radio can't be unchecked); input and change fire.
  ARX_FORM_SELECT_VALUES = 256, ARX_FORM_SET_CHECKED = 512,
} ArxFormActionKind;
typedef enum {
  ARX_FORM_NOT_DISPATCHED = 0, ARX_FORM_DISPATCHED = 1,
  ARX_FORM_POSSIBLY_DISPATCHED = 2, ARX_FORM_UNCHANGED = 3,
} ArxFormDisposition;
typedef enum {
  ARX_FORM_OK = 0, ARX_FORM_UNAVAILABLE = 1, ARX_FORM_NOT_READY = 2,
  ARX_FORM_UNSUPPORTED_DOCUMENT = 3, ARX_FORM_STALE = 4, ARX_FORM_NOT_INTERACTABLE = 5,
  ARX_FORM_NOT_AUTHORIZED = 6, ARX_FORM_BUSY = 7, ARX_FORM_LIMIT = 8,
  ARX_FORM_DUPLICATE = 9, ARX_FORM_CANCELLED = 10, ARX_FORM_TIMEOUT = 11,
  ARX_FORM_INVALID = 12, ARX_FORM_UNSUPPORTED_CONTROL = 13, ARX_FORM_INVALID_VALUE = 14,
  ARX_FORM_OPTION_NOT_FOUND = 15, ARX_FORM_AMBIGUOUS_OPTION = 16,
  ARX_FORM_OBSCURED = 17,
} ArxFormStatus;

// ABI12 one-use reference activation. Dispatch does not mean website success.
typedef enum {
  ARX_CLICK_NOT_DISPATCHED = 0, ARX_CLICK_DISPATCHED = 1,
  ARX_CLICK_POSSIBLY_DISPATCHED = 2,
} ArxClickDisposition;
typedef enum {
  ARX_CLICK_OK = 0, ARX_CLICK_UNAVAILABLE = 1, ARX_CLICK_NOT_READY = 2,
  ARX_CLICK_UNSUPPORTED = 3, ARX_CLICK_STALE = 4, ARX_CLICK_NOT_INTERACTABLE = 5,
  ARX_CLICK_NOT_AUTHORIZED = 6, ARX_CLICK_BUSY = 7, ARX_CLICK_LIMIT = 8,
  ARX_CLICK_DUPLICATE = 9, ARX_CLICK_CANCELLED = 10, ARX_CLICK_TIMEOUT = 11,
  ARX_CLICK_INVALID = 12,
} ArxClickStatus;

// ABI11 read-only semantic inspection. No form values or raw DOM; inspection
// itself never dispatches an action.
typedef enum {
  ARX_INSPECTION_SUCCESS = 0, ARX_INSPECTION_UNAVAILABLE = 1,
  ARX_INSPECTION_NOT_READY = 2, ARX_INSPECTION_UNSUPPORTED = 3,
  ARX_INSPECTION_STALE = 4, ARX_INSPECTION_LIMIT = 5,
  ARX_INSPECTION_TIMEOUT = 6, ARX_INSPECTION_BUSY = 7,
  ARX_INSPECTION_INVALID = 8, ARX_INSPECTION_CANCELLED = 9,
} ArxInspectionStatus;
typedef struct {
  uint32_t maximum_nodes, maximum_text_bytes, maximum_references;
  uint32_t maximum_output_bytes, timeout_ms;
} ArxInspectionLimits;
// ABI25 inspection windows. window_start is the first projected node index to
// emit; a page projects at most 16384 nodes and each window emits at most
// maximum_nodes. Flags opt into form values (password ancestry, file, hidden
// and payment/one-time inputs stay omitted) and main-widget bounds.
enum { ARX_INSPECTION_FORM_VALUES = 1u << 0, ARX_INSPECTION_BOUNDS = 1u << 1 };
typedef struct {
  ArxInspectionLimits limits;
  uint32_t window_start;
  uint32_t flags;
} ArxInspectionWindow;

// ABI10 ordinary-profile favicon lookup: PNG up to 32px, at most 64 KiB.
// A database miss fetches the site's icon (the app's directory or root page, with
// the profile's cookies for that site, or /favicon.ico; never the saved URL) and
// stores it in that profile (DEV-796, DEV-1108), unless
// set_site_icon_fetch turned that off. Missing is a normal fallback; with an
// icon URL it dropped an icon fetched before DEV-1108 as another host's. Private
// contexts never access the parent cache.
typedef enum {
  ARX_SITE_ICON_SUCCESS = 0, ARX_SITE_ICON_MISSING = 1,
  ARX_SITE_ICON_UNAVAILABLE = 2, ARX_SITE_ICON_INVALID = 3,
  ARX_SITE_ICON_LIMIT = 4, ARX_SITE_ICON_TIMEOUT = 5, ARX_SITE_ICON_BUSY = 6,
} ArxSiteIconStatus;

// ABI9 close approval is a one-use grant for the exact native document.
typedef enum {
  ARX_CLOSE_SUCCESS = 0, ARX_CLOSE_REFUSED = 1, ARX_CLOSE_STALE = 2,
  ARX_CLOSE_BUSY = 3, ARX_CLOSE_CANCELLED = 4, ARX_CLOSE_UNAVAILABLE = 5,
} ArxCloseStatus;

typedef enum {
  ARX_EXTENSION_SUCCESS = 0, ARX_EXTENSION_UNAVAILABLE = 1,
  ARX_EXTENSION_STALE = 2, ARX_EXTENSION_POLICY_BLOCKED = 3,
  ARX_EXTENSION_REVIEW_REQUIRED = 4, ARX_EXTENSION_INVALID_REQUEST = 5,
  ARX_EXTENSION_FAILED = 6, ARX_EXTENSION_LIMIT_EXCEEDED = 7,
  ARX_EXTENSION_TIMEOUT = 8, ARX_EXTENSION_BUSY = 9,
  ARX_EXTENSION_CANCELLED = 10, ARX_EXTENSION_INVALID_PACKAGE = 11,
  // ABI20 unpacked loading. Completion carries {"error": "<detail>"} for these
  // and for a Chromium-reported ARX_EXTENSION_POLICY_BLOCKED load refusal.
  ARX_EXTENSION_DIRECTORY_MISSING = 12, ARX_EXTENSION_DIRECTORY_UNREADABLE = 13,
  ARX_EXTENSION_MANIFEST_INVALID = 14,
  // ABI45 (DEV-776). update_webstore_extension found no newer version in the
  // store. Nothing was asked or changed.
  ARX_EXTENSION_UP_TO_DATE = 15,
} ArxExtensionStatus;
typedef enum {
  ARX_EXTENSION_INSPECT = 0, ARX_EXTENSION_ENABLE = 1,
  ARX_EXTENSION_DISABLE = 2, ARX_EXTENSION_REMOVE = 3,
  // ABI20: reread an installed unpacked extension from its own directory.
  ARX_EXTENSION_RELOAD = 4,
  // DEV-889: let the extension run in private windows, or stop it. Chromium's
  // per-extension incognito switch; Chromium reloads an enabled extension.
  // Allowed only where the inventory says canAllowInPrivate. Engines before
  // DEV-889 answer INVALID_REQUEST and their inventory has no such field.
  ARX_EXTENSION_ALLOW_PRIVATE = 5, ARX_EXTENSION_DISALLOW_PRIVATE = 6,
  // Refused unless this exact bundled fixture lives in native-owned fresh storage.
  ARX_EXTENSION_FIXTURE_REQUIRE_PERMISSIONS = 100,
} ArxExtensionAction;

typedef enum {
  ARX_MEDIA_SUCCESS = 0, ARX_MEDIA_STALE = 1, ARX_MEDIA_UNAVAILABLE = 2,
  ARX_MEDIA_UNSUPPORTED = 3, ARX_MEDIA_TIMEOUT = 4, ARX_MEDIA_CANCELLED = 5,
  ARX_MEDIA_BUSY = 6,
} ArxMediaStatus;
typedef enum {
  ARX_MEDIA_PLAY = 0, ARX_MEDIA_PAUSE = 1,
  ARX_MEDIA_ENTER_PICTURE = 2, ARX_MEDIA_EXIT_PICTURE = 3,
  ARX_MEDIA_ENTER_AUTOMATIC_PICTURE = 4,
  // ABI32: start seek_media instead; perform_media replies unsupported.
  ARX_MEDIA_SEEK = 5,
  // ABI53 (DEV-906): the session's next and previous track. They complete
  // once the session has the request, as nothing on the page reports them.
  ARX_MEDIA_NEXT_TRACK = 6,
  ARX_MEDIA_PREVIOUS_TRACK = 7,
  // ABI54 (DEV-948): a call's Media Session actions (togglemicrophone,
  // togglecamera, hangup). They succeed once the site's handler is asked; the
  // site reports the result through setMicrophoneActive and setCameraActive.
  ARX_MEDIA_TOGGLE_MICROPHONE = 8, ARX_MEDIA_TOGGLE_CAMERA = 9, ARX_MEDIA_HANG_UP = 10,
} ArxMediaAction;
enum {
  ARX_MEDIA_CAN_PLAY = 1, ARX_MEDIA_CAN_PAUSE = 2,
  ARX_MEDIA_CAN_ENTER_PICTURE = 4, ARX_MEDIA_CAN_EXIT_PICTURE = 8,
  ARX_MEDIA_CAN_ENTER_AUTOMATIC_PICTURE = 16,
  ARX_MEDIA_CAN_SEEK = 32,
  // ABI53 (DEV-906).
  ARX_MEDIA_CAN_NEXT_TRACK = 64,
  ARX_MEDIA_CAN_PREVIOUS_TRACK = 128,
  // ABI54 (DEV-948).
  ARX_MEDIA_CAN_TOGGLE_MICROPHONE = 256, ARX_MEDIA_CAN_TOGGLE_CAMERA = 512,
  ARX_MEDIA_CAN_HANG_UP = 1024,
};
// ABI54 (DEV-948). A call's microphone and camera, as the site reports them
// with navigator.mediaSession.setMicrophoneActive and setCameraActive.
typedef enum {
  ARX_MEDIA_DEVICE_UNKNOWN = 0, ARX_MEDIA_DEVICE_OFF = 1, ARX_MEDIA_DEVICE_ON = 2,
} ArxMediaDeviceState;
// Ordinary profiles only. Strings are borrowed during media_changed. Playback: 0 inactive, 1 playing, 2 paused.
typedef struct {
  uint64_t generation, revision;
  bool present, video, picture;
  int playback;
  uint32_t actions;
  const char *title, *origin;
  // ABI53 (DEV-906). Media Session's artist, empty when none, and its artwork
  // as PNG bytes (at most 256 pixels on a side, NULL and 0 until it has
  // loaded or when there's none), both borrowed during media_changed. A new
  // artwork arrives in a later snapshot with a new revision.
  const char *artist;
  const uint8_t *artwork;
  size_t artwork_size;
  // ABI54 (DEV-948). The page is in a call: it captures the camera or the
  // microphone and its Media Session offers a call action or automatic Picture
  // in Picture. A call is present and playing without a playing player, and
  // its Picture in Picture may be the site's own document (Google Meet's), so
  // picture doesn't imply video. Automatic entry is offered while it's hidden,
  // or showing while Arx isn't the active app.
  bool call;
  ArxMediaDeviceState microphone, camera;
} ArxMediaSnapshot;

// ABI32 one on-demand read of an ordinary observed page's media. generation is
// the current media source's (0 when none); muted is the page's audio mute,
// whether or not it has media. Times are seconds. The position is extrapolated
// from the last native update at the time of the read; duration is negative
// when unknown or unbounded (live).
typedef struct {
  uint64_t generation;
  bool muted;
  bool has_position;
  double position, duration, playback_rate;
} ArxMediaPosition;

typedef struct {
  // Only for a disposable test profile. Does not validate real Keychain storage.
  bool use_mock_keychain_for_testing;
  // Default false until the packaged extension fixture has been verified.
  bool enable_extensions;
  // Creates fresh native-owned temporary storage; ignores profile_path and
  // requires mock Keychain. Never loads from a caller-provided extension path.
  bool extension_fixture_for_testing;
  // Fresh native-owned storage, explicit mock Keychain, fixed loopback fixture.
  // Does not enable production full-document capture.
  bool document_capture_fixture_for_testing;
  // Requires mock Keychain and creates fresh native-owned temporary storage.
  bool gesture_fixture_for_testing;

  // Mutually exclusive developer signed-CRX fixture. Requires mock Keychain
  // and fresh native-owned storage; never used by production admission.
  bool extension_install_fixture_for_testing;

  // ABI44 (DEV-765). Only with extension_install_fixture_for_testing: an
  // http://127.0.0.1:<port> origin that stands in for the Chrome Web Store.
  // webstorePrivate is exposed to it and store packages are downloaded from
  // <origin>/crx/<id>.crx. NULL in every other run.
  const char *webstore_fixture_origin_for_testing;
} ArxEngineRunOptions;

typedef enum {
  ARX_CAPTURE_SUCCESS = 0,
  ARX_CAPTURE_STALE = 1,
  ARX_CAPTURE_LIMIT = 2,
  ARX_CAPTURE_UNAVAILABLE = 3,
  ARX_CAPTURE_TIMEOUT = 4,
  ARX_CAPTURE_UNSUPPORTED = 5,
  ARX_CAPTURE_ENCODING_FAILED = 6,
  ARX_CAPTURE_CANCELLED = 7,
  ARX_CAPTURE_INVALID = 8,
  ARX_CAPTURE_BUSY = 9,
} ArxCaptureStatus;

// ABI26 PDF. Export prints the page; source reads a PDF document's own bytes.
typedef enum {
  ARX_PDF_SUCCESS = 0, ARX_PDF_UNAVAILABLE = 1, ARX_PDF_UNSUPPORTED = 2,
  ARX_PDF_STALE = 3, ARX_PDF_LIMIT = 4, ARX_PDF_FAILED = 5, ARX_PDF_BUSY = 6,
  ARX_PDF_INVALID = 7, ARX_PDF_TIMEOUT = 8, ARX_PDF_CANCELLED = 9,
} ArxPdfStatus;
typedef enum { ARX_PDF_EXPORT = 0, ARX_PDF_SOURCE = 1 } ArxPdfKind;
// Zero scale or paper size keeps Chromium's default (1, US Letter in inches).
// ABI56 (DEV-971): allows_private lets the app's own Print and Save as PDF read
// a private page; the export and the PDF document's bytes stay in memory. MCP
// never sets it, so private pages stay refused there.
typedef struct {
  bool landscape, print_background, allows_private;
  double scale, paper_width, paper_height;
} ArxPdfOptions;

typedef struct {
  uint32_t maximum_dimension, maximum_pixels, maximum_encoded_bytes, timeout_ms;
} ArxCaptureLimits;

// PNG bytes and document identity are borrowed only during capture_completed.
typedef struct {
  const char *document_id;
  const uint8_t *png;
  size_t png_size;
  uint32_t width, height;
  double viewport_width, viewport_height, device_scale;
  bool was_loading;
} ArxCaptureSnapshot;

// Staged coordinated ABI16 suffix. Borrowed only during document_capture_completed.
// Document/visible/scroll geometry is Blink layout coordinates. Root viewport
// remains DIP; raster_scale is independent of device_scale (initial policy 1).
typedef struct {
  const char *document_id;
  const uint8_t *png;
  size_t png_size;
  uint32_t width, height;
  double document_x, document_y, document_width, document_height;
  double visible_x, visible_y, visible_width, visible_height;
  double scroll_x, scroll_y, zoom_level, page_scale;
  double viewport_width, viewport_height, device_scale, raster_scale;
  bool was_loading;
} ArxDocumentCaptureSnapshot;

// Staged additive link context API; root assigns the coordinated release ABI.
// User-invoked context only. Chromium's filtered URL of any scheme <=2 MiB
// (DEV-853; ABI48 engines before it sent only HTTP(S) on default ports, without
// credentials, <=8192 bytes), own link text <=4096 UTF-8 bytes. No
// selection/form value, unfiltered URL or persistence.
// Coordinates are proven root-page viewport DIP, origin top-left.
typedef struct {
  uint64_t token, document_generation;
  const uint8_t *url, *text;
  size_t url_size, text_size;
  double x, y;
} ArxLinkContext;

// Snapshot strings are borrowed until the callback returns. State follows Chromium:
// 0 in progress, 1 complete, 2 cancelled, 3 interrupted.
typedef struct {
  const char *guid, *url, *target_path, *filename;
  uint64_t source_page;
  int state, interrupt_reason;
  int64_t received_bytes, total_bytes;
  double started_at;
  bool dangerous, missing, private_context;
} ArxDownloadSnapshot;

// ABI34 developer tier (DEV-668). Scripts run in Arx's developer world, an
// isolated world where Blink keeps cookies, password, card and one-time-code
// values and stored credentials unreadable; never the page's main world.
// Console and network logs are kept natively per page, bounded, and read on
// request. Every reply's JSON is bounded and has the page's cookie values
// redacted.
typedef enum {
  ARX_DEVELOPER_OK = 0, ARX_DEVELOPER_UNAVAILABLE = 1, ARX_DEVELOPER_UNSUPPORTED = 2,
  ARX_DEVELOPER_STALE = 3, ARX_DEVELOPER_LIMIT = 4, ARX_DEVELOPER_FAILED = 5,
  ARX_DEVELOPER_BUSY = 6, ARX_DEVELOPER_INVALID = 7, ARX_DEVELOPER_TIMEOUT = 8,
  ARX_DEVELOPER_CANCELLED = 9, ARX_DEVELOPER_EXCEPTION = 10, ARX_DEVELOPER_SYNTAX = 11,
} ArxDeveloperStatus;
typedef enum { ARX_DEVELOPER_LOG_CONSOLE = 0, ARX_DEVELOPER_LOG_NETWORK = 1 } ArxDeveloperLogKind;

// ABI35 saved passwords (DEV-708). Chromium's password manager, per ordinary
// profile; private pages get nothing. No password value crosses this ABI:
// replies carry credential IDs, usernames, origins and outcomes only.
typedef enum {
  ARX_PASSWORD_SAVE = 0, ARX_PASSWORD_NEVER = 1, ARX_PASSWORD_NOT_NOW = 2,
} ArxPasswordSaveAnswer;
typedef enum {
  ARX_SIGN_IN_OK = 0, ARX_SIGN_IN_SIGNED_IN = 1, ARX_SIGN_IN_NEEDS_USER = 2,
  ARX_SIGN_IN_FAILED = 3, ARX_SIGN_IN_UNAVAILABLE = 4, ARX_SIGN_IN_STALE = 5,
  ARX_SIGN_IN_BUSY = 6, ARX_SIGN_IN_INVALID = 7, ARX_SIGN_IN_CANCELLED = 8,
  ARX_SIGN_IN_TIMEOUT = 9,
} ArxSignInStatus;

// ABI36 saved passwords in Settings (DEV-721). One ordinary profile at a time;
// private profiles are refused. Replies carry sites, usernames, counts and
// listing IDs. A password crosses only from an AppKit field the caller lends
// (save) and, after LocalAuthentication, to the pasteboard or a lent field
// (reveal); never through a reply.
typedef enum {
  ARX_SAVED_PASSWORDS_OK = 0, ARX_SAVED_PASSWORDS_UNAVAILABLE = 1,
  ARX_SAVED_PASSWORDS_INVALID = 2, ARX_SAVED_PASSWORDS_STALE = 3,
  ARX_SAVED_PASSWORDS_NOT_FOUND = 4, ARX_SAVED_PASSWORDS_EXISTS = 5,
  ARX_SAVED_PASSWORDS_DENIED = 6, ARX_SAVED_PASSWORDS_BUSY = 7,
  ARX_SAVED_PASSWORDS_FAILED = 8, ARX_SAVED_PASSWORDS_CANCELLED = 9,
} ArxSavedPasswordsStatus;
typedef enum {
  ARX_PASSWORD_REVEAL_COPY = 0, ARX_PASSWORD_REVEAL_SHOW = 1,
} ArxPasswordReveal;

// ABI52 autofill (DEV-875, DEV-893). When a fill asks the device owner (Touch
// ID or the login password) first. A payment card always asks, unless fills
// are refused. REFUSE turns away every fill that would ask: for tests, and
// when LocalAuthentication can't run.
typedef enum {
  ARX_AUTOFILL_ASK_DEVICE_OWNER = 0,
  ARX_AUTOFILL_FILL_PASSWORDS_WITHOUT_ASKING = 1,
  ARX_AUTOFILL_REFUSE_AUTHENTICATED_FILLS = 2,
} ArxAutofillAuthentication;

// ABI52 Settings › Autofill (DEV-893). One ordinary profile at a time; private
// and unknown profiles reply UNAVAILABLE. Replies list addresses and local
// cards (network, last four digits, name, expiry), never a card number.
typedef enum {
  ARX_AUTOFILL_DATA_OK = 0, ARX_AUTOFILL_DATA_UNAVAILABLE = 1,
  ARX_AUTOFILL_DATA_INVALID = 2, ARX_AUTOFILL_DATA_NOT_FOUND = 3,
  ARX_AUTOFILL_DATA_BUSY = 4, ARX_AUTOFILL_DATA_CANCELLED = 5,
  // Adding or editing an address or card while set_autofill_products has
  // that kind off: Chromium keeps none then.
  ARX_AUTOFILL_DATA_DISABLED = 6,
} ArxAutofillDataStatus;

// ABI38 site permissions and per-site zoom in Settings (DEV-716). One ordinary
// profile at a time; private and unknown profiles reply UNAVAILABLE. MANAGED:
// policy, an extension or supervision decides that setting, so a user value
// would have no effect.
typedef enum {
  ARX_SITE_SETTINGS_OK = 0, ARX_SITE_SETTINGS_UNAVAILABLE = 1,
  ARX_SITE_SETTINGS_INVALID = 2, ARX_SITE_SETTINGS_MANAGED = 3,
} ArxSiteSettingsStatus;
typedef enum {
  ARX_SITE_PERMISSION_CAMERA = 0, ARX_SITE_PERMISSION_MICROPHONE = 1,
  ARX_SITE_PERMISSION_LOCATION = 2, ARX_SITE_PERMISSION_NOTIFICATIONS = 3,
  ARX_SITE_PERMISSION_POPUPS = 4, ARX_SITE_PERMISSION_CLIPBOARD = 5,
  // DEV-884. Chromium's Ads setting: ALLOW turns Arx's content blocking off for
  // the site; BLOCK and the default keep it on. Listed as "ads".
  ARX_SITE_PERMISSION_ADS = 6,
} ArxSitePermission;
// DEFAULT removes a site's exception, so the profile's default applies again.
typedef enum {
  ARX_SITE_PERMISSION_SETTING_DEFAULT = 0, ARX_SITE_PERMISSION_SETTING_ALLOW = 1,
  ARX_SITE_PERMISSION_SETTING_BLOCK = 2, ARX_SITE_PERMISSION_SETTING_ASK = 3,
} ArxSitePermissionSetting;

// ABI39 clear browsing data and the downloads location (DEV-647). One ordinary
// profile at a time; private and unknown profiles reply UNAVAILABLE. BUSY: a
// clear is already running for that profile. MANAGED: policy decides the
// downloads location.
typedef enum {
  ARX_PROFILE_DATA_OK = 0, ARX_PROFILE_DATA_UNAVAILABLE = 1, ARX_PROFILE_DATA_INVALID = 2,
  ARX_PROFILE_DATA_BUSY = 3, ARX_PROFILE_DATA_MANAGED = 4,
} ArxProfileDataStatus;
// A mask of what to count or clear. HISTORY and DOWNLOADS clear Chromium's own
// records of visits and finished downloads (never the files); the app keeps its
// own history and download list and counts those itself.
typedef enum {
  ARX_BROWSING_DATA_HISTORY = 1 << 0, ARX_BROWSING_DATA_DOWNLOADS = 1 << 1,
  ARX_BROWSING_DATA_COOKIES = 1 << 2, ARX_BROWSING_DATA_CACHE = 1 << 3,
  ARX_BROWSING_DATA_AUTOFILL = 1 << 4, ARX_BROWSING_DATA_SITE_SETTINGS = 1 << 5,
} ArxBrowsingDataKind;

// ABI33 start_download replies. STARTED names the new item's GUID; FAILED has
// Chromium's interrupt reason and no item. A start with no reply after 30
// seconds replies TIMEOUT, and an item that arrives later is cancelled.
typedef enum {
  ARX_DOWNLOAD_START_STARTED = 0,
  ARX_DOWNLOAD_START_UNAVAILABLE = 1,
  ARX_DOWNLOAD_START_FAILED = 2,
  ARX_DOWNLOAD_START_TIMEOUT = 3,
} ArxDownloadStartStatus;

// Staged browser-created child ownership. Values preserve presentation intent;
// the child already has Chromium's opener/session storage and must not reload.
typedef enum {
  ARX_CONTENTS_FOREGROUND_TAB = 1, ARX_CONTENTS_BACKGROUND_TAB = 2,
  ARX_CONTENTS_WINDOW = 3, ARX_CONTENTS_POPUP = 4,
} ArxNewContentsDisposition;

// All calls and callbacks run synchronously on the macOS main thread.
// Strings and callback payloads are borrowed for the duration of the call.
typedef enum {
  ARX_EXTENSION_VIEW_OPTIONS = 1,
  ARX_EXTENSION_VIEW_ACTION = 2,
} ArxExtensionViewKind;

// ABI45 (DEV-795) page menu: a right click on the page itself (no link,
// editable field, selection, image or media). Titles come from
// configure_page_menu, one per item in this order.
typedef enum {
  ARX_PAGE_MENU_BACK = 0,
  ARX_PAGE_MENU_FORWARD = 1,
  ARX_PAGE_MENU_RELOAD = 2,
  ARX_PAGE_MENU_SAVE_AS = 3,
  ARX_PAGE_MENU_PRINT = 4,
  ARX_PAGE_MENU_VIEW_SOURCE = 5,
  // ABI48 (DEV-818): Share… with the page's address and title.
  ARX_PAGE_MENU_SHARE = 6,
  ARX_PAGE_MENU_ITEM_COUNT = 7,
} ArxPageMenuItem;

// ABI45 (DEV-795) Save Page As formats, as Chrome's save_page_type.
typedef enum {
  ARX_SAVE_PAGE_HTML_ONLY = 0,
  ARX_SAVE_PAGE_COMPLETE = 1,
  ARX_SAVE_PAGE_MHTML = 2,
} ArxSavePageKind;

// ---- ABI48 (DEV-814, DEV-815, DEV-818) context menus: begin ----
// Arx's menus for a right click on a text field, a selection, an image, a
// video or audio. Titles come from configure_context_menus, one per item in
// this order. Items marked "app" go to the app through context_menu_chosen,
// only when context_menu_items allows them; the others run natively. A
// SUBMENU item is only the title of the submenu holding the items after it.
// In LOOK_UP and SEARCH_SELECTION titles, the first "{}" becomes the selection,
// shortened. The DOWNLOAD items save as Chrome's Save Image As does
// (WebContents::SaveFrameWithHeaders: the frame's referrer, Save panel).
typedef enum {
  ARX_CONTEXT_MENU_CUT = 0,
  ARX_CONTEXT_MENU_COPY = 1,
  ARX_CONTEXT_MENU_PASTE = 2,
  ARX_CONTEXT_MENU_PASTE_AND_MATCH_STYLE = 3,
  ARX_CONTEXT_MENU_SELECT_ALL = 4,
  ARX_CONTEXT_MENU_NO_GUESSES = 5,  // Shown disabled for a word with no suggestions.
  ARX_CONTEXT_MENU_LEARN_SPELLING = 6,
  ARX_CONTEXT_MENU_SPELLING = 7,  // Submenu: Spelling and Grammar.
  ARX_CONTEXT_MENU_CHECK_SPELLING_WHILE_TYPING = 8,
  ARX_CONTEXT_MENU_SUBSTITUTIONS = 9,  // Submenu.
  ARX_CONTEXT_MENU_SHOW_SUBSTITUTIONS = 10,
  ARX_CONTEXT_MENU_SMART_QUOTES = 11,
  ARX_CONTEXT_MENU_SMART_DASHES = 12,
  ARX_CONTEXT_MENU_TEXT_REPLACEMENT = 13,
  ARX_CONTEXT_MENU_SPEECH = 14,  // Submenu.
  ARX_CONTEXT_MENU_START_SPEAKING = 15,
  ARX_CONTEXT_MENU_STOP_SPEAKING = 16,
  ARX_CONTEXT_MENU_LOOK_UP = 17,
  ARX_CONTEXT_MENU_SEARCH_SELECTION = 18,  // App.
  ARX_CONTEXT_MENU_SHARE_SELECTION = 19,  // App.
  ARX_CONTEXT_MENU_OPEN_IMAGE_IN_NEW_TAB = 20,  // App.
  ARX_CONTEXT_MENU_DOWNLOAD_IMAGE = 21,  // Save Image As…
  ARX_CONTEXT_MENU_COPY_IMAGE = 22,
  ARX_CONTEXT_MENU_COPY_IMAGE_ADDRESS = 23,
  ARX_CONTEXT_MENU_LOOP = 24,
  ARX_CONTEXT_MENU_SHOW_CONTROLS = 25,
  ARX_CONTEXT_MENU_PICTURE_IN_PICTURE = 26,  // App: ArxPiP, which pages can't enter directly.
  ARX_CONTEXT_MENU_COPY_VIDEO_FRAME = 27,
  ARX_CONTEXT_MENU_OPEN_VIDEO_IN_NEW_TAB = 28,  // App.
  ARX_CONTEXT_MENU_DOWNLOAD_VIDEO = 29,  // Save Video As…
  ARX_CONTEXT_MENU_COPY_VIDEO_ADDRESS = 30,
  ARX_CONTEXT_MENU_OPEN_AUDIO_IN_NEW_TAB = 31,  // App.
  ARX_CONTEXT_MENU_DOWNLOAD_AUDIO = 32,  // Save Audio As…
  ARX_CONTEXT_MENU_COPY_AUDIO_ADDRESS = 33,
  ARX_CONTEXT_MENU_UNDO = 34,
  ARX_CONTEXT_MENU_REDO = 35,
  ARX_CONTEXT_MENU_ITEM_COUNT = 36,
} ArxContextMenuItem;

// One app item the person chose. url is the image's or media's http(s)
// address (at most 8192 bytes, no credentials) for the open items; text is the selection for SEARCH_SELECTION and SHARE_SELECTION, at
// most 4096 UTF-8 bytes cut at a character boundary, never from a password
// field. The others are empty. Borrowed during the callback. x and y are where
// the menu opened, in root-view DIP with the origin top-left.
typedef struct {
  ArxContextMenuItem item;
  const uint8_t *url, *text;
  size_t url_size, text_size;
  double x, y;
} ArxContextMenuChoice;
// ---- ABI48 (DEV-814, DEV-815, DEV-818) context menus: end ----

// ABI48 (DEV-828) run_extension_action's outcome.
typedef enum {
  // The extension's popup is opening, anchored at the point.
  ARX_EXTENSION_ACTION_RUN_POPUP = 0,
  // The action ran with no popup: the extension got its click (action.onClicked).
  ARX_EXTENSION_ACTION_RUN_CLICKED = 1,
  // The page can't run actions now: unknown, private without a loaded opener
  // (DEV-956), hidden, not hosting content, between documents, or the engine
  // has no extension views.
  ARX_EXTENSION_ACTION_RUN_UNAVAILABLE = 2,
  // No enabled MV3 extension with that ID and an action in the page's profile,
  // not one allowed and able to run in private windows for a private page
  // (DEV-956), or its action is hidden on this page.
  ARX_EXTENSION_ACTION_RUN_INVALID = 3,
  // Chromium wouldn't run it here: the page needs a reload for the extension's
  // site access, or the action opens a side panel, which Arx doesn't host.
  ARX_EXTENSION_ACTION_RUN_REFUSED = 4,
} ArxExtensionActionRunStatus;

// ABI48 (DEV-819) the kind of document a page shows.
typedef enum {
  // Unknown page, or nothing committed yet.
  ARX_PAGE_DOCUMENT_NONE = 0,
  // Any document that isn't a PDF.
  ARX_PAGE_DOCUMENT_WEB = 1,
  // The PDF viewer hosts the page's main document (application/pdf).
  ARX_PAGE_DOCUMENT_PDF = 2,
} ArxPageDocumentType;

// ABI61 (DEV-1101) the colors a page declares for the browser around it, as
// SkColor (0xAARRGGBB). A has_ flag is false when the page declares none.
typedef struct {
  uint32_t theme_color;
  uint32_t background_color;
  bool has_theme_color;
  bool has_background_color;
} ArxPageColors;

// ABI46 credential migration (DEV-650, DEV-830). One ordinary profile at a
// time; private and unknown profiles reply UNAVAILABLE. Records are borrowed
// for the call only: native copies what it needs before returning, so the
// caller can clear its buffers right after. No reply carries a password or
// cookie value, and native never logs one.
typedef struct ArxImportedPassword {
  const char *url;           // origin_url as the source saved it, http(s)
  const char *signon_realm;  // must be url's own realm, as Chromium derives it
  const char *username;
  const char *password;
} ArxImportedPassword;

typedef struct ArxImportedCookie {
  const char *domain;              // host_key; a leading dot marks a domain cookie
  const char *name;
  const char *value;
  const char *path;
  const char *top_frame_site_key;  // "" when unpartitioned
  int64_t creation_utc;            // microseconds since 1601-01-01 UTC, as Chromium stores them
  int64_t expires_utc;
  int64_t last_access_utc;
  bool secure;
  bool http_only;
  bool has_cross_site_ancestor;
  int32_t same_site;               // net::CookieSameSite, -1...2
  int32_t priority;                // net::CookiePriority, 0...2
  int32_t source_scheme;           // net::CookieSourceScheme, 0...2
  int32_t source_port;             // -1 when unknown
} ArxImportedCookie;

typedef enum {
  ARX_CREDENTIAL_IMPORT_OK = 0,
  ARX_CREDENTIAL_IMPORT_UNAVAILABLE = 1,
  ARX_CREDENTIAL_IMPORT_INVALID = 2,
  ARX_CREDENTIAL_IMPORT_BUSY = 3,
  ARX_CREDENTIAL_IMPORT_FAILED = 4,
  ARX_CREDENTIAL_IMPORT_CANCELLED = 5,
} ArxCredentialImportStatus;

// ABI58 (DEV-1016): a page's renderer end. The statuses are base::TerminationStatus.
enum {
  ARX_RENDERER_END_NORMAL = 0,
  ARX_RENDERER_END_ABNORMAL = 1,
  ARX_RENDERER_END_KILLED = 2,
  ARX_RENDERER_END_CRASHED = 3,
  ARX_RENDERER_END_LAUNCH_FAILED = 7,
  ARX_RENDERER_END_OUT_OF_MEMORY = 8,
};
typedef struct {
  uint32_t number;
  int32_t status;
  int32_t exit_code;
  bool ended_by_engine;
} ArxRendererEnd;

// ABI60 (DEV-1111) what page_link_hovered knows about the link.
typedef enum {
  // An http(s) link without a user name or password to another site than the
  // page's committed http(s) document (eTLD+1, private registries included): the
  // test ABI43's cross_site_link_requested asks with.
  ARX_HOVERED_LINK_CROSS_SITE = 1 << 0,
  // DEV-1118. The page's frames said where a plain click navigates (the link's
  // target, else its document's <base target>). Without it the two bits below
  // mean nothing: no frame answered in time, several did, or the target names
  // a browsing context that may not exist.
  ARX_HOVERED_LINK_TARGET_KNOWN = 1 << 1,
  // `_blank`: a new browsing context, not the page.
  ARX_HOVERED_LINK_NEW_CONTEXT = 1 << 2,
  // A frame inside the page, not its main frame: `_self` or `_parent` of a
  // nested frame. A cross-site click there is never offered (ABI43).
  ARX_HOVERED_LINK_IN_SUBFRAME = 1 << 3,
} ArxHoveredLinkFlag;

typedef struct {
  void *context;
  void (*ready)(void *context);
  void (*stopping)(void *context);
  void (*profile_ready)(void *context, uint64_t request, bool success);
  void (*close_decided)(void *context, uint64_t request, bool proceed);
  void (*page_changed)(void *context, uint64_t page, const char *url,
                       const char *title, bool loading, bool can_go_back,
                       bool can_go_forward, int error_code);
  void (*download_changed)(void *context, const char *profile_key,
                           const ArxDownloadSnapshot *snapshot);
  void (*downloads_initialized)(void *context, const char *profile_key);
  void (*capture_completed)(void *context, uint64_t request, uint64_t page,
                            ArxCaptureStatus status, const ArxCaptureSnapshot *snapshot);
  void (*media_changed)(void *context, uint64_t page, const ArxMediaSnapshot *snapshot);
  void (*media_completed)(void *context, uint64_t request, uint64_t page, ArxMediaStatus status);
  void (*media_activated)(void *context, uint64_t page, uint64_t generation);
  // UTF-8 JSON and profile_key are borrowed only during this callback. Snapshot
  // payload is at most 1 MiB; revision is an opaque runtime/profile-bound token.
  void (*extensions_completed)(void *context, uint64_t request, const char *profile_key,
                               ArxExtensionStatus status, uint64_t revision,
                               const uint8_t *json, size_t json_size);
  void (*authorized_close_decided)(void *context, uint64_t request, uint64_t page,
                                    ArxCloseStatus status, uint64_t token);
  // Changed is a document-validated invalidation after Chromium's profile DB update.
  // ABI51 (DEV-940): icon_url is the favicon the page now shows, whose bitmap
  // every page mapped to it shares; empty when unknown.
  void (*site_icon_changed)(void *context, uint64_t page, const char *page_url,
                            const char *icon_url);
  // ABI51 (DEV-940): icon_url is the favicon the answer's bitmap belongs to,
  // empty when unknown or without an icon.
  void (*site_icon_completed)(void *context, uint64_t request, ArxSiteIconStatus status,
                              const uint8_t *png, size_t size, uint32_t width, uint32_t height,
                              const char *icon_url);
  // Bounded UTF-8 JSON is borrowed during this callback; validation has no payload.
  void (*inspection_completed)(void *context, uint64_t request, uint64_t page,
                               ArxInspectionStatus status, const uint8_t *json, size_t size);
  void (*reference_click_completed)(void *context, uint64_t request, uint64_t page,
                                    ArxClickDisposition disposition, ArxClickStatus status);
  void (*form_action_completed)(void *context, uint64_t request, uint64_t page,
                                ArxFormDisposition disposition, ArxFormStatus status);
  void (*reference_scroll_completed)(void *context, uint64_t request, uint64_t page,
                                     ArxScrollDisposition disposition, ArxScrollStatus status);
  // Return false when no app consumer accepts the context, preserving fallback.
  bool (*link_context_requested)(void *context, uint64_t page, const ArxLinkContext *menu);
  void (*profile_retirement_completed)(void *context, uint64_t request,
      ArxProfileRetirementStatus status, const ArxProfileRetirementSnapshot *snapshot);
  void (*document_capture_completed)(void *context, uint64_t request, uint64_t page,
                                     ArxCaptureStatus status, const ArxDocumentCaptureSnapshot *snapshot);
  void (*document_capture_fixture_completed)(void *context, uint64_t request, bool success);
  void (*gesture_fixture_completed)(void *context, uint64_t request, bool success);
  // Staged after ABI16. Called only for an original native Escape whose renderer
  // ACK declined it and whose document/focused source remain current. Return
  // false without an accepting host. Consumers must defer any page destruction.
  bool (*unhandled_escape)(void *context, uint64_t page, uint64_t document_generation);
  // Return false without publishing model/session ownership. The native registry
  // destroys only this offered child on refusal. Never recreate its URL.
  bool (*new_contents_requested)(void *context, uint64_t source_page,
                                 uint64_t source_generation, uint64_t child_page,
                                 const char* target_url, size_t target_url_size, ArxNewContentsDisposition disposition);

  // Verified CRX candidate only. JSON and key are borrowed during the callback,
  // at most 1 MiB. No installation or permission grant precedes explicit consent.
  // ABI45 (DEV-776): an update's JSON also carries "permissionIncrease", true
  // when the candidate's required permissions warn about more than the
  // installed extension was granted (Chromium's IsPrivilegeIncrease).
  void (*extension_install_prompt)(void *context, uint64_t request,
                                   const char *profile_key, uint64_t token,
                                   const uint8_t *json, size_t json_size);

  // Manifest-derived ordinary extension view. The exact pending request must
  // accept it synchronously; false destroys only this unadopted native page.
  bool (*extension_view_created)(void *context, uint64_t request,
      const char* profile_key, const char* extension_id, uint64_t child_page,
      const char* target_url, size_t target_url_size, ArxExtensionViewKind kind);
  // ABI18 draft: actual chrome.runtime.openOptionsPage, with native extension
  // caller authority. This is separate from an inventory/user request offer.
  bool (*extension_options_requested)(void *context, const char* profile_key,
      const char* extension_id, uint64_t child_page, const char* target_url, size_t target_url_size);
  // ABI18 draft: revoke only a failed initial runtime-options offer, before
  // Chrome replies. Exact child+generation/profile/extension proof is required.
  void (*extension_options_revoked)(void *context, const char* profile_key,
      const char* extension_id, uint64_t child_page, uint64_t document_generation);
  // ABI24 Force Click on a link. Called once per press, at the trackpad's
  // force stage, with the http(s) link under the pointer. Return true to take
  // it: native then skips Look Up and the press never becomes a click. False
  // keeps Chromium's behavior. The URL is borrowed during the callback.
  bool (*link_force_clicked)(void *context, uint64_t page, uint64_t document_generation,
                             const char *url, size_t url_size);
  // ABI26. Once per request_pdf. Bytes and document ID are borrowed during the callback.
  void (*pdf_completed)(void *context, uint64_t request, uint64_t page, ArxPdfStatus status,
                        const char *document_id, const uint8_t *bytes, size_t size);
  // ABI33. Once per accepted start_download, after the item's first
  // download_changed. guid is borrowed during the callback and NULL unless STARTED.
  void (*download_started)(void *context, uint64_t request, ArxDownloadStartStatus status,
                           const char *guid, int interrupt_reason);
  // ABI34. Once per evaluate_script or read_developer_log. json is borrowed
  // during the callback; see evaluate_script and read_developer_log for its shape.
  void (*developer_completed)(void *context, uint64_t request, uint64_t page,
                              ArxDeveloperStatus status, const uint8_t *json, size_t size);
  // ABI35. A page's submitted sign-in form can be saved (or, with update, a
  // saved password changed). origin and username are borrowed during the
  // callback. Answer once with answer_password_save; a newer offer for the
  // page replaces this one.
  void (*password_save_offered)(void *context, uint64_t page, uint64_t token,
                                const char *origin, const char *username, bool update);
  // ABI35. Once per sign_in_credentials or sign_in_attempt; json is borrowed
  // during the callback.
  void (*sign_in_completed)(void *context, uint64_t request, uint64_t page,
                            ArxSignInStatus status, const uint8_t *json, size_t size);
  // ABI36. Once per saved-password request; json is borrowed during the callback.
  void (*saved_passwords_completed)(void *context, uint64_t request,
                                    ArxSavedPasswordsStatus status, const uint8_t *json,
                                    size_t size);
  // ABI37. Once per focused_link. url is the focused http(s) link, borrowed
  // during the callback, or NULL when there is none Arx can open.
  // document_generation is the page's when asked.
  void (*focused_link_completed)(void *context, uint64_t request, uint64_t page,
                                 uint64_t document_generation, const char *url, size_t url_size);
  // ABI38. Once per list_site_settings, set_site_permission or set_site_zoom.
  // OK carries the profile's listing (see list_site_settings); INVALID and
  // MANAGED carry {"reason"}. json is borrowed during the callback.
  void (*site_settings_completed)(void *context, uint64_t request, ArxSiteSettingsStatus status,
                                  const uint8_t *json, size_t size);
  // ABI38. A watched profile's site permissions or zoom changed, from Settings,
  // a page's permission prompt or anywhere else. Coalesced and posted; read the
  // listing again. A profile is watched once it has been listed.
  void (*site_settings_changed)(void *context, const char *profile_key);
  // ABI39. Once per count_browsing_data, clear_browsing_data,
  // download_settings or set_download_settings, and (ABI40) site_data_scope or
  // clear_site_data. INVALID and MANAGED carry
  // {"reason"}. json is borrowed during the callback.
  void (*profile_data_completed)(void *context, uint64_t request, ArxProfileDataStatus status,
                                 const uint8_t *json, size_t size);
  // ABI42. A page's DevTools opened, closed, docked, undocked or moved its
  // divider: read devtools_layout and place the view again (DEV-733).
  void (*devtools_layout_changed)(void *context, uint64_t page);
  // ABI43 (DEV-727). A plain click on a link to another site in an ordinary
  // page: a renderer-initiated, user-gesture GET in the primary main frame with
  // a link transition, to an http(s) URL whose site (eTLD+1) differs from the
  // committed page's. Redirects, form posts, scripted navigations without a
  // gesture, reloads, history, same-document and private pages never ask.
  // Native defers the navigation and asks once, after a posted task, never
  // inside Chromium's throttle call. True takes the link: native cancels the
  // navigation and the page stays where it was. False lets it go on. The URL
  // is borrowed during the callback.
  bool (*cross_site_link_requested)(void *context, uint64_t page, uint64_t document_generation,
                                    const char *url, size_t url_size);
  // ABI44 (DEV-765). The Chrome Web Store page in an ordinary page asked to
  // install extension_id (Add to Chrome). Posted, never inside Chromium's call.
  // True takes the request: call install_webstore_extension with the token to
  // download, verify and review the package (extension_install_prompt, then
  // extensions_completed), or decline_webstore_install. False, or neither within
  // two minutes, answers the store that the user cancelled. The token is bound
  // to this profile and ID. Strings are borrowed during the callback.
  bool (*webstore_install_requested)(void *context, uint64_t page, const char *profile_key,
                                     const char *extension_id, uint64_t token);
  // ABI45 (DEV-795). The person chose an item in the page menu. Called after
  // AppKit's menu loop has ended, with the page's document generation then;
  // the app carries the item out as its own command for that page.
  void (*page_menu_chosen)(void *context, uint64_t page, uint64_t document_generation,
                           ArxPageMenuItem item);
  // ABI45 (DEV-795). Asked when the page menu is about to open: a mask with bit
  // (1u << item) set for each ArxPageMenuItem the page's host can carry out now
  // (Save As and Print aren't offered in private windows, View Source only in
  // a main window...). Native enables an item only when both it and the host
  // allow it; zero, or no callback, leaves the page items out of the menu.
  uint32_t (*page_menu_items)(void *context, uint64_t page);
  // ABI46 (DEV-830). Replies once, posted, to each credential import call.
  // UTF-8 JSON is borrowed during the callback. Failures carry {"reason"}.
  void (*credential_import_completed)(void *context, uint64_t request,
                                      ArxCredentialImportStatus status, const uint8_t *json,
                                      size_t size);
  // ---- ABI48 (DEV-814) context menus: begin ----
  // The person chose an app item in a context menu. Called after AppKit's menu
  // loop has ended, with the page's document generation then; the app carries
  // it out for that page. The choice is borrowed during the callback.
  void (*context_menu_chosen)(void *context, uint64_t page, uint64_t document_generation,
                              const ArxContextMenuChoice *choice);
  // Asked when a context menu is about to open: a mask with bit
  // (1ull << item) set for each app ArxContextMenuItem the page's host can
  // carry out now (no downloads in private windows...). Zero, or no callback,
  // leaves the app items out; native items don't ask.
  uint64_t (*context_menu_items)(void *context, uint64_t page);
  // ---- ABI48 (DEV-814) context menus: end ----
  // ABI49 (DEV-855). The page called window.close() and Blink allowed it (a
  // window a script opened, with one history entry), for the document of
  // document_generation. Posted, never inside Chromium's call. Blink has already
  // run the page's before-unload. Nothing is closed natively: the app closes the
  // page's host without asking the page again, or ignores it. NULL ignores every
  // request.
  void (*page_close_requested)(void *context, uint64_t page, uint64_t document_generation);
  // ABI50 (DEV-857). A page asked to open a link for another app (a custom
  // scheme such as claude://, after Chrome's own scheme and anti-flood policy
  // let it through), before Chrome looks up the app, shows its "Open app?"
  // dialog, applies a remembered "Always allow" or launches anything. Posted,
  // never inside Chromium's call, and only while the same document is current.
  // profile_key is the page's ordinary profile, NULL in a private one.
  // source_origin is the requesting origin, empty when unknown or opaque (a
  // sandboxed frame's); never the full page URL. flags are ArxExternalLinkFlag bits.
  // True takes the link: Chrome shows nothing and launches nothing, and the
  // app asks and opens it itself. False hands it back to Chrome's path,
  // unchanged. Strings are borrowed during the callback. NULL keeps Chrome's
  // path for every link.
  // token names this offer for external_link_is_current: the page keeps
  // Chrome's exact source guard for the link it took last.
  bool (*external_link_requested)(void *context, uint64_t page, uint64_t document_generation,
                                  uint64_t token,
                                  const char *profile_key, const char *url, size_t url_size,
                                  const char *source_origin, size_t source_origin_size,
                                  uint32_t flags);
  // ABI51 (DEV-940). An ordinary page committed a cross-document main-frame
  // navigation that redirected: page_urls is its redirect chain, oldest first,
  // ending with the committed URL (http(s) only, each at most 8192 bytes, at most
  // the last 8). Chromium's favicon database maps the page's icon to these
  // addresses too, though a page snapshot may never have shown the middle ones.
  // Same-document commits (pushState, replaceState) before the page's icon is
  // known send their one address, since Chromium maps the icon to them too.
  // truncated is true when the chain had addresses not sent (older than the last
  // eight, or longer than 8192 bytes).
  // Posted; strings are borrowed during the callback. Private pages send none.
  void (*site_icon_redirects)(void *context, uint64_t page, const char *const *page_urls,
                              size_t count, bool truncated);

  // ABI52 (DEV-875, DEV-893). An ordinary page's autofill suggestions for its
  // focused field changed. Posted, never inside Chromium's call. json is
  // borrowed during the callback:
  //   {"state": "shown", "product": "password"|"address"|"card"|"other",
  //    "x", "y", "width", "height": the field in the page view's points from
  //    its top left, "rtl", "selected": the item index arrows chose or -1,
  //    "items": [{"index", "kind", "title", "subtitle"?}]}
  // kind is password, address, card, text, undo, managePasswords,
  // manageAddresses or manageCards. Titles and subtitles name accounts,
  // addresses and masked cards; never a password, card number or code.
  //   {"state": "hidden", "open": "passwords"|"addresses"|"cards"?}
  // open asks the app to show that Settings list (a Manage item was chosen).
  // A newer session for the page replaces an older one without a hidden; a
  // changed list (the user typed on) comes as a new session too, so an answer
  // to a list the app no longer shows is refused. The arrow keys' selection
  // keeps the session.
  // Arrow keys, Return and Escape in the field drive the shown session
  // natively. Private pages never have suggestions.
  void (*autofill_suggestions_changed)(void *context, uint64_t page, uint64_t session,
                                       const uint8_t *json, size_t size);
  // ABI52 (DEV-893). Once per autofill data request, posted. OK carries the
  // profile's listing after the request's change landed:
  //   {"addresses": [{"id", "name", "organization", "street", "city", "state",
  //                   "zip", "country", "phone", "email"}],
  //    "cards": [{"id", "name", "network", "lastFour", "month", "year", "nickname"}]}
  // json is borrowed during the callback.
  void (*autofill_data_completed)(void *context, uint64_t request, ArxAutofillDataStatus status,
                                  const uint8_t *json, size_t size);

  // ABI54 (DEV-949). A page entered or left HTML full screen
  // (element.requestFullscreen(), document.exitFullscreen(), Escape, another
  // document, a crash or exit_page_fullscreen). Posted and coalesced: it carries
  // the state when delivered, once per change. document_generation is the
  // page's then; same-document navigations keep full screen, so don't drop a
  // report whose generation moved on. Entering, the app shows only this page,
  // filling the screen, until it hears false. A NULL callback refuses every
  // request, so the page's promise rejects instead of waiting.
  void (*page_fullscreen_changed)(void *context, uint64_t page, uint64_t document_generation,
                                  bool fullscreen);
  // ---- ABI55 (DEV-885) web notifications: begin ----
  // While a click on a notification from the page's ordinary profile and
  // origin runs, the page asked to come forward: window.focus() from the
  // notification's onclick, a service worker's client.focus(), or the page
  // openWindow() just opened. Posted, never inside Chromium's call. The app
  // shows the page's tab and brings Arx forward. Generic window.focus() never
  // asks. NULL ignores every request.
  void (*page_activation_requested)(void *context, uint64_t page, uint64_t document_generation);
  // A service worker called clients.openWindow(url) while a click on one of
  // its notifications ran. Native made child_page in the profile (profile_key
  // as for create_page) and started loading url; return true to adopt it as
  // a new foreground tab, which the worker then gets as its WindowClient.
  // False destroys only the child, and openWindow() gets null. Synchronous;
  // strings are borrowed during the callback. NULL refuses every window.
  bool (*notification_window_requested)(void *context, const char *profile_key,
                                        uint64_t child_page, const char *url, size_t url_size);
  // A click on a site's notification finished, half a second after the page
  // or service worker's handler settled. origin is the notification's origin
  // (scheme://host[:port]); flags are ArxNotificationClickFlag bits. Without
  // ARX_NOTIFICATION_HANDLED the app shows the site's tab in that profile, or
  // opens the origin when it has none. Posted; strings are borrowed during the
  // callback. Private profiles never report: Chromium denies them the
  // notification permission, as Chrome does in Incognito.
  void (*notification_clicked)(void *context, const char *profile_key, const char *origin,
                               size_t origin_size, uint32_t flags);
  // ---- ABI55 (DEV-885) web notifications: end ----

  // ABI56 (DEV-963). Posted while set_page_prompts_hosted is on: the page's site
  // permission prompt for the app to draw became current (token), or went away
  // (token 0: answered, the tab switched, the page navigated or closed). Read
  // it with copy_page_permission_prompt.
  void (*page_permission_prompt_changed)(void *context, uint64_t page, uint64_t token);

  // ABI60 (DEV-1111, DEV-1118), staged. The link under the pointer in the page,
  // in any of its frames, as Chrome's status bubble shows it (WebContentsDelegate's
  // UpdateTargetURL), or url_size 0 once the pointer leaves it and when a new
  // document commits. A link is reported once its frames say where it navigates,
  // or after 250 ms without that. Posted, never inside Chromium's call, and
  // coalesced: once per change, with the link hovered when delivered. The user name and password
  // are removed; a link longer than 8192 bytes reports as none. Private pages
  // report too. Only while set_link_hover_reports is on. flags are
  // ArxHoveredLinkFlag bits. url is borrowed during the
  // callback. NULL reports nothing.
  void (*page_link_hovered)(void *context, uint64_t page, uint64_t document_generation,
                            const char *url, size_t url_size, uint32_t flags);

  // ABI62 (DEV-1264, DEV-1073). A ⌘ key down a focused page received, and
  // whether the page used it (its handler called preventDefault). key_code and
  // modifier_flags are the NSEvent's keyCode and device-independent
  // modifierFlags, event_timestamp its timestamp, so the app can match the key
  // it let through. consumed is posted after the renderer's ACK, and its return
  // is ignored. A key the page left is reported synchronously from
  // HandleKeyboardEvent (consumed false): return true when the app ran its own
  // command for it. A key down Chromium drops when unhandled, a repeat the page
  // only sees, or a hidden page reports nothing. NULL follows no keys.
  bool (*page_command_key)(void *context, uint64_t page, uint64_t document_generation,
                           uint16_t key_code, uint64_t modifier_flags, double event_timestamp,
                           bool consumed);
} ArxEngineCallbacks;

typedef struct {
  // Blocks until Chromium exits. The runtime can run only once per process.
  int (*run)(const char *executable, const char *profile_path,
             const ArxEngineCallbacks *callbacks);
  void (*request_quit)(void);
  uint64_t (*create_page)(const char *url, const char *profile_key);
  void (*destroy_page)(uint64_t page);
  // Borrowed NSView*. Valid until destroy_page or the stopping callback returns.
  void *(*page_view)(uint64_t page);
  bool (*navigate)(uint64_t page, const char *url);
  void (*go_back)(uint64_t page);
  void (*go_forward)(uint64_t page);
  void (*reload)(uint64_t page);
  void (*stop)(uint64_t page);
  void (*prepare_profile)(const char *key, uint64_t request);
  void (*request_close)(uint64_t page, uint64_t request);
  int (*history_count)(uint64_t page);
  int (*history_entry)(uint64_t page, int index, const char **url, const char **title, bool *current);
  void (*go_to_entry)(uint64_t page, int entry_id);
  bool (*prepare_private_profile)(const char *key);
  void (*release_private_profile)(const char *key);
  void (*clear_cache_and_reload)(uint64_t page);
  bool (*observe_downloads)(const char *profile_key);
  bool (*cancel_download)(const char *profile_key, const char *guid);
  uint64_t (*active_download_count)(void);
  void (*cancel_all_downloads)(void);
  void (*capture_viewport)(uint64_t page, uint64_t request, ArxCaptureLimits limits);
  void (*cancel_capture)(uint64_t request);
  int (*run_with_options)(const char *executable, const char *profile_path,
                          const ArxEngineCallbacks *callbacks,
                          const ArxEngineRunOptions *options);
  bool (*observe_media)(uint64_t page);
  void (*perform_media)(uint64_t page, uint64_t request, uint64_t generation,
                        uint64_t revision, ArxMediaAction action);
  void (*cancel_media)(uint64_t request);
  // Read-only fixture evidence: -1 no private session, 0 metadata exposed, 1 hide_metadata.
  // Never returns private titles, origins, artwork, or player identities.
  int (*private_media_metadata_status)(uint64_t page);
  void (*inspect_extensions)(const char *profile_key, uint64_t request);
  void (*manage_extension)(const char *profile_key, uint64_t request,
                           uint64_t revision, const char *extension_id,
                           ArxExtensionAction action);
  void (*cancel_extension_request)(uint64_t request);
  void (*load_extension_fixture)(const char *profile_key, uint64_t request);
  // ABI8: synchronous UI-thread read of the live ordinary observer, not queued snapshots.
  // False for unavailable/closed/private pages or invalidated generations; no side effects.
  bool (*media_source_is_current)(uint64_t page, uint64_t generation);
  // Zero means unavailable. Cache with page_changed, not at close execution.
  uint64_t (*page_close_generation)(uint64_t page);
  void (*request_authorized_close)(uint64_t page, uint64_t request, uint64_t generation);
  // Success atomically consumes approval AND destroys the page. Never call destroy_page again.
  ArxCloseStatus (*consume_authorized_close)(uint64_t page, uint64_t request, uint64_t token);
  // Revokes authority; the physical before-unload slot remains until its tagged completion/reset.
  void (*cancel_authorized_close)(uint64_t page, uint64_t request);
  // DB-only exact page-URL query. No host fallback or network request.
  void (*lookup_site_icon)(const char *profile_key, const char *page_url, uint64_t request);
  void (*cancel_site_icon)(uint64_t request);
  void (*inspect_page)(uint64_t page, uint64_t request, const char *scope, ArxInspectionLimits limits);
  void (*validate_inspection_reference)(uint64_t page, uint64_t request, const char *scope,
                                        const char *snapshot, const char *reference);
  void (*cancel_inspection)(uint64_t request);
  void (*revoke_inspection_scope)(const char *scope);
  // Native document/page/scope liveness only. DOM validity requires renderer validation.
  bool (*inspection_document_is_current)(uint64_t page, const char *scope, const char *snapshot);
  // UI thread; strings are bounded tokens and request IDs are never reused.
  // Repeated operation never dispatches, even after reference/scope disposal.
  void (*click_inspection_reference)(uint64_t page, uint64_t request, const char *scope,
                                     const char *snapshot, const char *reference,
                                     const char *operation, uint32_t timeout_ms);
  void (*cancel_reference_click)(uint64_t request);
  void (*perform_inspection_form_action)(uint64_t page, uint64_t request, const char *scope,
                                        const char *snapshot, const char *reference,
                                        const char *operation, ArxFormActionKind kind,
                                        const uint8_t *bytes, size_t length, uint32_t timeout_ms);
  void (*cancel_reference_form_action)(uint64_t request);
  void (*scroll_inspection_reference)(uint64_t page, uint64_t request, const char *scope,
                                      const char *snapshot, const char *reference,
                                      const char *operation, ArxScrollAxis axis,
                                      double delta_css_pixels, uint32_t timeout_ms);
  // cancel_reference_click also cancels scroll requests in the shared queue.
  // Main-thread, synchronous token checks. Dismissal never clears another token.
  bool (*link_context_is_current)(uint64_t page, uint64_t token);
  void (*dismiss_link_context)(uint64_t page, uint64_t token);
  // Explicit opt-in only. Installation UUID must be persisted for this exact
  // app-owned root; legacy UUID is its permanent Default owner. Existing Run
  // variants remain unchanged. Rejects disposable extension-fixture mode.
  int (*run_with_profile_retirement)(const char *executable, const char *profile_path,
      const ArxEngineCallbacks *callbacks, const ArxEngineRunOptions *options,
      const char *installation_id, const char *legacy_profile_id);
  // Availability means durable retirement can be queued, never immediate erase.
  bool (*profile_retirement_available)(void);
  void (*inspect_profile_retirement)(uint64_t request);
  // Storage mapping is checked against the configured permanent legacy owner.
  // Caller obtains exact explicit erase consent and closes every profile user;
  // native rejects pages, private/shared ownership, preparation and downloads.
  void (*queue_profile_retirement)(const char *profile_key, bool legacy_storage,
      const char *request_id, uint64_t expected_revision, uint64_t request);
  // Availability remains false until full-document native acceptance completes.
  bool (*document_capture_available)(void);
  void (*capture_document)(uint64_t page, uint64_t request, ArxCaptureLimits limits);
  void (*cancel_document_capture)(uint64_t request);
  void (*run_document_capture_fixture)(uint64_t page, uint64_t request, const char *loopback_origin);
  // Owned fresh mock-Keychain fixture only; no ordinary app input-injection API.
  void (*run_gesture_fixture)(uint64_t page, uint64_t request, const char *loopback_origin);
  // Staged subsequent-batch capability; no keyboard activation or implicit focus.
  bool (*reference_keypress_available)(void);
  // Default off. Configure before navigation; children inherit their source's
  // normal browser host policy. Root coordinates release ABI after native proof.
  bool (*configure_content_hosting)(uint64_t page, bool enabled);

  // Explicit local CRX3 intake; native copies at most 32 MiB before returning.
  // expected_extension_id is empty for a new install and exact for an update.
  // Completion uses extensions_completed; cancellation uses cancel_extension_request.
  bool (*extension_install_available)(void);
  void (*install_extension_crx)(const char *profile_key, uint64_t request,
                                uint64_t inventory_revision,
                                const char *expected_extension_id,
                                const char *source_basename,
                                const uint8_t *crx, size_t crx_size);
  // Main-thread, one-use grant for this verified candidate/profile/inventory.
  bool (*resolve_extension_install)(const char *profile_key, uint64_t request,
                                    uint64_t token, bool accept);
  // Explicit developer fixture only: fresh signed packages with variants
  // 0=v1, 1=permission-increasing v2, 2=wrong signing key, 3=corrupt signature.
  void (*install_extension_fixture)(const char *profile_key, uint64_t request,
                                    uint64_t revision, const char *expected_id,
                                    uint32_t variant);

  bool (*extension_views_available)(void);
  void (*open_extension_view)(const char* profile_key, uint64_t request,
      uint64_t revision, const char* extension_id, ArxExtensionViewKind kind,
      uint64_t source_page, uint64_t source_generation);

  // ABI19 developer tools. Main thread. Titles are borrowed UTF-8 for this call;
  // empty keeps the previous value. inspect_context offers Inspect Element on
  // non-link context menus; link menus use inspect_link_context.
  bool (*devtools_available)(void);
  void (*configure_devtools)(const char *window_title, const char *inspect_title,
                             bool inspect_context);
  ArxDevToolsStatus (*open_devtools)(uint64_t page);
  // Inspects the exact element under a current link context token.
  ArxDevToolsStatus (*inspect_link_context)(uint64_t page, uint64_t token);
  bool (*close_devtools)(uint64_t page);
  bool (*devtools_is_open)(uint64_t page);
  // Reload the page bypassing its cache without clearing the profile cache.
  void (*reload_bypassing_cache)(uint64_t page);
  // The page's inspector exists and its bundled frontend finished loading.
  bool (*devtools_frontend_loaded)(uint64_t page);
  // ABI19 unattended runs. Call before run. Page JavaScript alert/confirm/prompt
  // is suppressed (Chromium supplies the default reply) and before-unload stays
  // on the page, so no app-modal dialog can block a run without a user.
  // Occluded hosts stay visible to Chromium and renderers are not backgrounded.
  void (*set_unattended)(bool unattended);
  // Main thread. Dialogs suppressed since run started; never their text.
  uint64_t (*unattended_dialog_count)(void);

  // ABI20 developer unpacked extensions. Main thread. directory is a borrowed
  // absolute UTF-8 path, at most 4096 bytes, read through Chromium's
  // UnpackedInstaller with its management-policy and requirement checks.
  // inventory_revision must be the profile's current inventory revision.
  // Success enables Chromium developer mode for this ordinary profile only.
  // Completion uses extensions_completed; cancellation uses
  // cancel_extension_request and never rolls back an already-committed load.
  bool (*unpacked_extensions_available)(void);
  void (*load_unpacked_extension)(const char *profile_key, uint64_t request,
                                  uint64_t inventory_revision, const char *directory);

  // ABI21 unattended HTTP authentication. Main thread. In an unattended run a
  // subframe or subresource challenge is cancelled instead of building a login
  // prompt nobody could answer; no credentials are sent. Returns how many were
  // cancelled for the page's current primary document (a new document resets
  // it); page_changed follows each cancellation. Always 0 in interactive runs,
  // whose prompts are unchanged. ABI22: a primary main-frame challenge is
  // cancelled the same way; the server's 401/407 body commits and counts once.
  uint64_t (*page_authentication_cancellations)(uint64_t page);

  // ABI22 extension windows. Main thread. Replaces every page's placement in
  // Arx windows at once; unlisted pages are in no window. Each distinct window
  // number gets a stable extension window ID for that window's lifetime.
  // chrome.tabs/chrome.windows then report windowId, index, active and
  // highlighted, match currentWindow/lastFocusedWindow/windowId/index, and
  // list the windows with windows.get/getCurrent/getLastFocused/getAll. An
  // extension sees only windows holding its own ordinary profile's pages;
  // private pages are never listed. A call from a page, or from an extension
  // popup opened for a page, has that page's window as its current window.
  void (*set_extension_tab_placements)(const ArxExtensionTabPlacement *placements,
                                       size_t count);
  // ABI22 unattended sign-in prompts. Main thread. In an unattended run a modal
  // WebAuthn request is cancelled before any dialog is built (the page sees
  // NotAllowedError) and a FedCM request that would need a dialog fails.
  // Returns ArxUserActionRequest bits for the page's current primary document
  // (a new document clears them); page_changed follows each. Always 0 in
  // interactive runs.
  uint32_t (*page_user_action_requests)(uint64_t page);
  // ABI22 unattended shutdown. Main thread, before run. Chromium's shutdown
  // watchdog waits deadline_seconds (> 0) instead of its default before
  // force-exiting a hung shutdown, and calls expired(context, exit_code) on
  // its own thread first. expired must not block or call back into the API.
  void (*set_unattended_shutdown)(uint32_t deadline_seconds,
                                  void (*expired)(void *context, int exit_code),
                                  void *context);
  // ABI23 find in page. Main thread. new_session starts a search for text;
  // otherwise this moves to the next or previous match of the current search.
  // Copies text. page_changed follows each result. Native highlights matches
  // in the page, and stop clears them and leaves the selection on the match.
  void (*page_find)(uint64_t page, const char *text, bool forward, bool new_session);
  void (*page_stop_find)(uint64_t page);
  // matches and active are -1 with no result for the current document.
  void (*page_find_status)(uint64_t page, int32_t *matches, int32_t *active);

  // ABI25 frame inspection. Main thread. frame is NULL or empty for the main
  // frame, or a child frame ID from a snapshot node's "frame" field: an active
  // ordinary HTTP(S) frame of the primary page outside fenced trees. Each frame
  // keeps its own snapshots and references; a newer read of a frame retires
  // only that frame's references, and page actions route to the snapshot's
  // own frame. Completion uses inspection_completed.
  void (*inspect_frame)(uint64_t page, uint64_t request, const char *scope,
                        const char *frame, ArxInspectionWindow window);

  // ABI26 offscreen capture. Main thread. A page that isn't on screen is kept
  // rendering while hidden (Chromium's hidden capturer count) and its viewport
  // is copied; nothing is shown, focused, selected or attached. A detached
  // page that never had a size is laid out at 1280x800 points first. A page
  // already on screen captures as capture_viewport. Completion uses
  // capture_completed.
  void (*capture_offscreen)(uint64_t page, uint64_t request, ArxCaptureLimits limits);
  // ABI26 PDF. Main thread, one physical job at a time. Export prints the
  // primary main frame of an ordinary HTTP(S) page (beforeprint and afterprint
  // fire in the page); source reads the bytes of a page showing a PDF, from the
  // cache when present, with the profile's cookies. Private pages are refused.
  void (*request_pdf)(uint64_t page, uint64_t request, ArxPdfKind kind, ArxPdfOptions options,
                      uint32_t maximum_bytes, uint32_t timeout_ms);
  void (*cancel_pdf)(uint64_t request);

  // ABI30 file choosers. Main thread. page_file_chooser reports the page's held
  // chooser. answer_file_chooser answers it once with absolute file paths the
  // app has checked and the user approved (at most 32; one unless multiple),
  // or cancels it with no paths. A held chooser is cancelled after 60 seconds,
  // on navigation and when the page closes.
  bool (*page_file_chooser)(uint64_t page, ArxFileChooserInfo *info);
  ArxFileChooserStatus (*answer_file_chooser)(uint64_t page, uint64_t token,
                                              const char *const *paths, size_t count);

  // ABI31 page dialogs. Main thread. page_dialog reports the page's JavaScript
  // dialog (it blocks the renderer, so it comes first) or else its permission
  // sheet; unattended runs suppress JavaScript dialogs as before. The user can
  // still answer either; whichever answer comes first wins and the other is
  // stale. answer_page_dialog accepts or dismisses it; prompt_text (NULL or
  // UTF-8, at most 4096 bytes) is only for an accepted prompt. A permission
  // accept allows this time when the permission supports it, otherwise allows;
  // a dismiss never blocks the permission.
  bool (*page_dialog)(uint64_t page, ArxPageDialog *dialog);
  ArxPageDialogStatus (*answer_page_dialog)(uint64_t page, uint64_t token, bool accept,
                                            const char *prompt_text);

  // ABI32 media position and page audio. Main thread, ordinary observed pages
  // only (observe_media first); private pages are refused. media_position reads
  // once and never streams. seek_media seeks the exact source through its media
  // session to an absolute, finite, non-negative time (clamped to a known
  // duration) and completes through media_completed once the position reaches
  // it, with perform_media's statuses; cancel_media cancels it.
  // set_page_audio_muted mutes or unmutes the page's audio. Chromium drops a
  // muted page's playing player from its media session (outside PiP), so its
  // source can disappear until it is unmuted.
  bool (*media_position)(uint64_t page, ArxMediaPosition *position);
  void (*seek_media)(uint64_t page, uint64_t request, uint64_t generation,
                     uint64_t revision, double seconds);
  bool (*set_page_audio_muted)(uint64_t page, bool muted);

  // ABI33 downloads a URL in an ordinary observed profile through its
  // DownloadManager, with no page or frame. Chromium's target, safe-browsing,
  // dangerous-file and insecure-download checks apply as to a link download
  // the user started; nothing bypasses a prompt or opens the file. url must be
  // http(s) without credentials. False refuses at once (stopped, private or
  // unknown profile, invalid URL); true replies through download_started.
  bool (*start_download)(uint64_t request, const char *profile_key, const char *url);

  // ABI34 developer tier. Main thread; ordinary HTTP(S) pages only, private
  // pages are refused. evaluate_script runs source (UTF-8, at most 65536
  // bytes) as the body of an async function in the main frame's developer
  // world of the current document and awaits it, at most timeout_ms (30000).
  // OK replies
  // {"type":"json","value":<JSON text>}, {"type":"undefined"} or
  // {"type":"unserializable","description"}; EXCEPTION and SYNTAX reply
  // {"name","message","line"?}. A value over maximum_bytes (262144) is LIMIT.
  // A navigation or a closed page is STALE. One script per page at a time.
  void (*evaluate_script)(uint64_t page, uint64_t request, const char *source,
                          uint32_t maximum_bytes, uint32_t timeout_ms);
  // Starts or stops keeping the page's console and network logs: at most 500
  // entries of each, newest kept. Stopping drops them. False refuses (private,
  // closed or not running).
  bool (*set_developer_log)(uint64_t page, bool enabled);
  // Replies {"capturing","entries":[...],"next","dropped"} with up to limit
  // (1-200) entries after the sequence number after. Network entries carry
  // no headers, cookies or bodies, and sensitive query values are redacted.
  void (*read_developer_log)(uint64_t page, uint64_t request, ArxDeveloperLogKind kind,
                             uint64_t after, uint32_t limit);
  // Replies CANCELLED to a pending request; a late renderer result is dropped.
  void (*cancel_developer)(uint64_t request);

  // ABI35 saved passwords. Main thread; ordinary HTTP(S) pages only.
  // answer_password_save answers the page's current offer: SAVE stores it in
  // the page's own profile, NEVER stops offering for the site (or keeps the
  // old password for an update), NOT_NOW drops it. False for a stale token.
  bool (*answer_password_save)(uint64_t page, uint64_t token, ArxPasswordSaveAnswer answer);
  // OK replies {"document","origin","credentials":[{"id","username","form"}]}:
  // the passwords saved for exactly the main frame's origin, at most 32, and
  // whether a sign-in form is on the page. document binds a later attempt to
  // this main-frame document.
  void (*sign_in_credentials)(uint64_t page, uint64_t request);
  // Fills credential through Chromium's actor_login into frame (NULL or empty
  // for the main frame, or a child frame ID from an inspection snapshot) of
  // the listed document, submits the form, then reads the page. Replies
  // SIGNED_IN, NEEDS_USER (reauthentication or a one-time code), FAILED, STALE
  // (the document or frame changed before submitting), TIMEOUT (5000-60000 ms)
  // or CANCELLED, with {"reason","filled","passwordVisible"}.
  void (*sign_in_attempt)(uint64_t page, uint64_t request, const char *document,
                          const char *frame, uint32_t credential, uint32_t timeout_ms);
  void (*cancel_sign_in)(uint64_t request);

  // ABI36 saved passwords in Settings. Main thread; profile_key names an
  // ordinary profile prepared with prepare_profile. Every call replies once
  // through saved_passwords_completed. A listing replies OK with
  // {"listing","passwords":[{"id","site","origin","username"}],"blocked":[{"id","site","origin"}]}
  // (at most 10000 of each). Mutations name a credential by its ID in the
  // listing token they were shown; a newer listing makes older tokens STALE.
  // A finished mutation replies OK with a fresh listing.
  void (*list_saved_passwords)(uint64_t request, const char *profile_key);
  // Adds (credential 0, with url) or edits (username and, unless
  // password_field is NULL, the password) a saved password. password_field is
  // a borrowed NSTextField*; native reads its value once and clears it.
  // EXISTS: the site already has that username. INVALID: bad URL or empty password.
  void (*save_saved_password)(uint64_t request, const char *profile_key, const char *listing,
                              uint32_t credential, const char *url, const char *username,
                              void *password_field);
  // Removes a saved password or a "never saved" site from the listing.
  void (*remove_saved_password)(uint64_t request, const char *profile_key,
                                const char *listing, uint32_t credential);
  // Asks the device owner with LocalAuthentication (reason is shown), then
  // COPY puts the password on the general pasteboard as concealed, cleared
  // after 60 seconds unless it changed, or SHOW writes it into field (a
  // borrowed NSTextField*). DENIED: authentication failed or was cancelled.
  // Replies OK with {}.
  void (*reveal_saved_password)(uint64_t request, const char *profile_key, const char *listing,
                                uint32_t credential, ArxPasswordReveal mode, const char *reason,
                                void *field);
  // Imports a Chrome or Apple Passwords CSV export at path into the profile
  // through Chromium's PasswordImporter. Existing site and username pairs are
  // kept and reported. OK replies {"imported","conflicts":[{"site","username"}],
  // "skipped":[{"site","username","reason"}],"conflictCount","skippedCount"} (at
  // most 200 rows each); FAILED and INVALID reply {"reason"}: io, format,
  // tooLarge, tooMany or unknown.
  void (*import_saved_passwords)(uint64_t request, const char *profile_key, const char *path);
  // Replies CANCELLED to a pending request. A store write already started may finish.
  void (*cancel_saved_passwords)(uint64_t request);

  // ABI37 focused link (DEV-713). Main thread. Reads document.activeElement in
  // the page's focused frame (any origin, open shadow roots included), then its
  // closest a[href] or area[href], in a Chrome-internal isolated world; nothing
  // is clicked or focused. Only an ordinary page whose main frame is http(s),
  // in a visible window, answers with a link: http(s), no credentials, at most
  // 8192 bytes. A text field or other control, a private page, a navigation or
  // no answer within two seconds replies without a URL.
  void (*focused_link)(uint64_t page, uint64_t request);

  // ABI38 site permissions and zoom (DEV-716). Main thread; profile_key names
  // an ordinary profile prepared with prepare_profile. Every call replies once
  // through site_settings_completed, never synchronously. A listing replies OK
  // with {"permissions":{"defaults":{"camera":"ask",...},"managedDefaults":[...],
  // "sites":[{"origin","permission","setting","managed"}]},
  // "zoom":{"default":1.0,"sites":[{"host","factor"}]},"truncated":false}.
  // Permissions are camera, microphone, location, notifications, popups and
  // clipboard; settings allow, block or ask. Sites hold at most 5000 rows each.
  void (*list_site_settings)(uint64_t request, const char *profile_key);
  // Sets one permission for an http(s) origin, or the profile's default when
  // origin is NULL or empty. DEFAULT on an origin removes its exception (an
  // origin may also be a listed pattern such as "https://[*.]example.com");
  // DEFAULT has no meaning for the profile default. INVALID: a bad origin or a
  // setting that permission doesn't take (pop-ups take no ask). OK replies a
  // fresh listing.
  void (*set_site_permission)(uint64_t request, const char *profile_key, const char *origin,
                              ArxSitePermission permission, ArxSitePermissionSetting setting);
  // Sets a host's page zoom factor (0.25-5.0), or the profile's default zoom
  // when host is NULL or empty. Factor 0 removes the host's zoom, so the
  // default applies; a factor equal to the default also removes it. Open
  // pages on that host follow at once. OK replies a fresh listing.
  void (*set_site_zoom)(uint64_t request, const char *profile_key, const char *host,
                        double factor);

  // ABI39 clear browsing data and the downloads location (DEV-647). Main
  // thread; profile_key names an ordinary profile prepared with
  // prepare_profile. Every call replies once through profile_data_completed,
  // never synchronously. since is seconds from 1970; 0 means all time.
  // Counts what clearing the same kinds since that time would remove. OK:
  // {"cookies":{"sites":N},"cache":{"bytes":N,"upperLimit":false},
  // "autofill":{"entries":N,"addresses":N,"cards":N},"siteSettings":{"sites":N}},
  // with a key only for each kind asked that the engine counts (never HISTORY
  // or DOWNLOADS).
  void (*count_browsing_data)(uint64_t request, const char *profile_key, uint32_t kinds,
                              double since);
  // Removes those kinds from since until now, as Chrome's Clear Browsing Data
  // does (cookies with every other kind of site storage). OK: {"failed":[names]}
  // naming kinds Chromium couldn't fully clear. INVALID: no or unknown kinds,
  // or a bad time.
  void (*clear_browsing_data)(uint64_t request, const char *profile_key, uint32_t kinds,
                              double since);
  // OK: {"directory":"/Users/.../Downloads","ask":false,
  // "defaultDirectory":"/Users/.../Downloads","managed":false}.
  void (*download_settings)(uint64_t request, const char *profile_key);
  // Saves downloads to directory (an existing absolute directory; NULL or empty
  // keeps the current one), and, when ask is true, asks where to save each
  // file first. Private windows opened from this profile with
  // prepare_private_profile_for (ABI45) follow it at once; ones prepared with
  // prepare_private_profile keep the bootstrap or Default profile's settings.
  // OK replies the settings as download_settings does.
  void (*set_download_settings)(uint64_t request, const char *profile_key, const char *directory,
                                bool ask);

  // ABI40 the site menu's Clear Cache and Clear Cookies (DEV-633). Main thread;
  // profile_key names an ordinary profile prepared with prepare_profile and url
  // is a page's http(s) address. Both reply once through profile_data_completed,
  // never synchronously; INVALID carries {"reason"} ("url" or "kinds").
  // OK: {"domain":"example.com"}, the site whose data clear_site_data removes:
  // the address's registrable domain with all its subdomains, or the host
  // itself when it has none (an IP address, localhost).
  void (*site_data_scope)(uint64_t request, const char *profile_key, const char *url);
  // Removes COOKIES (with every other kind of site storage, as
  // clear_browsing_data does) and CACHE, all time, for that site only. Other
  // kinds are INVALID. BUSY while another clear of the profile runs.
  // OK: {"domain","failed":[names]}.
  void (*clear_site_data)(uint64_t request, const char *profile_key, const char *url,
                          uint32_t kinds);

  // ABI41 page zoom for View > Zoom In, Zoom Out and Actual Size (DEV-726).
  // Main thread, synchronous. The page's zoom factor (1.0 is 100%), or 0 for an
  // unknown page. default_factor, when not NULL, receives the page's profile
  // default zoom, one of the levels Zoom In and Zoom Out step through.
  double (*page_zoom)(uint64_t page, double *default_factor);
  // Sets the page's zoom factor (0.25-5.0) as Chrome's Zoom In does: for the
  // committed address's host, so every page on that host follows. An ordinary
  // profile keeps it (Site Settings lists it and site_settings_changed fires);
  // a private profile only while that profile lives. A page without a host
  // (file:, data:), or one already zoomed on its own, keeps it to itself until
  // it navigates. Factor 0 returns to the default zoom and resets pinch
  // magnification. False for an unknown page or a factor out of range.
  bool (*set_page_zoom)(uint64_t page, double factor);

  // ABI42 docked DevTools (DEV-733). Main thread. open_devtools opens it docked
  // at DevTools' saved side (right at first), or in its own window when DevTools
  // was undocked last. False when the page has no open DevTools. Reading the
  // layout after placing the docked view lets a pending activation focus it.
  bool (*devtools_layout)(uint64_t page, ArxDevToolsLayout *layout);
  // Opens DevTools if needed and shows a panel ("console", "network",
  // "elements", "sources"...: lowercase letters, digits, - and _).
  ArxDevToolsStatus (*show_devtools_panel)(uint64_t page, const char *panel);
  // Opens DevTools if needed and starts Inspect Element's picker in the page.
  ArxDevToolsStatus (*start_devtools_inspect)(uint64_t page);

  // ABI44 Chrome Web Store installs (DEV-765). Main thread. Downloads the
  // token's item from the store (Google's update endpoint, no cookies, at most
  // 32 MiB, HTTPS redirects only) into the token's ordinary profile, then
  // continues as install_extension_crx for a new install: Web Store publisher
  // signature, the requested ID, MV3, extension_install_prompt with the
  // package's SHA-256 and permissions, resolve_extension_install, and
  // extensions_completed for request. The store page gets the outcome.
  // Unknown, used or expired tokens complete with STALE.
  void (*install_webstore_extension)(const char *profile_key, uint64_t request,
                                     uint64_t inventory_revision, uint64_t token);
  // Answers the store that the user cancelled. Unknown tokens are ignored.
  void (*decline_webstore_install)(uint64_t token);

  // ABI45 private windows follow their opener's downloads (DEV-729). Main
  // thread. As prepare_private_profile, and the private context's downloads
  // folder, save-as folder and "Ask where to save" follow opener_profile_key's,
  // an ordinary profile prepared with prepare_profile ("" is Default): copied
  // now and whenever the opener's change, until either profile goes away. The
  // values live only in the private context; the opener's prefs are only read.
  // DEV-889: the private context is the opener's own off-the-record child, so
  // the opener's extensions allowed in private windows (ARX_EXTENSION_ALLOW_
  // PRIVATE) run there, and the opener stays loaded until the context is gone
  // (release_profile and retirement refuse it). A NULL or unprepared opener
  // follows nothing and parents the context as prepare_private_profile does.
  // Calling it again for a prepared private key links its downloads to this
  // opener; its parent doesn't change.
  // False as prepare_private_profile, or when the opener is a private key.
  bool (*prepare_private_profile_for)(const char *key, const char *opener_profile_key);

  // ABI45 Chrome Web Store updates (DEV-776). Main thread. extension_id must be
  // installed in profile_key's ordinary profile and come from the store.
  // Downloads the store's current package for it as install_webstore_extension
  // does (no cookies, at most 32 MiB, HTTPS redirects only) and, when its
  // version is newer, continues as install_extension_crx for an update: Web
  // Store publisher signature, the same ID, MV3, then extension_install_prompt
  // with "isUpdate" and "permissionIncrease", resolve_extension_install and
  // extensions_completed for request. Completes with UP_TO_DATE when the store
  // has nothing newer, INVALID_REQUEST for an extension that isn't from the
  // store or isn't installed there, FAILED when the download fails. Cancel with
  // cancel_extension_request. One install or update per profile at a time.
  void (*update_webstore_extension)(const char *profile_key, uint64_t request,
                                    uint64_t inventory_revision, const char *extension_id);

  // ABI45 page menu (DEV-795). Main thread. titles holds one UTF-8 title per
  // ArxPageMenuItem before ARX_PAGE_MENU_ITEM_COUNT, at most 256 bytes each,
  // copied. Until then, or after a call with NULL or an empty title, a right
  // click on the page shows what it did before: Inspect Element in developer
  // mode, Chromium's own menu otherwise. Once set, the page menu shows the
  // items (Save As, Print, View Source and, since ABI48, Share only for http(s)
  // pages), plus Inspect Element in developer mode, and reports a choice with
  // page_menu_chosen. Links, editable fields, selections, images and media
  // keep their menus (ABI48: see configure_context_menus).
  void (*configure_page_menu)(const char *const *titles, size_t count);
  // ABI45 Save Page As (DEV-795). Main thread. Saves the page's current http(s)
  // document with Chromium's SavePackage to an absolute path; COMPLETE puts the
  // page's resources in "<name>_files" beside it. The save runs as a download
  // in the page's profile, so download observers see it. False when the page,
  // path or kind is invalid or Chromium refused to start.
  bool (*save_page)(uint64_t page, const char *path, ArxSavePageKind kind);

  // ABI46 credential migration (DEV-830). Main thread. profile_key names an
  // ordinary profile prepared with prepare_profile ("" is Default). Each call
  // replies once through credential_import_completed, never synchronously, and
  // one call runs per profile at a time (BUSY otherwise). A cookie key below is
  // {"domain","name","path","topFrameSiteKey","hasCrossSiteAncestor",
  // "sourceScheme","sourcePort"}; a password key is {"signonRealm","username",
  // "dateCreated"}, where dateCreated is the store's creation time as a decimal
  // string of microseconds since 1601.

  // Adds up to 10000 passwords to the profile's own store (never the account
  // store), as imported HTML-form credentials. A row whose url isn't http(s),
  // whose signon_realm isn't url's realm, or with an empty or too long field is
  // skipped. A (signon_realm, username) pair already stored, or earlier in the
  // call, keeps its password and counts as a conflict. The entries are read
  // back after the write, so "imported" lists only what the store kept; a row
  // it didn't keep counts as skipped. Once the write has started, any failure
  // (store error, lost profile, timeout) still replies OK, with every
  // attempted row in "unconfirmed" (and counted as skipped): it may have been
  // stored, so the caller keeps those keys for undo. OK:
  // {"imported":[<password key>],"unconfirmed":[<password key>],"conflicts":n,"skipped":n}.
  void (*import_password_records)(uint64_t request, const char *profile_key,
                                  const ArxImportedPassword *records, size_t count);
  // Sets up to 20000 cookies through the profile's CookieManager, with their
  // source scheme and port, so __Host- and Secure cookies keep their identity.
  // A cookie Chromium would treat as the same one as a cookie already set is
  // kept as it is and counted as existing; one Chromium refuses, or that isn't
  // canonical, is rejected; so is a cookie whose name and value exceed 4096
  // bytes, whose domain isn't a canonical host or whose site exceeds 2048 bytes.
  // Paths keep any length. Strings are read up to 1 MiB; a longer one, or a
  // missing domain, name, path or site, makes the whole call INVALID (the app
  // never sends one). A set whose reply never came, or every set still
  // outstanding when the request fails or times out, is listed as rejected and
  // also in "unconfirmed": it may be stored, so the caller keeps it for undo.
  // OK: {"accepted":[<cookie key>],"existing":[<cookie key>],
  // "rejected":[<cookie key>],"unconfirmed":[<cookie key>]}, every input in
  // exactly one of the first three lists. Native has no notion of a site; the
  // caller groups the keys.
  void (*import_cookies)(uint64_t request, const char *profile_key,
                         const ArxImportedCookie *cookies, size_t count);
  // keys is JSON [<cookie key>]. Reads the profile's cookies back and answers
  // which keys match an unexpired cookie on all seven fields. OK:
  // {"present":[<cookie key>]}.
  void (*check_cookies)(uint64_t request, const char *profile_key, const char *keys);
  // Removes exactly what one import added. keys is JSON
  // {"passwords":[<password key>],"cookies":[<cookie key>]}. A password goes
  // only while its stored entry is unchanged since the import (creation and
  // password-modified times both still dateCreated); a cookie only when all
  // seven key fields match. Undo reads the store and cookies again after
  // deleting and replies OK only when none of the matched entries is left;
  // otherwise, or on a dropped network-service reply (here or in
  // check_cookies), FAILED, and the caller keeps the batch to retry. Undo is
  // idempotent. OK: {"removed":n}.
  void (*undo_credential_import)(uint64_t request, const char *profile_key, const char *keys);

  // ABI47 store installs by ID (DEV-845), for bringing extensions over from
  // another browser. Main thread. Installs the Chrome Web Store item
  // extension_id into profile_key's ordinary profile with no store page and no
  // token: downloads its package as install_webstore_extension does (Google's
  // update endpoint, no cookies, at most 32 MiB, HTTPS redirects only), then
  // continues as install_extension_crx for a new install: Web Store publisher
  // signature, the requested ID, MV3, extension_install_prompt with the
  // package's SHA-256 and permissions, resolve_extension_install, and
  // extensions_completed for request. The user approves every install.
  // Completes with INVALID_REQUEST for an invalid ID or one already installed
  // in that profile, BUSY while another store install or update runs there,
  // FAILED when the download fails. Cancel with cancel_extension_request.
  void (*install_webstore_extension_by_id)(const char *profile_key, uint64_t request,
                                           uint64_t inventory_revision, const char *extension_id);

  // ---- ABI48 (DEV-814) context menus: begin ----
  // Main thread. titles holds one UTF-8 title per ArxContextMenuItem before
  // ARX_CONTEXT_MENU_ITEM_COUNT, at most 256 bytes each, copied. Until then, or
  // after a call with NULL or an empty title, those right clicks show what they
  // did before: Inspect Element alone in developer mode, Chromium's own menu
  // otherwise. Once set, a right click on an editable field, a selection, an
  // image, a video or audio (not on an http(s) link, which keeps the link
  // menu) shows Arx's menu for it, with Inspect Element last in developer
  // mode. AppKit adds its own items to it (Writing Tools, AutoFill, Services).
  void (*configure_context_menus)(const char *const *titles, size_t count);
  // ---- ABI48 (DEV-814) context menus: end ----

  // ABI48 extension actions from the app (DEV-828). Main thread. Runs
  // extension_id's toolbar action for a page, as a click on its
  // toolbar button: Chromium's ExtensionActionRunner grants activeTab and opens
  // the popup, or sends action.onClicked when there's none. The popup is the
  // page's own (the one the native Extensions menu opens, ABI22) and replaces
  // any popup the page had. It shows anchored at screen_x, screen_y: AppKit
  // screen coordinates (points, origin bottom-left of the primary screen),
  // kept inside the page's window. The app calls it only for the person's
  // click, such as an extension's tile in the site menu; the page must be in a
  // visible window while Arx is active. A private page acts for its opener's
  // extensions allowed in private windows (DEV-956). extension_id is a
  // borrowed, NUL-ended 32-letter ID.
  ArxExtensionActionRunStatus (*run_extension_action)(uint64_t page, const char *extension_id,
                                                      double screen_x, double screen_y);

  // ABI48 document type (DEV-819). Main thread. The kind of the page's
  // committed main document, read from Chromium's contents MIME type, so a PDF
  // reads as PDF while the viewer is still loading it. Save Page As classifies
  // a page with it instead of probing request_pdf, which answers UNAVAILABLE
  // while a page loads.
  ArxPageDocumentType (*page_document_type)(uint64_t page);
  // ABI50 app links (DEV-857). Main thread. True while the link the page took
  // last with this token (external_link_requested) still comes from a current
  // source: the same main document, and Chrome's exact initiator check still
  // passes (the frame that asked hasn't navigated or gone). Recheck right
  // before running a script or opening the app. False for any older token.
  bool (*external_link_is_current)(uint64_t page, uint64_t token);
  // ABI50 site icon fetch (DEV-796). Whether lookup_site_icon may fetch a site's
  // icon when the profile's favicon database has none (Settings: Fetch icons
  // for tabs that haven't loaded). On by default; may be set before run. Off,
  // a miss answers MISSING and nothing is requested.
  void (*set_site_icon_fetch)(bool enabled);
  // ABI51 (DEV-940). As lookup_site_icon, but a database miss answers MISSING and
  // never fetches: for reads only the app's bookkeeping needs, not a shown icon.
  void (*lookup_cached_site_icon)(const char *profile_key, const char *page_url,
                                  uint64_t request);

  // ABI52 autofill (DEV-875, DEV-893). Main thread. Fills the item at index
  // of the page's current session, as a click on it: a saved password fills
  // its username and password, an address or card the fields of its form.
  // Asks the device owner first where set_autofill_authentication says so;
  // a refused or cancelled prompt, or a page that navigated meanwhile, fills
  // nothing. A Manage item hides the session with "open". False when the
  // session or index isn't current. Within 500 ms of the list appearing a
  // choice is ignored (true, nothing happens), as Chrome's popup ignores it.
  bool (*accept_autofill_suggestion)(uint64_t page, uint64_t session, uint32_t index);
  // The item the pointer is over, or -1, so Return fills it.
  void (*select_autofill_suggestion)(uint64_t page, uint64_t session, int32_t index);
  void (*dismiss_autofill_suggestions)(uint64_t page, uint64_t session);
  // App-wide, may be set before run; ASK_DEVICE_OWNER until set. The reasons
  // are LocalAuthentication's localized prompts, at most 256 UTF-8 bytes; a
  // missing one refuses fills that need it.
  void (*set_autofill_authentication)(ArxAutofillAuthentication mode,
                                      const char *password_reason, const char *card_reason);
  // ABI52 (DEV-893). Main thread. Whether ordinary profiles fill addresses
  // and payment cards; both on until set, and never in private pages. Applied
  // to every ordinary profile with a page now and as pages open.
  void (*set_autofill_products)(bool addresses, bool cards);
  // Settings › Autofill, one ordinary profile. Each replies once through
  // autofill_data_completed. An address is a JSON object with the listing's
  // keys (strings, country a two-letter code) and "id" to edit one. A card is
  // {"id"?, "name", "nickname", "month", "year"}; its number is read from the
  // lent NSTextField (digits only) during the call, and an edit with an empty
  // field keeps the saved number.
  void (*list_autofill_data)(const char *profile_key, uint64_t request);
  void (*save_autofill_address)(const char *profile_key, uint64_t request, const char *json);
  void (*save_autofill_card)(const char *profile_key, uint64_t request, const char *json,
                             void *number_field);
  void (*remove_autofill_data)(const char *profile_key, uint64_t request, const char *id);
  void (*cancel_autofill_data)(uint64_t request);

  // ABI54 (DEV-949). Main thread. Takes the page out of HTML full screen, as
  // Escape does: when the app shows another tab or space, closes its window or
  // leaves macOS full screen. page_fullscreen_changed reports it. False when
  // the page isn't in full screen.
  bool (*exit_page_fullscreen)(uint64_t page);

  // ABI56 (DEV-851). Main thread. The link menu's Download Linked File: while
  // the link menu `token` is current, downloads its link from the link's own
  // frame with that frame's sanitized referrer and charset and the link's
  // suggested name, as Chrome's Save Link As, in the page's ordinary profile.
  // Checks and replies as start_download (download_started with `request`);
  // false refuses at once (stale menu, private page, not an http(s) link).
  bool (*download_link_context)(uint64_t page, uint64_t token, uint64_t request);

  // ABI56 (DEV-963). Main thread. The app draws site permission prompts. Set
  // once at launch; off (the default) keeps the engine's own sheet and its
  // quiet "Permission request…" button exactly as before. On, an ordinary ask
  // (or one asked again after a block) builds no sheet or button: the engine
  // reports it through page_permission_prompt_changed and waits for the app's
  // answer; other prompts (already allowed, macOS settings, administrator) keep
  // the engine's sheet. ABI31's page_dialog and answer_page_dialog still read
  // and answer either kind.
  void (*set_page_prompts_hosted)(bool hosted);
  // The page's current hosted prompt as UTF-8 JSON, borrowed until the next
  // call: {"token" (decimal string), "variant" ("ask" | "previouslyDenied"),
  // "requestingOrigin", "embeddingOrigin" (null when the same), "permissions"
  // (one name per request: notifications, camera, microphone, geolocation,
  // clipboard, or Chromium's content setting name), "fragments" (Chromium's
  // wording per request, in the same order), "allowOnce", "geolocation" (null,
  // or {"prompt": "default" | "approximateOnly" | "upgradeToPrecise",
  // "initial": "approximate" | "precise"}), "quiet"}. False when `token` isn't
  // the page's current hosted prompt.
  bool (*copy_page_permission_prompt)(uint64_t page, uint64_t token, const char **json,
                                      size_t *size);
  // Answers that exact prompt. INVALID for Allow Once where it isn't offered,
  // or an accuracy the prompt can't take; STALE when it's no longer current.
  // Any answer but a dismissal becomes a dismissal unless the page's window is
  // the active key window (or holds the app's sheet) and half a second has
  // passed since the prompt was reported.
  ArxPageDialogStatus (*answer_page_permission_prompt)(uint64_t page, uint64_t token,
                                                      ArxPagePermissionDecision decision,
                                                      ArxPagePermissionAccuracy accuracy);

  // ABI57 (DEV-996). Main thread. The app's page translation scripts, as
  // evaluate_script but in Arx's translation world, an isolated world of the
  // main frame apart from the developer world, with the same credential hooks.
  // Private pages are accepted. The same limits and replies, through
  // developer_completed; cancel_developer cancels it. One translation script
  // per page at a time, alongside at most one evaluate_script.
  void (*evaluate_translation_script)(uint64_t page, uint64_t request, const char *source,
                                      uint32_t maximum_bytes, uint32_t timeout_ms);

  // ABI58 (DEV-1009), staged. Main thread. A page whose renderer stopped answering:
  // Chromium reports a visible page that left an input unanswered for 15 s; while a
  // DevTools client is attached (request capture), the engine pings a visible page every
  // 5 s and counts 15 s without an answer instead. page_changed follows each change.
  // page_unresponsive is 0 while the page answers, else the number of its current hang,
  // which grows with each report.
  uint32_t (*page_unresponsive)(uint64_t page);
  // Wait: the engine checks again; a hang still there comes back with a new number.
  // False when the page answers.
  bool (*wait_for_page)(uint64_t page);
  // Ends the page's renderer process (and every page sharing it) as Chrome's Exit Page
  // does; the page then reports its renderer gone. A reload or navigation after it starts
  // a new one. False without a live renderer.
  bool (*end_page_renderer)(uint64_t page);
  // Asks the page's main frame for nothing, apart from evaluate_script's queue, which a
  // script a frozen page holds keeps busy. Replies through developer_completed: OK when the
  // page answers, TIMEOUT after timeout_ms (at most 30000), UNAVAILABLE without a live
  // renderer, while DevTools is open on it (a breakpoint isn't a hang), and while the page
  // waits on its own alert, confirm or prompt or Chromium has frozen it. Private pages too.
  void (*ping_page)(uint64_t page, uint64_t request, uint32_t timeout_ms);

  // ABI58 (DEV-1016), staged. Main thread. Why the page's renderer last ended: its number
  // (1 for the page's first end, growing with each), Chromium's termination status
  // (ARX_RENDERER_END_*), the process's exit code, and whether the engine ended it itself
  // (end_page_renderer). page_changed follows an end, and again once a late exit code is
  // known. False before the page's first end.
  bool (*page_renderer_end)(uint64_t page, ArxRendererEnd *end);

  // ABI59 (DEV-1065), staged. Main thread. The page's main-frame documents committed so far:
  // it grows with each new document, a reload or the page's own location.reload() included,
  // and not with a fragment, history.pushState or a frame in the page. page_changed follows.
  // 0 before the first.
  uint64_t (*page_main_document)(uint64_t page);
  // ABI60 (DEV-1118). Main thread. The app shows the link status: pages
  // report hovered links through page_link_hovered, after asking their frames
  // where each navigates. Off, the default, reports nothing and runs no script.
  void (*set_link_hover_reports)(bool enabled);

  // ABI61 (DEV-1101). Main thread. The colors of the page's primary
  // document, as Chromium keeps them for the browser around it: the theme
  // color from <meta name="theme-color"> (Blink picks the tag whose media
  // matches the page's light or dark scheme; WebContents::GetThemeColor) and
  // the background its CSS gives the document (GetBackgroundColor). page_changed
  // follows each change of either (DidChangeThemeColor,
  // OnBackgroundColorChanged). False, with nothing set, for an unknown page.
  bool (*page_colors)(uint64_t page, ArxPageColors *colors);
} ArxEngineAPI;

// The framework returns NULL for an incompatible version or table size.
typedef const ArxEngineAPI *(*ArxEngineGetAPIFunction)(uint32_t version,
                                                    size_t table_size);

// DEV-898 Task Manager, exported outside the ABI table like
// ArxEngineSetPageAudioVolume, so the app looks both up with dlsym and runs on
// older engines without a Task Manager.
typedef enum ArxEngineProcessKind {
  // A page's renderer: `page` names it. Several pages may share one process.
  ARX_ENGINE_PROCESS_PAGE = 0,
  // An extension's renderer (background page, service worker, popup):
  // `extension_id` names it.
  ARX_ENGINE_PROCESS_EXTENSION = 1,
} ArxEngineProcessKind;

typedef struct ArxEngineProcess {
  int32_t pid;
  int32_t kind;
  uint64_t page;
  bool is_private;
  // NUL-terminated, for ARX_ENGINE_PROCESS_EXTENSION; empty otherwise.
  char extension_id[33];
} ArxEngineProcess;

// size_t ArxEngineCopyProcesses(ArxEngineProcess *entries, size_t capacity):
// main thread. Writes up to `capacity` live renderer processes the engine
// knows: one entry per page and one per extension running in a process.
// Returns how many there are, which may be more than `capacity`.
typedef size_t (*ArxEngineCopyProcessesFunction)(ArxEngineProcess *entries,
                                                 size_t capacity);

// DEV-892 download pause and resume, exported outside the ABI table.
// ArxEngineDownloadControl(key, guid) answers these bits for a transfer of the
// profile `key` ("" for the legacy profile), or 0 when it's unknown or blocked
// as dangerous. Main thread.
enum {
  ARX_DOWNLOAD_CONTROL_PAUSED = 1u << 0,
  ARX_DOWNLOAD_CONTROL_CAN_RESUME = 1u << 1,
  ARX_DOWNLOAD_CONTROL_CAN_PAUSE = 1u << 2,
};
typedef uint32_t (*ArxEngineDownloadControlFunction)(const char *key,
                                                     const char *guid);
// Pauses an in-progress transfer, or resumes a paused or resumable interrupted
// one (Chromium's DownloadItem::Pause and Resume). False when the transfer
// can't do that now. The change arrives through download_changed. Main thread.
typedef bool (*ArxEngineSetDownloadPausedFunction)(const char *key,
                                                   const char *guid,
                                                   bool paused);
// Removes a finished, cancelled or interrupted transfer from Chromium's
// download history, so it doesn't come back after a relaunch. The file stays.
// False for a transfer in progress or an unknown one. Main thread.
typedef bool (*ArxEngineRemoveDownloadFunction)(const char *key,
                                                const char *guid);
// DEV-1130, exported outside the ABI table as ArxEngineLostOnQuitDownloadCount:
// how many transfers in progress, paused ones included, a quit would lose.
// Every one in a private context, and an ordinary one Chromium couldn't
// continue from its bytes on disk: no strong validator (ETag or
// Last-Modified), Accept-Ranges: none, transient or Save Page As. Read
// synchronously from the native managers, so a transfer whose events haven't
// reached the app yet counts. Main thread.
typedef uint64_t (*ArxEngineLostOnQuitDownloadCountFunction)(void);

// DEV-924 request details for browser_logs, exported outside the ABI table.
// ArxEngineSetNetworkCapture starts or stops keeping an ordinary page's
// requests with their headers and bodies (credential and cookie headers never
// leave the engine); stopping drops them. Private pages are refused.
typedef bool (*ArxEngineSetNetworkCaptureFunction)(uint64_t page, bool enabled);
// Writes the entries after `after` (at most `limit`, bodies cut at
// `body_bytes`, 0 for none) as NUL-terminated JSON into `buffer` when
// `capacity` is larger than the JSON, and returns the JSON's length either
// way. 0 when the page isn't capturing. Main thread.
typedef size_t (*ArxEngineReadNetworkCaptureFunction)(uint64_t page, uint64_t after,
                                                     uint32_t limit, uint32_t body_bytes,
                                                     char *buffer, size_t capacity);

// bool ArxEngineEndProcess(int32_t pid): main thread. Ends a live renderer
// process (a page's or an extension's) the way Chrome's Task Manager does, with
// RenderProcessHost::Shutdown. False for any other process, including the
// browser, GPU and utility processes.
typedef bool (*ArxEngineEndProcessFunction)(int32_t pid);

// DEV-1172, exported outside the ABI table as ArxEngineCaptureWholePage and
// ArxEngineCancelWholePageCapture: the whole page, rendered beyond the viewport
// the way DevTools' "Capture full size screenshot" renders it. Arx's own DevTools
// protocol session asks for Page.captureScreenshot with captureBeyondViewport, so
// frames, video, canvas and WebGL come out as they show on screen (protected
// video stays blank). The page lays out at its whole height for that one frame
// and goes back to its own size after; it sees the resize. Engines built before
// it lack the exports, and the app keeps ABI16's document capture.
//
// Physical pixels. A taller or wider page is cut at maximum_dimension, and a
// page over maximum_pixels is cut shorter still; the snapshot says so (`cut`).
typedef struct ArxPageCaptureLimits {
  uint32_t maximum_dimension;      // 1...16384
  uint64_t maximum_pixels;         // 1...67108864
  uint64_t maximum_encoded_bytes;  // 1...67108864
  uint32_t timeout_ms;             // 1...30000
} ArxPageCaptureLimits;

// Borrowed only during the callback. Sizes are DIP, CSS pixels scaled by the
// browser zoom: the image is `width` x `height` physical pixels from the
// document's top-left corner, `captured_width` x `captured_height` of the
// `document_width` x `document_height` document, each DIP `device_scale`
// pixels.
typedef struct ArxPageCaptureSnapshot {
  const char *document_id;
  const uint8_t *png;
  size_t png_size;
  uint32_t width, height;
  double document_width, document_height;
  double captured_width, captured_height;
  double scroll_x, scroll_y;
  double viewport_width, viewport_height;
  double device_scale, zoom_level;
  bool cut, was_loading;
} ArxPageCaptureSnapshot;

typedef void (*ArxPageCaptureCallback)(void *context, uint64_t request,
                                       ArxCaptureStatus status,
                                       const ArxPageCaptureSnapshot *snapshot);

// bool ArxEngineCaptureWholePage(page, request, limits, done, context): main
// thread, for an Arx page that's shown. False, and no callback, when the engine
// isn't running, the page isn't an Arx page, `done` is NULL or `limits` are out
// of range. Otherwise `done` runs exactly once, later, on the main thread, with
// a snapshot on success or one of: ARX_CAPTURE_BUSY while another capture holds
// the engine's one capture slot, ARX_CAPTURE_UNAVAILABLE for a page that isn't
// shown, ARX_CAPTURE_STALE when the page navigated, closed, hid or moved,
// ARX_CAPTURE_LIMIT, ARX_CAPTURE_UNSUPPORTED when Chromium's capture failed or
// came back another size than measured, ARX_CAPTURE_ENCODING_FAILED,
// ARX_CAPTURE_TIMEOUT or ARX_CAPTURE_CANCELLED. A timed-out or canceled capture
// keeps the slot until Chromium's screenshot returns, so the page's own size is
// always restored first.
typedef bool (*ArxEngineCaptureWholePageFunction)(uint64_t page, uint64_t request,
                                                  const ArxPageCaptureLimits *limits,
                                                  ArxPageCaptureCallback done,
                                                  void *context);
// Completes `request` with ARX_CAPTURE_CANCELLED if it's in flight. Main thread.
typedef void (*ArxEngineCancelWholePageCaptureFunction)(uint64_t request);

#ifdef __cplusplus
}
#endif
#endif
