"""Tell Arx when a page asks for protected media (DEV-877).

Arx has no Widevine module, so `navigator.requestMediaKeySystemAccess` for a
protected key system fails and Netflix-class players stop. The app offers to
open such a site in WebKit, where macOS's FairPlay plays it.

A renderer frame asks the browser which key systems it may use once, the first
time the page touches Encrypted Media Extensions: `KeySystemSupportImpl::
SetObserver` in content. DEV-877 called an embedder observer there; since
DEV-1211 the document's `KeySystemSupportImpl` calls it from its reports (below).
The observer is declared in the dependency-free `chrome/browser/arx/
protected_media_hooks.h` and its setter is defined here, next to its call site,
as `unattended_prompts_overlay.py` does for its hooks.

DEV-1144: with `media::kArxWidevineAnswer` on, Widevine access resolves without a CDM, so
the first question would report pages that only probe (Apple's store checkout). The
observer then hears of the first question only while the feature is off. With it on, it
hears of:

- a library CDM that couldn't be created (`ReportProtectedMediaFailure`, called by
  `widevine_answer_overlay.py`), where a page that took the answer fails;
- a document left without protected media, once: a `requestMediaKeySystemAccess` for a
  protected key system was refused (a configuration the answer doesn't cover, such as a
  persistent licence or hardware-secure robustness, or another key system such as PlayReady
  or FairPlay), and no request or capability query in the document was granted one within
  3 seconds (DEV-1205). A document that isn't shown when the wait ends, such as one the
  person left for the back/forward cache, reports nothing.

DEV-1205: bot detection asks about every key system. Fingerprint's agent (resend.com) asks
`MediaCapabilities.decodingInfo` about Widevine, then `requestMediaKeySystemAccess` for
Widevine with and without a persistent licence, PlayReady, Clear Key, Primetime and FairPlay.
Chrome on a Mac grants Widevine and Clear Key and refuses the rest, and so does Arx. Reporting
every refusal offered WebKit on such a page. Now:

- `decodingInfo` is a capability query and never reports a refusal. Only the
  `requestMediaKeySystemAccess` initializer (`navigator_request_media_key_system_access.cc`)
  does, through `WebEncryptedMediaClient::ArxReportAccessRefused`.
- Every grant of a protected key system, from either API, is reported too. The browser
  (`KeySystemSupportImpl`, one per document) waits 3 seconds after a refusal and offers WebKit
  only if nothing was granted. A probing page is granted Widevine like Chrome and stays quiet.
- Clear Key isn't protected media under any of its names (`org.w3.clearkey`,
  `webkit-org.w3.clearkey`, External Clear Key).

The renderer reports through `KeySystemSupport.ArxReportAccessRejected` and
`ArxReportAccessGranted` on a connection the frame's `KeySystemConfigSelector` delegate keeps,
so the reports stay in order. The renderer drops its first connection after `SetObserver`, so
the browser takes the newer connection; the observer stays the first one's.

DEV-1211, Max's rule: a streaming site falls back to WebKit with a prompt, and a likely bot
check stays in Chromium with none. Each report says why (`arx::ProtectedMediaReason`):

- `kPlaybackFailed`: a media element wants keys Arx can't give it (keys that failed, or a
  refusal nothing was granted after), or, with the Widevine answer on, the document was refused
  every protected key system it asked for (DEV-1205).
- `kKeysWithoutMedia`: keys failed, or with the answer off a refusal went unanswered, and no
  media element wants keys yet. A bot check may create keys it never uses; a streaming player
  may stop before it loads media. The app offers WebKit for it only on a streaming site.

A media element wants keys when `setMediaKeys` gives it keys, it fires `encrypted`, or its
playback waits for a key, in the document or in a same-origin document of its page (a player
may keep its video in an iframe and its keys in the parent) (`html_media_element_encrypted_media.cc`), reported through
`WebEncryptedMediaClient::ArxReportMediaWantsKeys` and `KeySystemSupport.ArxReportMediaWantsKeys`
on the frame's kept connection. `arx::ReportProtectedMediaFailure` records failed keys on the
frame's document (`ArxNoteKeysFailed`). The first question reports nothing, with the answer on
or off. Each reason reports once per document, nothing after `kPlaybackFailed`, and only while
the document is active, except keys that fail to be created again: each failed creation
reports, as before, since the app may not have shown the first.

`upgrade_previous` turns a tree prepared with DEV-877's, DEV-1144's or DEV-1205's version into
this one, step by step. If an anchor changes, the build stops.
"""
from .overlay import replace_once

SOURCE = "content/browser/media/key_system_support_impl.cc"

HOOKS = ('#include "chrome/browser/arx/protected_media_hooks.h"  // nogncheck\n'
         '#include "base/feature_list.h"\n'
         '#include "media/base/media_switches.h"\n')


SETTER = """void arx::SetProtectedMediaObserver(ProtectedMediaObserver observer) {
  g_arx_protected_media_observer = observer;
}
"""

REPORT = """
void arx::ReportProtectedMediaFailure(content::RenderFrameHost* frame) {
  // Arx (DEV-1211): recorded on the frame's document, which decides whether a
  // page that can't play or a bot check that only made keys asked.
  if (frame) {
    content::KeySystemSupportImpl::GetOrCreateForCurrentDocument(frame)
        ->ArxNoteKeysFailed();
  }
}
"""


MOJOM = "media/mojo/mojom/key_system_support.mojom"
SUPPORT_HEADER = "content/browser/media/key_system_support_impl.h"
SELECTOR_HEADER = "third_party/blink/public/platform/media/key_system_config_selector.h"
CLIENT = "third_party/blink/renderer/platform/media/web_encrypted_media_client_impl.cc"
CLIENT_HEADER = "third_party/blink/public/platform/media/web_encrypted_media_client_impl.h"
PUBLIC_CLIENT = "third_party/blink/public/platform/web_encrypted_media_client.h"
REQUEST_ACCESS = "third_party/blink/renderer/modules/encryptedmedia/navigator_request_media_key_system_access.cc"
MEDIA_FACTORY = "content/renderer/media/media_factory.cc"
MEDIA_ELEMENT = "third_party/blink/renderer/modules/encryptedmedia/html_media_element_encrypted_media.cc"

# How long a refused request waits for a grant in the same document before it reports.
REJECTION_DELAY = "base::Seconds(3)"

MOJOM_ANCHOR = "  SetObserver(pending_remote<KeySystemSupportObserver> observer);\n"
MOJOM_REPORTS = (
    MOJOM_ANCHOR + "\n"
    "  // Arx (DEV-1144): the renderer rejected one of the frame's\n"
    "  // requestMediaKeySystemAccess requests for a protected key system.\n"
    "  ArxReportAccessRejected();\n\n"
    "  // Arx (DEV-1205): the renderer granted one of the frame's requests for a\n"
    "  // protected key system, through requestMediaKeySystemAccess or\n"
    "  // MediaCapabilities.decodingInfo.\n"
    "  ArxReportAccessGranted();\n\n"
    "  // Arx (DEV-1211): a media element in the frame wants keys: it was given\n"
    "  // MediaKeys, met encrypted media, or waits for a key.\n"
    "  ArxReportMediaWantsKeys();\n")

SUPPORT_DECLARATION_ANCHOR = ("  void SetObserver(mojo::PendingRemote<media::mojom::KeySystemSupportObserver>\n"
                              "                       observer) final;\n")
SUPPORT_DECLARATIONS = (SUPPORT_DECLARATION_ANCHOR
                        + "  void ArxReportAccessRejected() final;\n"
                        + "  void ArxReportAccessGranted() final;\n"
                        + "  void ArxReportMediaWantsKeys() final;\n"
                        + "  // Arx (DEV-1211): MediaInterfaceProxy found no CDM for this document's\n"
                        + "  // keys (arx::ReportProtectedMediaFailure).\n"
                        + "  void ArxNoteKeysFailed();\n")

SUPPORT_MEMBER_ANCHOR = "  mojo::Receiver<KeySystemSupport> key_system_support_receiver_{this};\n"
SUPPORT_MEMBERS = (SUPPORT_MEMBER_ANCHOR
                   + "  // Arx (DEV-1144, DEV-1205, DEV-1211): what this document did with protected\n"
                   "  // media, and what it reported: a protected key system granted, a refusal\n"
                   "  // left without a grant, keys that couldn't be created, a media element that\n"
                   "  // wants keys, and the wait for a grant after a refusal.\n"
                   "  void ArxRejectionUnanswered();\n"
                   "  void ArxReport(bool playback_failed);\n"
                   "  // Arx (DEV-1211): media in a same-origin frame of the page counts too.\n"
                   "  bool ArxPageMediaWantsKeys();\n"
                   "  void ArxPageMediaWantsKeysNow();\n"
                   "  bool arx_granted_access_ = false;\n"
                   "  bool arx_rejection_unanswered_ = false;\n"
                   "  bool arx_keys_failed_ = false;\n"
                   "  bool arx_media_wants_keys_ = false;\n"
                   "  bool arx_reported_keys_without_media_ = false;\n"
                   "  bool arx_reported_playback_failure_ = false;\n"
                   "  base::OneShotTimer arx_rejection_timer_;\n"
                   "  // Arx (DEV-1211): the frame's report connections after the first.\n"
                   "  mojo::ReceiverSet<KeySystemSupport> arx_key_system_support_receivers_;\n")

SUPPORT_INCLUDE_ANCHOR = '#include "base/memory/weak_ptr.h"\n'
SUPPORT_INCLUDES = (SUPPORT_INCLUDE_ANCHOR + '#include "base/timer/timer.h"\n'
                    + '#include "mojo/public/cpp/bindings/receiver_set.h"\n')

BIND_ANCHOR = ("  // Only one receiver is allowed. This is not expected to happen. Renderers\n"
               "  // are expected to maintain one connection per RenderFrame.\n")
BIND = ("  // Arx (DEV-1144, DEV-1211): the frame keeps a second connection for its\n"
        "  // protected media reports. The first may still carry SetObserver when the\n"
        "  // first report comes (a media element meets encrypted media before the\n"
        "  // page's first EME request), so each stays bound; a later one replaces\n"
        "  // nothing.\n"
        "  if (key_system_support_receiver_.is_bound()) {\n"
        "    arx_key_system_support_receivers_.Add(this, std::move(receiver));\n"
        "    return;\n"
        "  }\n"
        + BIND_ANCHOR)

REPORT_REJECTED = """// Arx (DEV-1144, DEV-1205, DEV-1211): what this document did with protected
// media decides whether the embedder hears of it, and why. A page that can't
// play its protected media is reported as playback that failed; keys a page
// made without any media wanting them may be a bot check's, reported as such,
// so the embedder offers another engine only where streaming is likely.
//
// - A refused requestMediaKeySystemAccess for a protected key system waits
//   3 seconds for a grant. Bot detection asks about every key system and is
//   granted Widevine, as in Chrome. With the Widevine answer on, a document
//   granted nothing wants a key system Arx lacks: playback failed. With it
//   off, every page is refused Widevine, bot checks too, so a refusal is
//   playback failing only once a media element wants keys.
// - Keys that couldn't be created (Widevine answered without a CDM) are
//   playback failing once a media element wants keys, and keys without media
//   until then.
// - A media element counts in this document or in a same-origin document of
//   the same page: a player may keep its video in a frame and its keys in
//   another.
//
// Each reason reports once per document, and after playback failing nothing
// does, except keys that fail to be created again.
void KeySystemSupportImpl::ArxReportAccessRejected() {
  // A refusal after an earlier wait ended waits again: that wait's report may
  // have been dropped while the document wasn't shown, and the reasons already
  // reported won't report twice.
  if (arx_granted_access_ || arx_reported_playback_failure_ ||
      arx_rejection_timer_.IsRunning()) {
    return;
  }
  arx_rejection_timer_.Start(
      FROM_HERE, """ + REJECTION_DELAY + """,
      base::BindOnce(&KeySystemSupportImpl::ArxRejectionUnanswered,
                     base::Unretained(this)));
}

// Arx (DEV-1205): the document has a protected key system, so a refusal is a
// probe, not a page that can't play.
void KeySystemSupportImpl::ArxReportAccessGranted() {
  arx_granted_access_ = true;
  arx_rejection_timer_.Stop();
}

// Arx (DEV-1211): a media element in the document was given MediaKeys, met
// encrypted media, or waits for a key. A player may keep its video in one
// frame and make its keys in another, so every same-origin document of the
// page hears of it; each keeps its own state and reports.
void KeySystemSupportImpl::ArxReportMediaWantsKeys() {
  arx_media_wants_keys_ = true;
  const url::Origin origin = render_frame_host().GetLastCommittedOrigin();
  render_frame_host().GetOutermostMainFrame()->ForEachRenderFrameHost(
      [&origin](RenderFrameHost* frame) {
        if (!frame->GetLastCommittedOrigin().IsSameOriginWith(origin)) {
          return;
        }
        if (auto* support = KeySystemSupportImpl::GetForCurrentDocument(frame)) {
          support->ArxPageMediaWantsKeysNow();
        }
      });
}

// Arx (DEV-1211): media in this document or a same-origin one of its page now
// wants keys: keys that failed here, or a refusal nothing was granted after,
// are playback failing.
void KeySystemSupportImpl::ArxPageMediaWantsKeysNow() {
  if (arx_keys_failed_ || (arx_rejection_unanswered_ && !arx_granted_access_)) {
    ArxReport(/*playback_failed=*/true);
  }
}

// Arx (DEV-1211): whether media in this document, or in a same-origin document
// of the same page, wants keys.
bool KeySystemSupportImpl::ArxPageMediaWantsKeys() {
  if (arx_media_wants_keys_) {
    return true;
  }
  bool wants = false;
  const url::Origin origin = render_frame_host().GetLastCommittedOrigin();
  render_frame_host().GetOutermostMainFrame()->ForEachRenderFrameHost(
      [&origin, &wants](RenderFrameHost* frame) {
        if (wants || !frame->GetLastCommittedOrigin().IsSameOriginWith(origin)) {
          return;
        }
        auto* support = KeySystemSupportImpl::GetForCurrentDocument(frame);
        wants = support && support->arx_media_wants_keys_;
      });
  return wants;
}

void KeySystemSupportImpl::ArxNoteKeysFailed() {
  arx_keys_failed_ = true;
  // Each failed creation reports, as each did before: a player that retries is
  // asking again, and the embedder may not have shown the first report (a tab
  // in the background, another prompt showing).
  // Either reason may have reported before, from media now gone (an iframe
  // removed), so this creation's report clears both.
  arx_reported_playback_failure_ = false;
  arx_reported_keys_without_media_ = false;
  ArxReport(/*playback_failed=*/ArxPageMediaWantsKeys());
}

void KeySystemSupportImpl::ArxRejectionUnanswered() {
  if (arx_granted_access_) {
    return;
  }
  arx_rejection_unanswered_ = true;
  ArxReport(/*playback_failed=*/
            base::FeatureList::IsEnabled(media::kArxWidevineAnswer) ||
            ArxPageMediaWantsKeys());
}

void KeySystemSupportImpl::ArxReport(bool playback_failed) {
  if (arx_reported_playback_failure_ ||
      (!playback_failed && arx_reported_keys_without_media_)) {
    return;
  }
  // A document that isn't shown (in the back/forward cache, prerendering or
  // being unloaded) offers nothing: the prompt would show over another page.
  // It may report once it's shown again.
  if (!render_frame_host().IsActive()) {
    return;
  }
  if (playback_failed) {
    arx_reported_playback_failure_ = true;
  } else {
    arx_reported_keys_without_media_ = true;
  }
  if (g_arx_protected_media_observer) {
    g_arx_protected_media_observer(
        &render_frame_host(),
        playback_failed ? arx::ProtectedMediaReason::kPlaybackFailed
                        : arx::ProtectedMediaReason::kKeysWithoutMedia);
  }
}

"""

SELECTOR_DELEGATE_ANCHOR = ("    virtual bool AllowStorageAccessSync(\n"
                            "        WebContentSettingsClient::StorageType storage_type) = 0;\n")
SELECTOR_DELEGATE = (SELECTOR_DELEGATE_ANCHOR + "\n"
                     "    // Arx (DEV-1144): an access request for protected media was rejected.\n"
                     "    virtual void ArxReportAccessRejected() {}\n"
                     "    // Arx (DEV-1205): an access request or capability query for protected\n"
                     "    // media was granted.\n"
                     "    virtual void ArxReportAccessGranted() {}\n"
                     "    // Arx (DEV-1211): a media element wants keys.\n"
                     "    virtual void ArxReportMediaWantsKeys() {}\n")

SELECTOR_ANCHOR = "  ~KeySystemConfigSelector();\n"
SELECTOR_FORWARDS = (SELECTOR_ANCHOR + "\n"
                     "  // Arx (DEV-1144): passes a rejected protected media request on to the frame.\n"
                     "  void ArxReportAccessRejected() {\n"
                     "    if (web_frame_delegate_) {\n"
                     "      web_frame_delegate_->ArxReportAccessRejected();\n"
                     "    }\n"
                     "  }\n\n"
                     "  // Arx (DEV-1205): passes a granted protected key system on to the frame.\n"
                     "  void ArxReportAccessGranted() {\n"
                     "    if (web_frame_delegate_) {\n"
                     "      web_frame_delegate_->ArxReportAccessGranted();\n"
                     "    }\n"
                     "  }\n\n"
                     "  // Arx (DEV-1211): passes a media element that wants keys on to the frame.\n"
                     "  void ArxReportMediaWantsKeys() {\n"
                     "    if (web_frame_delegate_) {\n"
                     "      web_frame_delegate_->ArxReportMediaWantsKeys();\n"
                     "    }\n"
                     "  }\n")

PUBLIC_CLIENT_INCLUDE_ANCHOR = '#include "third_party/blink/public/platform/web_common.h"\n'
PUBLIC_CLIENT_ANCHOR = "  virtual void RequestMediaKeySystemAccess(WebEncryptedMediaRequest) = 0;\n"
PUBLIC_CLIENT_HOOK = (PUBLIC_CLIENT_ANCHOR
                      + "  // Arx (DEV-1205): navigator.requestMediaKeySystemAccess refused a request.\n"
                      "  // A capability query (MediaCapabilities.decodingInfo) never calls this.\n"
                      "  virtual void ArxReportAccessRefused(const WebString& key_system) {}\n"
                      "  // Arx (DEV-1211): a media element in the frame wants keys: it was given\n"
                      "  // MediaKeys, met encrypted media, or waits for a key.\n"
                      "  virtual void ArxReportMediaWantsKeys() {}\n")

CLIENT_HEADER_ANCHOR = "  void RequestMediaKeySystemAccess(WebEncryptedMediaRequest request) override;\n"
CLIENT_HEADER_HOOK = (CLIENT_HEADER_ANCHOR
                      + "  void ArxReportAccessRefused(const WebString& key_system) override;\n"
                      + "  void ArxReportMediaWantsKeys() override;\n")

CLIENT_REFUSED_ANCHOR = "void WebEncryptedMediaClientImpl::CreateCdm(\n"
CLIENT_REFUSED = """// Arx (DEV-1205): whether a key system is protected media, which WebKit may
// play. Clear Key isn't, under any of its names.
static bool ArxIsProtectedKeySystem(const WebString& key_system) {
  const std::string name = key_system.Utf8();
  return !media::IsClearKey(name) && !media::IsExternalClearKey(name) &&
         name != "webkit-org.w3.clearkey";
}

void WebEncryptedMediaClientImpl::ArxReportAccessRefused(
    const WebString& key_system) {
  if (ArxIsProtectedKeySystem(key_system)) {
    key_system_config_selector_.ArxReportAccessRejected();
  }
}

// Arx (DEV-1211): a media element in the frame wants keys.
void WebEncryptedMediaClientImpl::ArxReportMediaWantsKeys() {
  key_system_config_selector_.ArxReportMediaWantsKeys();
}

"""

CLIENT_GRANTED_ANCHOR = ("  // Use the returned key system which should be used for CDM creation.\n"
                         "  request.RequestSucceeded(")
CLIENT_GRANTED = """  // Arx (DEV-1205): the page has protected media, for an access request or a
  // decodingInfo query. A refused request then doesn't offer WebKit.
  if (ArxIsProtectedKeySystem(request.KeySystem())) {
    key_system_config_selector_.ArxReportAccessGranted();
  }

"""

REQUEST_ACCESS_ANCHOR = """  resolver_->Reject(MakeGarbageCollected<DOMException>(
      DOMExceptionCode::kNotSupportedError, error_message));
  resolver_.Clear();
}
"""
REQUEST_ACCESS_REFUSED = """  resolver_->Reject(MakeGarbageCollected<DOMException>(
      DOMExceptionCode::kNotSupportedError, error_message));
  resolver_.Clear();

  // Arx (DEV-1205): a refused request for protected media may offer WebKit.
  // MediaCapabilities.decodingInfo, a capability query, never does.
  if (DomWindow() && DomWindow()->GetFrame()) {
    if (WebEncryptedMediaClient* media_client =
            EncryptedMediaUtils::GetEncryptedMediaClientFromLocalDOMWindow(
                DomWindow())) {
      media_client->ArxReportAccessRefused(KeySystem());
    }
  }
}
"""

DELEGATE_ANCHOR = "  ~LocalFrameDelegate() override = default;\n"

# Where DEV-877 to DEV-1205 reported a frame's first EME question while the Widevine answer
# was off. DEV-1211 reports nothing there: a refusal follows the rule that answers it.
FIRST_QUESTION_ANCHOR = "  observer_remote_.Bind(std::move(observer));\n"
DELEGATE_REPORT = """  // Arx (DEV-1144, DEV-1205): tells the browser that a protected media access
  // request was refused, or granted. The renderer keeps no KeySystemSupport
  // connection after SetObserver, so the delegate keeps its own; one pipe
  // keeps the reports in order. The browser takes the newer connection.
  void ArxReportAccessRejected() override {
    if (media::mojom::KeySystemSupport* support = ArxKeySystemSupport()) {
      support->ArxReportAccessRejected();
    }
  }

  void ArxReportAccessGranted() override {
    if (media::mojom::KeySystemSupport* support = ArxKeySystemSupport()) {
      support->ArxReportAccessGranted();
    }
  }

  // Arx (DEV-1211): a media element in the frame wants keys.
  void ArxReportMediaWantsKeys() override {
    if (media::mojom::KeySystemSupport* support = ArxKeySystemSupport()) {
      support->ArxReportMediaWantsKeys();
    }
  }

  media::mojom::KeySystemSupport* ArxKeySystemSupport() {
    if (arx_key_system_support_.is_bound() &&
        arx_key_system_support_.is_connected()) {
      return arx_key_system_support_.get();
    }
    content::RenderFrameImpl* frame =
        content::RenderFrameImpl::FromWebFrame(&*web_frame_);
    if (!frame) {
      return nullptr;
    }
    arx_key_system_support_.reset();
    frame->GetBrowserInterfaceBroker().GetInterface(
        arx_key_system_support_.BindNewPipeAndPassReceiver());
    return arx_key_system_support_.get();
  }

"""

MEDIA_ELEMENT_INCLUDE_ANCHOR = (
    '#include "third_party/blink/renderer/modules/encryptedmedia/encrypted_media_utils.h"\n')
MEDIA_ELEMENT_INCLUDES = (MEDIA_ELEMENT_INCLUDE_ANCHOR
                          + '#include "third_party/blink/public/platform/web_encrypted_media_client.h"\n'
                          + '#include "third_party/blink/renderer/core/dom/document.h"\n'
                          + '#include "third_party/blink/renderer/core/frame/local_dom_window.h"\n')

MEDIA_ELEMENT_REPORT_ANCHOR = "ScriptPromise<IDLUndefined> HTMLMediaElementEncryptedMedia::setMediaKeys(\n"
MEDIA_ELEMENT_REPORT = """// Arx (DEV-1211): tells the browser that a media element in this frame wants
// keys. Keys that failed to be created are then a page that can't play, not a
// bot check that only made keys.
static void ArxReportMediaWantsKeys(HTMLMediaElement& element) {
  LocalDOMWindow* window = element.GetDocument().domWindow();
  if (!window || !window->GetFrame()) {
    return;
  }
  if (WebEncryptedMediaClient* client =
          EncryptedMediaUtils::GetEncryptedMediaClientFromLocalDOMWindow(
              window)) {
    client->ArxReportMediaWantsKeys();
  }
}

"""

MEDIA_ELEMENT_SET_KEYS_ANCHOR = ("  // 3. Let this object's attaching media keys value be true.\n"
                                 "  this_element.is_attaching_media_keys_ = true;\n")
MEDIA_ELEMENT_SET_KEYS = (MEDIA_ELEMENT_SET_KEYS_ANCHOR
                          + "  // Arx (DEV-1211): the page gives the element keys to play with.\n"
                          + "  if (media_keys) {\n"
                          + "    ArxReportMediaWantsKeys(element);\n"
                          + "  }\n")

MEDIA_ELEMENT_ENCRYPTED_ANCHOR = ("  event->SetTarget(GetSupplementable());\n"
                                  "  GetSupplementable()->ScheduleEvent(event);\n"
                                  "}\n\n"
                                  "void HTMLMediaElementEncryptedMedia::DidBlockPlaybackWaitingForKey() {\n")
MEDIA_ELEMENT_ENCRYPTED = ("  event->SetTarget(GetSupplementable());\n"
                           "  GetSupplementable()->ScheduleEvent(event);\n"
                           "  // Arx (DEV-1211): the element met encrypted media.\n"
                           "  ArxReportMediaWantsKeys(*GetSupplementable());\n"
                           "}\n\n"
                           "void HTMLMediaElementEncryptedMedia::DidBlockPlaybackWaitingForKey() {\n")

MEDIA_ELEMENT_WAITING_ANCHOR = ("  // 3. Set the media element's waiting for key value to true.\n"
                                "  is_waiting_for_key_ = true;\n")
MEDIA_ELEMENT_WAITING = (MEDIA_ELEMENT_WAITING_ANCHOR
                         + "  // Arx (DEV-1211): playback waits for a key.\n"
                         + "  ArxReportMediaWantsKeys(*GetSupplementable());\n")

DELEGATE_MEMBER_ANCHOR = "  const raw_ref<blink::WebLocalFrame> web_frame_;\n};\n"
DELEGATE_MEMBER = ("  const raw_ref<blink::WebLocalFrame> web_frame_;\n"
                   "  // Arx (DEV-1205): the connection Arx's access reports use.\n"
                   "  mojo::Remote<media::mojom::KeySystemSupport> arx_key_system_support_;\n"
                   "};\n")


def rejected_access_patches():
    """A document left without protected media reaches the observer (DEV-1144, DEV-1205)."""
    yield MOJOM, MOJOM_ANCHOR, MOJOM_REPORTS
    yield SUPPORT_HEADER, SUPPORT_INCLUDE_ANCHOR, SUPPORT_INCLUDES
    yield SUPPORT_HEADER, SUPPORT_DECLARATION_ANCHOR, SUPPORT_DECLARATIONS
    yield SUPPORT_HEADER, SUPPORT_MEMBER_ANCHOR, SUPPORT_MEMBERS
    yield SOURCE, BIND_ANCHOR, BIND
    yield SOURCE, "void KeySystemSupportImpl::SetObserver(\n", (
        REPORT_REJECTED + "void KeySystemSupportImpl::SetObserver(\n")
    yield SELECTOR_HEADER, SELECTOR_DELEGATE_ANCHOR, SELECTOR_DELEGATE
    yield SELECTOR_HEADER, SELECTOR_ANCHOR, SELECTOR_FORWARDS
    yield PUBLIC_CLIENT, PUBLIC_CLIENT_INCLUDE_ANCHOR, (
        PUBLIC_CLIENT_INCLUDE_ANCHOR + '#include "third_party/blink/public/platform/web_string.h"\n')
    yield PUBLIC_CLIENT, PUBLIC_CLIENT_ANCHOR, PUBLIC_CLIENT_HOOK
    yield CLIENT_HEADER, CLIENT_HEADER_ANCHOR, CLIENT_HEADER_HOOK
    yield CLIENT, '#include "media/base/key_systems.h"\n', (
        '#include "media/base/key_system_names.h"\n'
        '#include "media/base/key_systems.h"\n')
    yield CLIENT, CLIENT_REFUSED_ANCHOR, CLIENT_REFUSED + CLIENT_REFUSED_ANCHOR
    yield CLIENT, CLIENT_GRANTED_ANCHOR, CLIENT_GRANTED + CLIENT_GRANTED_ANCHOR
    yield REQUEST_ACCESS, REQUEST_ACCESS_ANCHOR, REQUEST_ACCESS_REFUSED
    yield MEDIA_FACTORY, '#include "mojo/public/cpp/bindings/pending_remote.h"\n', (
        '#include "mojo/public/cpp/bindings/pending_remote.h"\n'
        '#include "mojo/public/cpp/bindings/remote.h"\n')
    yield MEDIA_FACTORY, DELEGATE_ANCHOR, DELEGATE_REPORT + DELEGATE_ANCHOR
    yield MEDIA_FACTORY, DELEGATE_MEMBER_ANCHOR, DELEGATE_MEMBER
    yield MEDIA_ELEMENT, MEDIA_ELEMENT_INCLUDE_ANCHOR, MEDIA_ELEMENT_INCLUDES
    yield MEDIA_ELEMENT, MEDIA_ELEMENT_REPORT_ANCHOR, MEDIA_ELEMENT_REPORT + MEDIA_ELEMENT_REPORT_ANCHOR
    yield MEDIA_ELEMENT, MEDIA_ELEMENT_SET_KEYS_ANCHOR, MEDIA_ELEMENT_SET_KEYS
    yield MEDIA_ELEMENT, MEDIA_ELEMENT_ENCRYPTED_ANCHOR, MEDIA_ELEMENT_ENCRYPTED
    yield MEDIA_ELEMENT, MEDIA_ELEMENT_WAITING_ANCHOR, MEDIA_ELEMENT_WAITING


def patches():
    yield SOURCE, '#include "content/browser/media/key_system_support_impl.h"\n', (
        '#include "content/browser/media/key_system_support_impl.h"\n\n' + HOOKS)
    yield SOURCE, "namespace content {\n", '''namespace {
arx::ProtectedMediaObserver g_arx_protected_media_observer = nullptr;
}  // namespace

''' + SETTER + REPORT + '''
namespace content {
'''
    yield from rejected_access_patches()


# DEV-1144's inserted text, as a tree prepared with that version keeps it.
DEV_1144_REPORT_REJECTED = """// Arx (DEV-1144): the renderer rejected one of this document's access
// requests. While Widevine is answered without a CDM, the first question
// doesn't report, so this does, once per document.
void KeySystemSupportImpl::ArxReportAccessRejected() {
  if (!base::FeatureList::IsEnabled(media::kArxWidevineAnswer) ||
      arx_reported_access_rejection_) {
    return;
  }
  arx_reported_access_rejection_ = true;
  if (g_arx_protected_media_observer) {
    g_arx_protected_media_observer(&render_frame_host());
  }
}

"""

DEV_1144_DELEGATE_REPORT = """  // Arx (DEV-1144): tells the browser that a protected media access request
  // was rejected. The renderer keeps no KeySystemSupport connection after
  // SetObserver, so this opens one; the browser takes the newer connection.
  void ArxReportAccessRejected() override {
    content::RenderFrameImpl* frame =
        content::RenderFrameImpl::FromWebFrame(&*web_frame_);
    if (!frame) {
      return;
    }
    mojo::Remote<media::mojom::KeySystemSupport> support;
    frame->GetBrowserInterfaceBroker().GetInterface(
        support.BindNewPipeAndPassReceiver());
    support->ArxReportAccessRejected();
  }

"""

DEV_1144_CLIENT_ANCHOR = ("      request.RequestNotSupported(kUnsupportedKeySystemOrConfigMessage);\n"
                          "      GetPerProcessReporter(request.KeySystem())->ReportRejectTime();\n")

# DEV-1205's inserted text, as a tree prepared with that version keeps it (DEV-1211 upgrades it).
DEV_1205_MOJOM_REPORTS = (
    '  SetObserver(pending_remote<KeySystemSupportObserver> observer);\n'
    '\n'
    "  // Arx (DEV-1144): the renderer rejected one of the frame's\n"
    '  // requestMediaKeySystemAccess requests for a protected key system.\n'
    '  ArxReportAccessRejected();\n'
    '\n'
    "  // Arx (DEV-1205): the renderer granted one of the frame's requests for a\n"
    '  // protected key system, through requestMediaKeySystemAccess or\n'
    '  // MediaCapabilities.decodingInfo.\n'
    '  ArxReportAccessGranted();\n')
DEV_1205_SUPPORT_DECLARATIONS = (
    '  void SetObserver(mojo::PendingRemote<media::mojom::KeySystemSupportObserver>\n'
    '                       observer) final;\n'
    '  void ArxReportAccessRejected() final;\n'
    '  void ArxReportAccessGranted() final;\n')
DEV_1205_SUPPORT_MEMBERS = (
    '  mojo::Receiver<KeySystemSupport> key_system_support_receiver_{this};\n'
    '  // Arx (DEV-1144, DEV-1205): a refused request reported for this document,\n'
    '  // a protected key system granted to it, and the wait for a grant after a\n'
    '  // refusal.\n'
    '  void ArxReportUnansweredRejection();\n'
    '  bool arx_reported_access_rejection_ = false;\n'
    '  bool arx_granted_access_ = false;\n'
    '  base::OneShotTimer arx_rejection_timer_;\n')
DEV_1205_REPORT = (
    '\n'
    'void arx::ReportProtectedMediaFailure(content::RenderFrameHost* frame) {\n'
    '  if (g_arx_protected_media_observer) {\n'
    '    g_arx_protected_media_observer(frame);\n'
    '  }\n'
    '}\n')
DEV_1205_REPORT_REJECTED = (
    "// Arx (DEV-1144, DEV-1205): the renderer refused one of this document's\n"
    '// requestMediaKeySystemAccess requests for a protected key system. While\n'
    "// Widevine is answered without a CDM, the first question doesn't report, so\n"
    '// this may, once per document. Bot detection asks about every key system and\n'
    '// is granted Widevine, as in Chrome; a page left without any protected key\n'
    '// system wants one. So the report waits for a grant first.\n'
    'void KeySystemSupportImpl::ArxReportAccessRejected() {\n'
    '  if (!base::FeatureList::IsEnabled(media::kArxWidevineAnswer) ||\n'
    '      arx_reported_access_rejection_ || arx_granted_access_ ||\n'
    '      arx_rejection_timer_.IsRunning()) {\n'
    '    return;\n'
    '  }\n'
    '  arx_rejection_timer_.Start(\n'
    '      FROM_HERE, base::Seconds(3),\n'
    '      base::BindOnce(&KeySystemSupportImpl::ArxReportUnansweredRejection,\n'
    '                     base::Unretained(this)));\n'
    '}\n'
    '\n'
    '// Arx (DEV-1205): the document has a protected key system, so a refusal is a\n'
    "// probe, not a page that can't play.\n"
    'void KeySystemSupportImpl::ArxReportAccessGranted() {\n'
    '  arx_granted_access_ = true;\n'
    '  arx_rejection_timer_.Stop();\n'
    '}\n'
    '\n'
    'void KeySystemSupportImpl::ArxReportUnansweredRejection() {\n'
    '  if (arx_granted_access_ || arx_reported_access_rejection_) {\n'
    '    return;\n'
    '  }\n'
    "  // A document that isn't shown when the wait ends (in the back/forward cache,\n"
    '  // prerendering or being unloaded) offers nothing: the prompt would show over\n'
    "  // another page. A refusal after it's shown again may report.\n"
    '  if (!render_frame_host().IsActive()) {\n'
    '    return;\n'
    '  }\n'
    '  arx_reported_access_rejection_ = true;\n'
    '  if (g_arx_protected_media_observer) {\n'
    '    g_arx_protected_media_observer(&render_frame_host());\n'
    '  }\n'
    '}\n'
    '\n')
DEV_1205_SELECTOR_DELEGATE = (
    '    virtual bool AllowStorageAccessSync(\n'
    '        WebContentSettingsClient::StorageType storage_type) = 0;\n'
    '\n'
    '    // Arx (DEV-1144): an access request for protected media was rejected.\n'
    '    virtual void ArxReportAccessRejected() {}\n'
    '    // Arx (DEV-1205): an access request or capability query for protected\n'
    '    // media was granted.\n'
    '    virtual void ArxReportAccessGranted() {}\n')
DEV_1205_SELECTOR_FORWARDS = (
    '  ~KeySystemConfigSelector();\n'
    '\n'
    '  // Arx (DEV-1144): passes a rejected protected media request on to the frame.\n'
    '  void ArxReportAccessRejected() {\n'
    '    if (web_frame_delegate_) {\n'
    '      web_frame_delegate_->ArxReportAccessRejected();\n'
    '    }\n'
    '  }\n'
    '\n'
    '  // Arx (DEV-1205): passes a granted protected key system on to the frame.\n'
    '  void ArxReportAccessGranted() {\n'
    '    if (web_frame_delegate_) {\n'
    '      web_frame_delegate_->ArxReportAccessGranted();\n'
    '    }\n'
    '  }\n')
DEV_1205_PUBLIC_CLIENT_HOOK = (
    '  virtual void RequestMediaKeySystemAccess(WebEncryptedMediaRequest) = 0;\n'
    '  // Arx (DEV-1205): navigator.requestMediaKeySystemAccess refused a request.\n'
    '  // A capability query (MediaCapabilities.decodingInfo) never calls this.\n'
    '  virtual void ArxReportAccessRefused(const WebString& key_system) {}\n')
DEV_1205_CLIENT_REFUSED = (
    '// Arx (DEV-1205): whether a key system is protected media, which WebKit may\n'
    "// play. Clear Key isn't, under any of its names.\n"
    'static bool ArxIsProtectedKeySystem(const WebString& key_system) {\n'
    '  const std::string name = key_system.Utf8();\n'
    '  return !media::IsClearKey(name) && !media::IsExternalClearKey(name) &&\n'
    '         name != "webkit-org.w3.clearkey";\n'
    '}\n'
    '\n'
    'void WebEncryptedMediaClientImpl::ArxReportAccessRefused(\n'
    '    const WebString& key_system) {\n'
    '  if (ArxIsProtectedKeySystem(key_system)) {\n'
    '    key_system_config_selector_.ArxReportAccessRejected();\n'
    '  }\n'
    '}\n'
    '\n')
DEV_1205_DELEGATE_REPORT = (
    '  // Arx (DEV-1144, DEV-1205): tells the browser that a protected media access\n'
    '  // request was refused, or granted. The renderer keeps no KeySystemSupport\n'
    '  // connection after SetObserver, so the delegate keeps its own; one pipe\n'
    '  // keeps the reports in order. The browser takes the newer connection.\n'
    '  void ArxReportAccessRejected() override {\n'
    '    if (media::mojom::KeySystemSupport* support = ArxKeySystemSupport()) {\n'
    '      support->ArxReportAccessRejected();\n'
    '    }\n'
    '  }\n'
    '\n'
    '  void ArxReportAccessGranted() override {\n'
    '    if (media::mojom::KeySystemSupport* support = ArxKeySystemSupport()) {\n'
    '      support->ArxReportAccessGranted();\n'
    '    }\n'
    '  }\n'
    '\n'
    '  media::mojom::KeySystemSupport* ArxKeySystemSupport() {\n'
    '    if (arx_key_system_support_.is_bound() &&\n'
    '        arx_key_system_support_.is_connected()) {\n'
    '      return arx_key_system_support_.get();\n'
    '    }\n'
    '    content::RenderFrameImpl* frame =\n'
    '        content::RenderFrameImpl::FromWebFrame(&*web_frame_);\n'
    '    if (!frame) {\n'
    '      return nullptr;\n'
    '    }\n'
    '    arx_key_system_support_.reset();\n'
    '    frame->GetBrowserInterfaceBroker().GetInterface(\n'
    '        arx_key_system_support_.BindNewPipeAndPassReceiver());\n'
    '    return arx_key_system_support_.get();\n'
    '  }\n'
    '\n')
DEV_1205_FIRST_QUESTION = (
    '  observer_remote_.Bind(std::move(observer));\n'
    '\n'
    "  // Arx (DEV-877): the frame's first Encrypted Media Extensions request. The\n"
    '  // embedder may offer another engine for the page; it posts its work. While\n'
    '  // Widevine is answered without a CDM (DEV-1144), a failed CDM creation\n'
    "  // reports instead, so a page that only probes isn't offered another engine.\n"
    '  if (g_arx_protected_media_observer &&\n'
    '      !base::FeatureList::IsEnabled(media::kArxWidevineAnswer)) {\n'
    '    g_arx_protected_media_observer(&render_frame_host());\n'
    '  }\n')
DEV_1205_CLIENT_HEADER_HOOK = (
    '  void RequestMediaKeySystemAccess(WebEncryptedMediaRequest request) override;\n'
    '  void ArxReportAccessRefused(const WebString& key_system) override;\n')


# A prepared tree keeps an earlier version of this overlay: `upgrade_previous` turns each
# `previous` inserted text into this version's `current` before the anchors are checked.
DEV_877_UPGRADES = (
    (SOURCE, '#include "chrome/browser/arx/protected_media_hooks.h"  // nogncheck\n\n',
     HOOKS + "\n"),
    (SOURCE, SETTER + "\nnamespace content {\n", SETTER + DEV_1205_REPORT + "\nnamespace content {\n"),
    (SOURCE, """  // Arx (DEV-877): the frame's first Encrypted Media Extensions request. The
  // embedder may offer another engine for the page; it posts its work.
  if (g_arx_protected_media_observer) {
""", """  // Arx (DEV-877): the frame's first Encrypted Media Extensions request. The
  // embedder may offer another engine for the page; it posts its work. While
  // Widevine is answered without a CDM (DEV-1144), a failed CDM creation
  // reports instead, so a page that only probes isn't offered another engine.
  if (g_arx_protected_media_observer &&
      !base::FeatureList::IsEnabled(media::kArxWidevineAnswer)) {
"""),
)

# DEV-1144's inserted text becomes DEV-1205's.
DEV_1144_UPGRADES = (
    (MOJOM, MOJOM_ANCHOR + "\n"
     "  // Arx (DEV-1144): the renderer rejected one of the frame's\n"
     "  // requestMediaKeySystemAccess requests for a protected key system.\n"
     "  ArxReportAccessRejected();\n", DEV_1205_MOJOM_REPORTS),
    (SUPPORT_HEADER, SUPPORT_DECLARATION_ANCHOR + "  void ArxReportAccessRejected() final;\n",
     DEV_1205_SUPPORT_DECLARATIONS),
    (SUPPORT_HEADER, SUPPORT_MEMBER_ANCHOR
     + "  // Arx (DEV-1144): a rejected access request reported for this document.\n"
     "  bool arx_reported_access_rejection_ = false;\n", DEV_1205_SUPPORT_MEMBERS),
    (SOURCE, DEV_1144_REPORT_REJECTED + "void KeySystemSupportImpl::SetObserver(\n",
     DEV_1205_REPORT_REJECTED + "void KeySystemSupportImpl::SetObserver(\n"),
    (SELECTOR_HEADER, SELECTOR_DELEGATE_ANCHOR + "\n"
     "    // Arx (DEV-1144): an access request for protected media was rejected.\n"
     "    virtual void ArxReportAccessRejected() {}\n", DEV_1205_SELECTOR_DELEGATE),
    (SELECTOR_HEADER, SELECTOR_ANCHOR + "\n"
     "  // Arx (DEV-1144): passes a rejected protected media request on to the frame.\n"
     "  void ArxReportAccessRejected() {\n"
     "    if (web_frame_delegate_) {\n"
     "      web_frame_delegate_->ArxReportAccessRejected();\n"
     "    }\n"
     "  }\n", DEV_1205_SELECTOR_FORWARDS),
    # The client reported every refusal, decodingInfo's included; now the initializer does.
    (CLIENT, DEV_1144_CLIENT_ANCHOR
     + "      // Arx (DEV-1144): the page may play in WebKit instead. Clear Key isn't\n"
     "      // protected media.\n"
     "      if (const std::string key_system = request.KeySystem().Utf8();\n"
     "          !media::IsClearKey(key_system) &&\n"
     "          !media::IsExternalClearKey(key_system)) {\n"
     "        key_system_config_selector_.ArxReportAccessRejected();\n"
     "      }\n", DEV_1144_CLIENT_ANCHOR),
    (MEDIA_FACTORY, DEV_1144_DELEGATE_REPORT + DELEGATE_ANCHOR, DEV_1205_DELEGATE_REPORT + DELEGATE_ANCHOR),
)

# DEV-1205's first version reported a document that had left the screen.
DEV_1205_FIRST_VERSION_UPGRADES = (
    (SOURCE, "  if (arx_granted_access_ || arx_reported_access_rejection_) {\n"
     "    return;\n"
     "  }\n"
     "  arx_reported_access_rejection_ = true;\n",
     "  if (arx_granted_access_ || arx_reported_access_rejection_) {\n"
     "    return;\n"
     "  }\n"
     "  // A document that isn't shown when the wait ends (in the back/forward cache,\n"
     "  // prerendering or being unloaded) offers nothing: the prompt would show over\n"
     "  // another page. A refusal after it's shown again may report.\n"
     "  if (!render_frame_host().IsActive()) {\n"
     "    return;\n"
     "  }\n"
     "  arx_reported_access_rejection_ = true;\n"),
)

# DEV-1205's inserted text becomes this version's (DEV-1211). The first question no longer
# reports: its block goes, and the anchor stays.
DEV_1205_BIND = (
    "  // Arx (DEV-1144): the renderer drops its connection after SetObserver and\n"
    "  // opens another to report a rejected access request. The newer one wins;\n"
    "  // the observer stays the first connection's.\n"
    "  key_system_support_receiver_.reset();\n" + BIND_ANCHOR)

DEV_1205_UPGRADES = (
    (SUPPORT_HEADER, SUPPORT_INCLUDE_ANCHOR + '#include "base/timer/timer.h"\n', SUPPORT_INCLUDES),
    (SOURCE, DEV_1205_BIND, BIND),
    (MOJOM, DEV_1205_MOJOM_REPORTS, MOJOM_REPORTS),
    (SUPPORT_HEADER, DEV_1205_SUPPORT_DECLARATIONS, SUPPORT_DECLARATIONS),
    (SUPPORT_HEADER, DEV_1205_SUPPORT_MEMBERS, SUPPORT_MEMBERS),
    (SOURCE, DEV_1205_REPORT + "\nnamespace content {\n", REPORT + "\nnamespace content {\n"),
    (SOURCE, DEV_1205_REPORT_REJECTED + "void KeySystemSupportImpl::SetObserver(\n",
     REPORT_REJECTED + "void KeySystemSupportImpl::SetObserver(\n"),
    (SOURCE, DEV_1205_FIRST_QUESTION, FIRST_QUESTION_ANCHOR),
    (SELECTOR_HEADER, DEV_1205_SELECTOR_DELEGATE, SELECTOR_DELEGATE),
    (SELECTOR_HEADER, DEV_1205_SELECTOR_FORWARDS, SELECTOR_FORWARDS),
    (PUBLIC_CLIENT, DEV_1205_PUBLIC_CLIENT_HOOK, PUBLIC_CLIENT_HOOK),
    (CLIENT_HEADER, DEV_1205_CLIENT_HEADER_HOOK, CLIENT_HEADER_HOOK),
    (CLIENT, DEV_1205_CLIENT_REFUSED + CLIENT_REFUSED_ANCHOR, CLIENT_REFUSED + CLIENT_REFUSED_ANCHOR),
    (MEDIA_FACTORY, DEV_1205_DELEGATE_REPORT + DELEGATE_ANCHOR, DELEGATE_REPORT + DELEGATE_ANCHOR),
)

# DEV-1211's first version's inserted text (3b14ae64, engine batch 9's first build).
DEV_1211_FIRST_SUPPORT_MEMBERS = (
    '  mojo::Receiver<KeySystemSupport> key_system_support_receiver_{this};\n'
    '  // Arx (DEV-1144, DEV-1205, DEV-1211): what this document did with protected\n'
    '  // media, and what it reported: a protected key system granted, a refusal\n'
    "  // left without a grant, keys that couldn't be created, a media element that\n"
    '  // wants keys, and the wait for a grant after a refusal.\n'
    '  void ArxRejectionUnanswered();\n'
    '  void ArxReport(bool playback_failed);\n'
    '  bool arx_granted_access_ = false;\n'
    '  bool arx_rejection_unanswered_ = false;\n'
    '  bool arx_keys_failed_ = false;\n'
    '  bool arx_media_wants_keys_ = false;\n'
    '  bool arx_reported_keys_without_media_ = false;\n'
    '  bool arx_reported_playback_failure_ = false;\n'
    '  base::OneShotTimer arx_rejection_timer_;\n'
    "  // Arx (DEV-1211): the frame's report connections after the first.\n"
    '  mojo::ReceiverSet<KeySystemSupport> arx_key_system_support_receivers_;\n')
DEV_1211_FIRST_REPORT_REJECTED = (
    '// Arx (DEV-1144, DEV-1205, DEV-1211): what this document did with protected\n'
    "// media decides whether the embedder hears of it, and why. A page that can't\n"
    '// play its protected media is reported as playback that failed; keys a page\n'
    "// made without any media wanting them may be a bot check's, reported as such,\n"
    '// so the embedder offers another engine only where streaming is likely.\n'
    '//\n'
    '// - A refused requestMediaKeySystemAccess for a protected key system waits\n'
    '//   3 seconds for a grant. Bot detection asks about every key system and is\n'
    '//   granted Widevine, as in Chrome. With the Widevine answer on, a document\n'
    '//   granted nothing wants a key system Arx lacks: playback failed. With it\n'
    '//   off, every page is refused Widevine, bot checks too, so a refusal is\n'
    '//   playback failing only once a media element wants keys.\n'
    "// - Keys that couldn't be created (Widevine answered without a CDM) are\n"
    '//   playback failing once a media element wants keys, and keys without media\n'
    '//   until then.\n'
    '//\n'
    '// Each reason reports once per document, and after playback failing nothing\n'
    '// does, except keys that fail to be created again.\n'
    'void KeySystemSupportImpl::ArxReportAccessRejected() {\n'
    "  // A refusal after an earlier wait ended waits again: that wait's report may\n"
    "  // have been dropped while the document wasn't shown, and the reasons already\n"
    "  // reported won't report twice.\n"
    '  if (arx_granted_access_ || arx_reported_playback_failure_ ||\n'
    '      arx_rejection_timer_.IsRunning()) {\n'
    '    return;\n'
    '  }\n'
    '  arx_rejection_timer_.Start(\n'
    '      FROM_HERE, base::Seconds(3),\n'
    '      base::BindOnce(&KeySystemSupportImpl::ArxRejectionUnanswered,\n'
    '                     base::Unretained(this)));\n'
    '}\n'
    '\n'
    '// Arx (DEV-1205): the document has a protected key system, so a refusal is a\n'
    "// probe, not a page that can't play.\n"
    'void KeySystemSupportImpl::ArxReportAccessGranted() {\n'
    '  arx_granted_access_ = true;\n'
    '  arx_rejection_timer_.Stop();\n'
    '}\n'
    '\n'
    '// Arx (DEV-1211): a media element in the document was given MediaKeys, met\n'
    '// encrypted media, or waits for a key.\n'
    'void KeySystemSupportImpl::ArxReportMediaWantsKeys() {\n'
    '  arx_media_wants_keys_ = true;\n'
    '  if (arx_keys_failed_ || (arx_rejection_unanswered_ && !arx_granted_access_)) {\n'
    '    ArxReport(/*playback_failed=*/true);\n'
    '  }\n'
    '}\n'
    '\n'
    'void KeySystemSupportImpl::ArxNoteKeysFailed() {\n'
    '  arx_keys_failed_ = true;\n'
    '  // Each failed creation reports, as each did before: a player that retries is\n'
    '  // asking again, and the embedder may not have shown the first report (a tab\n'
    '  // in the background, another prompt showing).\n'
    '  if (arx_media_wants_keys_) {\n'
    '    arx_reported_playback_failure_ = false;\n'
    '  } else {\n'
    '    arx_reported_keys_without_media_ = false;\n'
    '  }\n'
    '  ArxReport(/*playback_failed=*/arx_media_wants_keys_);\n'
    '}\n'
    '\n'
    'void KeySystemSupportImpl::ArxRejectionUnanswered() {\n'
    '  if (arx_granted_access_) {\n'
    '    return;\n'
    '  }\n'
    '  arx_rejection_unanswered_ = true;\n'
    '  ArxReport(/*playback_failed=*/\n'
    '            base::FeatureList::IsEnabled(media::kArxWidevineAnswer) ||\n'
    '            arx_media_wants_keys_);\n'
    '}\n'
    '\n'
    'void KeySystemSupportImpl::ArxReport(bool playback_failed) {\n'
    '  if (arx_reported_playback_failure_ ||\n'
    '      (!playback_failed && arx_reported_keys_without_media_)) {\n'
    '    return;\n'
    '  }\n'
    "  // A document that isn't shown (in the back/forward cache, prerendering or\n"
    '  // being unloaded) offers nothing: the prompt would show over another page.\n'
    "  // It may report once it's shown again.\n"
    '  if (!render_frame_host().IsActive()) {\n'
    '    return;\n'
    '  }\n'
    '  if (playback_failed) {\n'
    '    arx_reported_playback_failure_ = true;\n'
    '  } else {\n'
    '    arx_reported_keys_without_media_ = true;\n'
    '  }\n'
    '  if (g_arx_protected_media_observer) {\n'
    '    g_arx_protected_media_observer(\n'
    '        &render_frame_host(),\n'
    '        playback_failed ? arx::ProtectedMediaReason::kPlaybackFailed\n'
    '                        : arx::ProtectedMediaReason::kKeysWithoutMedia);\n'
    '  }\n'
    '}\n'
    '\n')


# DEV-1211's first version counted only media in the same document.
DEV_1211_FIRST_VERSION_UPGRADES = (
    (SUPPORT_HEADER, DEV_1211_FIRST_SUPPORT_MEMBERS, SUPPORT_MEMBERS),
    (SOURCE, DEV_1211_FIRST_REPORT_REJECTED + "void KeySystemSupportImpl::SetObserver(\n",
     REPORT_REJECTED + "void KeySystemSupportImpl::SetObserver(\n"),
)

# Each step in order: a tree prepared with any earlier version reaches this one.
UPGRADES = (DEV_877_UPGRADES + DEV_1144_UPGRADES + DEV_1205_FIRST_VERSION_UPGRADES + DEV_1205_UPGRADES
            + DEV_1211_FIRST_VERSION_UPGRADES)

def upgrade_previous(source):
    """Turns an earlier version's inserted text into this version's, in a prepared tree.

    An upgrade applies where its earlier text is there once and this version's isn't yet. When
    this version only removes text, its text is part of the earlier one."""
    for relative, previous, current in UPGRADES:
        path = source / relative
        if not path.is_file():
            continue
        text = path.read_text()
        if text.count(previous) == 1 and (current in previous or current not in text):
            path.write_text(text.replace(previous, current, 1))


def apply(source):
    upgrade_previous(source)
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
