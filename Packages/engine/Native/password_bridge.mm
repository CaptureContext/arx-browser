#include "chrome/browser/arx/password_bridge.h"

#include "chrome/browser/arx/autofill_bridge.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "chrome/browser/password_manager/chrome_password_manager_client.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/autofill/autofill_client_provider.h"
#include "chrome/browser/ui/autofill/autofill_client_provider_factory.h"
#include "components/arx_inspection/developer.mojom.h"
#include "components/autofill/core/common/autofill_prefs.h"
#include "components/password_manager/content/browser/content_password_manager_driver.h"
#include "components/password_manager/content/browser/content_password_manager_driver_factory.h"
#include "components/password_manager/core/browser/actor_login/actor_login_quality_logger_interface.h"
#include "components/password_manager/core/browser/actor_login/actor_login_service_impl.h"
#include "components/password_manager/core/browser/actor_login/actor_login_types.h"
#include "components/password_manager/core/browser/actor_login/internal/actor_login_delegate_client.h"
#include "components/password_manager/core/browser/actor_login/internal/actor_login_web_content_interface.h"
#include "components/password_manager/core/browser/password_form_manager_for_ui.h"
#include "components/password_manager/core/common/password_manager_pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace arx {
namespace {
constexpr uint32_t kMinimumTimeout = 5000;
constexpr uint32_t kMaximumTimeout = 60000;
constexpr size_t kMaximumCredentials = 32;
constexpr size_t kMaximumRequests = 8;
constexpr size_t kMaximumTokenBytes = 64;
constexpr uint32_t kScriptBytes = 4096;
// A username-first form is followed through one more page at most.
constexpr int kMaximumSteps = 2;
constexpr base::TimeDelta kSettle = base::Milliseconds(1500);
constexpr base::TimeDelta kQuiet = base::Milliseconds(700);

// Runs in Arx's developer world, where Blink never returns a password,
// card or one-time-code value. It submits the form the fill went into the
// way a person would: its submit button, the form itself, a nearby sign-in
// button, or Enter in the field.
constexpr char kSubmitScript[] = R"JS(
const visible = (e) => {
  const r = e.getBoundingClientRect();
  const s = getComputedStyle(e);
  return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
};
const fields = [...document.querySelectorAll('input')].filter(visible);
const field = fields.find((e) => e.type === 'password')
  || fields.find((e) => /username|email/i.test(e.autocomplete) || e.type === 'email')
  || fields.find((e) => e.type !== 'hidden' && /user|mail|login|account|identifier/i.test(e.name + ' ' + e.id));
if (!field) return 'none';
const label = (e) => (e.innerText || e.getAttribute('value') || e.getAttribute('aria-label') || '').trim();
const form = field.form;
if (form) {
  const submit = [...form.querySelectorAll('button, input[type=submit], input[type=image]')]
    .filter(visible)
    .find((e) => e.type === 'submit' || e.type === 'image');
  if (submit) { submit.click(); return 'button'; }
  try { form.requestSubmit(); return 'form'; } catch (error) { return 'invalid'; }
}
let scope = field.parentElement;
for (let depth = 0; scope && depth < 6; depth += 1, scope = scope.parentElement) {
  const button = [...scope.querySelectorAll('button, [role=button], input[type=button]')]
    .filter(visible)
    .find((e) => /sign ?in|log ?in|continue|next|submit/i.test(label(e)));
  if (button) { button.click(); return 'button'; }
}
field.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true}));
return 'enter';
)JS";

// What the page shows after submitting: a password field (the site refused
// it or asks again) or a one-time-code field (a second step for the user).
constexpr char kProbeScript[] = R"JS(
const visible = (e) => {
  const r = e.getBoundingClientRect();
  const s = getComputedStyle(e);
  return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
};
const fields = [...document.querySelectorAll('input')].filter(visible);
const otp = fields.some((e) => /one-time-code/i.test(e.autocomplete)
  || /otp|totp|2fa|mfa|one.?time|verification.?code|security.?code|passcode/i
    .test(e.name + ' ' + e.id + ' ' + (e.placeholder || '')));
return {password: fields.some((e) => e.type === 'password'), otp};
)JS";

class NoopQualityLogger final : public actor_login::ActorLoginQualityLoggerInterface {
 public:
  void SetDomainAndLanguage(translate::TranslateManager*, const GURL&) override {}
  void SetGetCredentialsDetails(
      optimization_guide::proto::ActorLoginQuality_GetCredentialsDetails) override {}
  void SetFederatedGetCredentialsDetails(
      optimization_guide::proto::ActorLoginQuality_FederatedGetCredentialsDetails) override {}
  void AddAttemptLoginDetails(
      optimization_guide::proto::ActorLoginQuality_AttemptLoginDetails) override {}
  void SetPermissionPicked(
      optimization_guide::proto::ActorLoginQuality_PermissionOption) override {}

 private:
  ~NoopQualityLogger() override = default;
};

scoped_refptr<actor_login::ActorLoginQualityLoggerInterface> Logger() {
  return base::MakeRefCounted<NoopQualityLogger>();
}

actor_login::ActorLoginService& Service() {
  static base::NoDestructor<actor_login::ActorLoginServiceImpl> service;
  return *service;
}

struct Offer {
  uint64_t token = 0;
  std::unique_ptr<password_manager::PasswordFormManagerForUI> form;
  bool update = false;
};

// One credential list per page, bound to the main frame's document it was
// read for.
struct Listing {
  content::WeakDocumentPtr document;
  std::string token;
  std::vector<actor_login::Credential> credentials;
  // Every frame's document when listed, by frame ID: a frame that navigated
  // since, even keeping its ID, is stale.
  std::map<std::string, content::WeakDocumentPtr> frames;
};

class SignIn;

struct Registry {
  PasswordSaveOffered offered = nullptr;
  SignInReply reply = nullptr;
  std::map<uint64_t, base::WeakPtr<content::WebContents>> pages;
  std::map<uint64_t, Offer> offers;
  uint64_t next_token = 1;
  std::map<uint64_t, Listing> listings;
  // Pending credential reads, by request, with their page.
  std::map<uint64_t, uint64_t> reads;
  std::map<uint64_t, std::unique_ptr<SignIn>> sign_ins;
};

Registry& Passwords() {
  static base::NoDestructor<Registry> registry;
  return *registry;
}

std::string Write(const base::Value& value) {
  std::string json;
  base::JSONWriter::Write(value, &json);
  return json;
}

void ReplyLater(uint64_t request, uint64_t page, ArxSignInStatus status,
                std::string json = std::string()) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
      [](uint64_t request, uint64_t page, ArxSignInStatus status, std::string json) {
        auto reply = Passwords().reply;
        if (!reply) return;
        reply(request, page, status,
              json.empty() ? nullptr : reinterpret_cast<const uint8_t*>(json.data()), json.size());
      }, request, page, status, std::move(json)));
}

std::optional<uint64_t> PageOf(content::WebContents* contents) {
  for (const auto& [page, weak] : Passwords().pages)
    if (weak.get() == contents) return page;
  return std::nullopt;
}

bool Ordinary(content::WebContents* contents) {
  return contents && !contents->IsBeingDestroyed() && !contents->IsCrashed() &&
      !contents->GetBrowserContext()->IsOffTheRecord();
}

bool Ready(content::RenderFrameHost* frame) {
  return frame && frame->IsRenderFrameLive() && !frame->IsErrorDocument() &&
      frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS();
}

// An exact origin: the credential was saved for this scheme, host and port.
bool ExactMatch(const actor_login::Credential& credential, const url::Origin& origin) {
  return credential.type == actor_login::kPassword &&
      url::Origin::Create(GURL(credential.signon_realm)).IsSameOriginWith(origin) &&
      credential.request_origin.IsSameOriginWith(origin);
}

// Arx's own ActorLoginDelegateClient: no Chrome tab, Glic or actor task. An
// Arx page is in focus for reauthentication only when the user is filling,
// never for an agent, so a required reauthentication becomes "needs the user".
class ArxActorLoginClient final
    : public actor_login::ActorLoginDelegateClient,
      public content::WebContentsObserver,
      public content::WebContentsUserData<ArxActorLoginClient> {
 public:
  ~ArxActorLoginClient() override = default;

  void SetActorLoginWebContentInterface(
      actor_login::ActorLoginWebContentInterface* web_interface) override {
    web_interface_ = web_interface;
  }
  PrefService* GetPrefs() override {
    return Profile::FromBrowserContext(GetWebContents().GetBrowserContext())->GetPrefs();
  }
  password_manager::PasswordManagerClient* GetPasswordManagerClient() override {
    auto* factory =
        password_manager::ContentPasswordManagerDriverFactory::FromWebContents(&GetWebContents());
    return factory ? factory->password_client() : nullptr;
  }
  password_manager::PasswordManagerDriver* GetPasswordManagerDriverForMainFrame() override {
    auto* frame = GetWebContents().GetPrimaryMainFrame();
    return frame ? password_manager::ContentPasswordManagerDriver::GetForRenderFrameHost(frame)
                 : nullptr;
  }
  ukm::SourceId GetPageUkmSourceIdForMainFrame() override {
    return GetWebContents().GetPrimaryMainFrame()->GetPageUkmSourceId();
  }
  url::Origin GetLastCommittedOriginForMainFrame() override {
    return GetWebContents().GetPrimaryMainFrame()->GetLastCommittedOrigin();
  }
  translate::TranslateManager* GetTranslateManager() override { return nullptr; }
  // Arx never stores agent permissions in Chromium, so there are none to clean.
  actor_login::ActorLoginPermissionCleaningService* GetPermissionCleaningService() override {
    return nullptr;
  }
  std::unique_ptr<actor_login::ActorLoginCredentialsFetcher> CreateFederatedCredentialsFetcher(
      scoped_refptr<actor_login::ActorLoginQualityLoggerInterface>,
      actor_login::ActorLoginMetricsHelper*) override {
    return nullptr;
  }
  std::unique_ptr<actor_login::ActorLoginSiwgControllerInterface> CreateSiwgController(
      const actor_login::Credential&, bool, actor_login::LoginStatusResultOrErrorReply,
      base::WeakPtr<actor_login::ActionSequenceDelegate>,
      scoped_refptr<actor_login::ActorLoginQualityLoggerInterface>, base::TimeTicks,
      base::OnceCallback<void(bool)>) override {
    return nullptr;
  }
  bool IsTaskInFocus() override { return false; }
  bool SupportsFedCmEmbedderInitiatedLogin() override { return false; }
  void RemoveFederatedEmbedderLoginRequest() override {}
  void ObserveControlStateForCurrentTask(base::OnceClosure) override {}
  base::WeakPtr<actor_login::ActorLoginDelegateClient> AsWeakPtr() override {
    return weak_.GetWeakPtr();
  }

  void PrimaryPageChanged(content::Page&) override {
    if (web_interface_) web_interface_->OnPrimaryPageChanged();
    // DEV-943: a listing and a pending read belong to one visit of a document.
    // A document restored from the back/forward cache is the same document, so
    // its old listing would match it again; end them when it is left instead.
    auto page = PageOf(web_contents());
    if (!page) return;
    auto& passwords = Passwords();
    passwords.listings.erase(*page);
    for (auto it = passwords.reads.begin(); it != passwords.reads.end();) {
      if (it->second != *page) { ++it; continue; }
      ReplyLater(it->first, *page, ARX_SIGN_IN_STALE);
      it = passwords.reads.erase(it);
    }
  }
  void WebContentsDestroyed() override {
    if (web_interface_) web_interface_->OnContextDestroyed();
    web_interface_ = nullptr;
  }

 private:
  friend class content::WebContentsUserData<ArxActorLoginClient>;

  explicit ArxActorLoginClient(content::WebContents* contents)
      : content::WebContentsObserver(contents),
        content::WebContentsUserData<ArxActorLoginClient>(*contents) {}

  raw_ptr<actor_login::ActorLoginWebContentInterface> web_interface_ = nullptr;
  base::WeakPtrFactory<ArxActorLoginClient> weak_{this};

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(ArxActorLoginClient);

const char* ErrorReason(actor_login::ActorLoginError error) {
  switch (error) {
    case actor_login::ActorLoginError::kServiceBusy: return "busy";
    case actor_login::ActorLoginError::kFillingNotAllowed: return "notAllowed";
    case actor_login::ActorLoginError::kInvalidTabInterface:
    case actor_login::ActorLoginError::kFeatureDisabled: return "unavailable";
  }
  return "unavailable";
}

ArxSignInStatus ErrorStatus(actor_login::ActorLoginError error) {
  switch (error) {
    case actor_login::ActorLoginError::kServiceBusy: return ARX_SIGN_IN_BUSY;
    case actor_login::ActorLoginError::kFillingNotAllowed: return ARX_SIGN_IN_FAILED;
    case actor_login::ActorLoginError::kInvalidTabInterface:
    case actor_login::ActorLoginError::kFeatureDisabled: return ARX_SIGN_IN_UNAVAILABLE;
  }
  return ARX_SIGN_IN_UNAVAILABLE;
}

// The JSON value a fixed script returned, or none.
std::optional<base::Value> ScriptValue(arx::developer::mojom::ScriptStatus status,
                                       const std::string& result) {
  if (status != arx::developer::mojom::ScriptStatus::kOK) return std::nullopt;
  auto parsed = base::JSONReader::Read(result, base::JSON_PARSE_RFC);
  const auto* dict = parsed ? parsed->GetIfDict() : nullptr;
  const auto* type = dict ? dict->FindString("type") : nullptr;
  const auto* text = dict ? dict->FindString("value") : nullptr;
  if (!type || *type != "json" || !text) return std::nullopt;
  return base::JSONReader::Read(*text, base::JSON_PARSE_RFC);
}

// One agent sign-in: fill through actor_login into the bound frame of the
// bound document, submit, then read what the page shows. A change of the
// bound document or frame before submitting cancels it.
class SignIn final : public content::WebContentsObserver {
 public:
  SignIn(content::WebContents* contents, uint64_t page, uint64_t request,
         content::RenderFrameHost* frame, actor_login::Credential credential, uint32_t timeout_ms)
      : WebContentsObserver(contents), page_(page), request_(request),
        credential_(std::move(credential)) {
    Bind(frame);
    timeout_.Start(FROM_HERE, base::Milliseconds(timeout_ms),
                   base::BindOnce(&SignIn::Finish, weak_.GetWeakPtr(), ARX_SIGN_IN_TIMEOUT,
                                  "timeout"));
  }

  uint64_t page() const { return page_; }

  void Start() {
    auto* client = ArxActorLoginClient::FromWebContents(web_contents());
    if (!client) return Finish(ARX_SIGN_IN_UNAVAILABLE, "unavailable");
    phase_ = Phase::kFilling;
    filled_frames_.clear();
    Service().AttemptLogin(
        client, credential_, /*should_store_permission=*/false, Logger(), base::TimeTicks::Now(),
        base::BindOnce(&SignIn::FillingStarted, weak_.GetWeakPtr()),
        base::BindOnce(&SignIn::Filled, weak_.GetWeakPtr()), nullptr);
  }

  void Finish(ArxSignInStatus status, const char* reason) {
    if (phase_ == Phase::kDone) return;
    phase_ = Phase::kDone;
    timeout_.Stop();
    settle_.Stop();
    runner_.reset();
    base::DictValue body;
    body.Set("reason", reason);
    body.Set("filled", filled_);
    body.Set("passwordVisible", password_visible_);
    ReplyLater(request_, page_, status, Write(base::Value(std::move(body))));
    Drain();
  }

  // content::WebContentsObserver:
  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsSameDocument() || phase_ == Phase::kDone) return;
    const bool bound = navigation->GetFrameTreeNodeId() == frame_node_;
    if (phase_ == Phase::kFilling && (bound || navigation->IsInPrimaryMainFrame()))
      return Finish(ARX_SIGN_IN_STALE, "navigation");
  }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (!navigation->HasCommitted() || navigation->IsSameDocument() ||
        !navigation->IsInPrimaryMainFrame()) return;
    // Waiting for the next step's credentials: a replaced document ends it, even
    // one that later comes back from the back/forward cache (DEV-943).
    if (phase_ == Phase::kWaiting) return Finish(ARX_SIGN_IN_STALE, "navigation");
    if (phase_ != Phase::kSubmitting && phase_ != Phase::kSettling &&
        phase_ != Phase::kProbing) return;
    navigated_ = true;
    // A probe of the old document is moot; read the new one once it settles.
    if (phase_ != Phase::kSubmitting) Settle();
  }
  void DidStopLoading() override {
    if (phase_ == Phase::kSettling && !settle_.IsRunning())
      settle_.Start(FROM_HERE, kQuiet, base::BindOnce(&SignIn::Settled, weak_.GetWeakPtr()));
  }
  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    if (phase_ == Phase::kFilling && frame == frame_.AsRenderFrameHostIfValid())
      Finish(ARX_SIGN_IN_STALE, "frame");
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    Finish(ARX_SIGN_IN_STALE, "navigation");
  }
  void WebContentsDestroyed() override { Finish(ARX_SIGN_IN_STALE, "navigation"); }

 private:
  enum class Phase { kWaiting, kFilling, kSubmitting, kSettling, kProbing, kDone };

  void Bind(content::RenderFrameHost* frame) {
    frame_ = frame->GetWeakDocumentPtr();
    frame_node_ = frame->GetFrameTreeNodeId();
    main_ = web_contents()->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    origin_ = web_contents()->GetPrimaryMainFrame()->GetLastCommittedOrigin();
  }

  bool BoundIsCurrent() const {
    auto* frame = frame_.AsRenderFrameHostIfValid();
    auto* main = main_.AsRenderFrameHostIfValid();
    return frame && main && web_contents() && web_contents()->GetPrimaryMainFrame() == main &&
        frame->IsActive() && frame->IsRenderFrameLive() &&
        main->GetLastCommittedOrigin().IsSameOriginWith(origin_);
  }

  void FillingStarted(base::span<const int> frames) {
    for (int frame : frames) filled_frames_.insert(frame);
    if (!frames.empty()) filled_ = true;
  }

  void Filled(actor_login::LoginStatusResultOrError result) {
    if (phase_ != Phase::kFilling) return;
    if (!result.has_value()) return Finish(ErrorStatus(result.error()), ErrorReason(result.error()));
    using actor_login::LoginStatusResult;
    switch (result.value()) {
      case LoginStatusResult::kSuccessUsernameAndPasswordFilled:
      case LoginStatusResult::kSuccessPasswordFilled:
        username_only_ = false;
        break;
      case LoginStatusResult::kSuccessUsernameFilled:
        username_only_ = true;
        break;
      case LoginStatusResult::kErrorDeviceReauthRequired:
      case LoginStatusResult::kErrorDeviceReauthFailed:
        return Finish(ARX_SIGN_IN_NEEDS_USER, "reauthentication");
      case LoginStatusResult::kErrorPageChangedDuringFilling:
        return Finish(ARX_SIGN_IN_STALE, "navigation");
      case LoginStatusResult::kErrorInvalidCredential:
        return Finish(ARX_SIGN_IN_FAILED, "credential");
      case LoginStatusResult::kErrorNoSigninForm:
      case LoginStatusResult::kErrorNoFillableFields:
        return Finish(ARX_SIGN_IN_FAILED, "noForm");
      default:
        return Finish(ARX_SIGN_IN_FAILED, "unsupported");
    }
    if (!filled_frames_.contains(frame_node_.value())) return Finish(ARX_SIGN_IN_FAILED, "frame");
    if (!BoundIsCurrent()) return Finish(ARX_SIGN_IN_STALE, "navigation");
    password_visible_ = true;
    Submit();
  }

  void Submit() {
    phase_ = Phase::kSubmitting;
    auto* frame = frame_.AsRenderFrameHostIfValid();
    if (!frame) return Finish(ARX_SIGN_IN_STALE, "frame");
    Run(frame, kSubmitScript, base::BindOnce(&SignIn::Submitted, weak_.GetWeakPtr()));
  }

  void Submitted(arx::developer::mojom::ScriptStatus status, const std::string& result) {
    if (phase_ != Phase::kSubmitting) return;
    auto value = ScriptValue(status, result);
    const auto* how = value ? value->GetIfString() : nullptr;
    if (!how) return Finish(ARX_SIGN_IN_FAILED, "submit");
    if (*how == "none" || *how == "invalid") return Finish(ARX_SIGN_IN_FAILED, "submit");
    Settle();
  }

  void Settle() {
    runner_.reset();
    phase_ = Phase::kSettling;
    settle_.Start(FROM_HERE, kSettle, base::BindOnce(&SignIn::Settled, weak_.GetWeakPtr()));
  }

  void Settled() {
    if (phase_ != Phase::kSettling) return;
    // DidStopLoading restarts the quiet wait once the page stops loading.
    if (web_contents()->IsLoading()) return;
    phase_ = Phase::kProbing;
    auto* main = web_contents()->GetPrimaryMainFrame();
    if (!Ready(main)) return Finish(ARX_SIGN_IN_FAILED, "navigation");
    Run(main, kProbeScript, base::BindOnce(&SignIn::Probed, weak_.GetWeakPtr()));
  }

  void Probed(arx::developer::mojom::ScriptStatus status, const std::string& result) {
    if (phase_ != Phase::kProbing) return;
    auto value = ScriptValue(status, result);
    const auto* dict = value ? value->GetIfDict() : nullptr;
    if (!dict) return Finish(ARX_SIGN_IN_FAILED, "unknown");
    const bool password = dict->FindBool("password").value_or(true);
    const bool otp = dict->FindBool("otp").value_or(false);
    password_visible_ = password;
    if (otp) return Finish(ARX_SIGN_IN_NEEDS_USER, "twoFactor");
    if (!password) return Finish(ARX_SIGN_IN_SIGNED_IN, "signedIn");
    auto* main = web_contents()->GetPrimaryMainFrame();
    if (username_only_ && navigated_ && ++steps_ < kMaximumSteps &&
        main->GetLastCommittedOrigin().IsSameOriginWith(origin_)) {
      return Continue();
    }
    Finish(ARX_SIGN_IN_FAILED, "rejected");
  }

  // A username-first site's password page: the same account, once more.
  void Continue() {
    auto* client = ArxActorLoginClient::FromWebContents(web_contents());
    if (!client) return Finish(ARX_SIGN_IN_UNAVAILABLE, "unavailable");
    phase_ = Phase::kWaiting;
    Bind(web_contents()->GetPrimaryMainFrame());
    Service().GetCredentials(client, false, Logger(),
                             base::BindOnce(&SignIn::Relisted, weak_.GetWeakPtr()));
  }

  void Relisted(actor_login::CredentialsOrError result) {
    if (phase_ != Phase::kWaiting) return;
    if (!result.has_value()) return Finish(ErrorStatus(result.error()), ErrorReason(result.error()));
    if (!BoundIsCurrent()) return Finish(ARX_SIGN_IN_STALE, "navigation");
    for (const auto& credential : result.value()) {
      if (ExactMatch(credential, origin_) && credential.username == credential_.username &&
          credential.signon_realm == credential_.signon_realm) {
        credential_ = credential;
        return Start();
      }
    }
    Finish(ARX_SIGN_IN_FAILED, "credential");
  }

  void Run(content::RenderFrameHost* frame, const char* script,
           base::OnceCallback<void(arx::developer::mojom::ScriptStatus, const std::string&)> done) {
    runner_.reset();
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&runner_);
    runner_.set_disconnect_handler(base::BindOnce(&SignIn::Disconnected, weak_.GetWeakPtr()));
    runner_->Evaluate(script, kScriptBytes, std::move(done));
  }

  // The submit or the page itself navigated away from the script's document.
  void Disconnected() {
    if (phase_ == Phase::kSubmitting || phase_ == Phase::kProbing) {
      navigated_ |= phase_ == Phase::kSubmitting;
      return Settle();
    }
    Finish(ARX_SIGN_IN_STALE, "navigation");
  }

  void Drain() {
    // The owner's address only, never followed: this can run twice, and a pointer bound into
    // the task would dangle once the first run erases the owner.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](uint64_t request, uintptr_t owner) {
          auto& sign_ins = Passwords().sign_ins;
          auto found = sign_ins.find(request);
          if (found != sign_ins.end() && reinterpret_cast<uintptr_t>(found->second.get()) == owner)
            sign_ins.erase(found);
        }, request_, reinterpret_cast<uintptr_t>(this)));
  }

  const uint64_t page_, request_;
  actor_login::Credential credential_;
  content::WeakDocumentPtr frame_, main_;
  content::FrameTreeNodeId frame_node_;
  url::Origin origin_;
  Phase phase_ = Phase::kWaiting;
  std::set<int> filled_frames_;
  bool filled_ = false;
  bool password_visible_ = false;
  bool username_only_ = false;
  bool navigated_ = false;
  int steps_ = 0;
  mojo::AssociatedRemote<arx::developer::mojom::ScriptRunner> runner_;
  base::OneShotTimer timeout_, settle_;
  base::WeakPtrFactory<SignIn> weak_{this};
};

// The save or update offer for a page's submitted form. Arx has no Chrome
// bubble; the app shows its own sheet and answers with the token.
bool OfferSave(content::WebContents* contents,
               std::unique_ptr<password_manager::PasswordFormManagerForUI> form, bool update) {
  auto& passwords = Passwords();
  const auto page = PageOf(contents);
  if (!page || !passwords.offered || !form || form->IsBlocklisted() || !Ordinary(contents) ||
      !form->GetURL().SchemeIsHTTPOrHTTPS()) return false;
  auto& offer = passwords.offers[*page];
  if (offer.form) offer.form->OnNoInteraction(offer.update);
  offer.token = passwords.next_token++;
  offer.update = update;
  const std::string origin = url::Origin::Create(form->GetURL()).Serialize();
  const std::string username = base::UTF16ToUTF8(form->GetPendingCredentials().username_value);
  offer.form = std::move(form);
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
      [](uint64_t page, uint64_t token, std::string origin, std::string username, bool update) {
        auto& passwords = Passwords();
        auto found = passwords.offers.find(page);
        if (!passwords.offered || found == passwords.offers.end() || found->second.token != token)
          return;
        passwords.offered(page, token, origin.c_str(), username.c_str(), update);
      }, *page, offer.token, origin, username, update));
  return true;
}

void SetPreference(PrefService* prefs, const char* name, bool value) {
  if (prefs->GetBoolean(name) != value) prefs->SetBoolean(name, value);
}
}  // namespace

void StartPasswords(PasswordSaveOffered offered, SignInReply reply) {
  auto& passwords = Passwords();
  passwords.offered = offered;
  passwords.reply = reply;
  ChromePasswordManagerClient::SetEmbedderSavePrompt(base::BindRepeating(&OfferSave));
}

void StopPasswords() {
  ChromePasswordManagerClient::SetEmbedderSavePrompt({});
  auto& passwords = Passwords();
  for (auto& [request, sign_in] : passwords.sign_ins) sign_in->Finish(ARX_SIGN_IN_UNAVAILABLE, "unavailable");
  passwords.sign_ins.clear();
  for (auto& [page, offer] : passwords.offers)
    if (offer.form) offer.form->OnNoInteraction(offer.update);
  passwords.offers.clear();
  passwords.listings.clear();
  passwords.reads.clear();
  passwords.pages.clear();
  passwords.offered = nullptr;
  passwords.reply = nullptr;
}

void AttachPasswordClients(content::WebContents* contents, uint64_t page) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!Ordinary(contents)) return;
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  PrefService* prefs = profile->GetPrefs();
  // Passwords on, automatic sign-in off; addresses and cards follow Settings
  // (DEV-893), on unless the user turned them off.
  SetPreference(prefs, password_manager::prefs::kCredentialsEnableService, true);
  SetPreference(prefs, password_manager::prefs::kCredentialsEnableAutosignin, false);
  ApplyAutofillProducts(prefs);
  // Arx asks the device owner itself before a fill (DEV-875), once.
  SetPreference(prefs, password_manager::prefs::kBiometricAuthenticationBeforeFilling, false);
  auto& provider = autofill::AutofillClientProviderFactory::GetForProfile(profile);
  provider.CreateClientForWebContents(contents);
  if (provider.uses_platform_autofill()) return;
  ChromePasswordManagerClient::CreateForWebContents(contents);
  ArxActorLoginClient::CreateForWebContents(contents);
  Passwords().pages[page] = contents->GetWeakPtr();
  AttachAutofillPage(contents, page);
}

void ForgetPasswordPage(uint64_t page) {
  ForgetAutofillPage(page);
  auto& passwords = Passwords();
  passwords.pages.erase(page);
  passwords.listings.erase(page);
  if (auto found = passwords.offers.find(page); found != passwords.offers.end()) {
    if (found->second.form) found->second.form->OnNoInteraction(found->second.update);
    passwords.offers.erase(found);
  }
  for (auto it = passwords.reads.begin(); it != passwords.reads.end();) {
    if (it->second == page) {
      ReplyLater(it->first, page, ARX_SIGN_IN_STALE);
      it = passwords.reads.erase(it);
    } else {
      ++it;
    }
  }
  for (auto it = passwords.sign_ins.begin(); it != passwords.sign_ins.end();) {
    if (it->second->page() == page) {
      it->second->Finish(ARX_SIGN_IN_STALE, "navigation");
      it = passwords.sign_ins.erase(it);
    } else {
      ++it;
    }
  }
}

bool AnswerPasswordSave(uint64_t page, uint64_t token, ArxPasswordSaveAnswer answer) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& offers = Passwords().offers;
  auto found = offers.find(page);
  if (found == offers.end() || found->second.token != token || !found->second.form) return false;
  auto offer = std::move(found->second);
  offers.erase(found);
  switch (answer) {
    case ARX_PASSWORD_SAVE:
      offer.form->Save();
      return true;
    case ARX_PASSWORD_NEVER:
      if (offer.update) offer.form->OnNopeUpdateClicked();
      else offer.form->OnNeverClicked();
      return true;
    case ARX_PASSWORD_NOT_NOW:
      offer.form->OnNoInteraction(offer.update);
      return true;
  }
  offer.form->OnNoInteraction(offer.update);
  return false;
}

void RequestSignInCredentials(content::WebContents* contents, uint64_t page, uint64_t request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& passwords = Passwords();
  if (!request || passwords.reads.contains(request) || passwords.sign_ins.contains(request))
    return ReplyLater(request, page, ARX_SIGN_IN_INVALID);
  if (!Ordinary(contents)) return ReplyLater(request, page, ARX_SIGN_IN_UNAVAILABLE);
  auto* client = ArxActorLoginClient::FromWebContents(contents);
  auto* main = contents->GetPrimaryMainFrame();
  if (!client || !passwords.pages.contains(page)) return ReplyLater(request, page, ARX_SIGN_IN_UNAVAILABLE);
  if (!Ready(main)) return ReplyLater(request, page, ARX_SIGN_IN_UNAVAILABLE);
  const bool busy = std::any_of(passwords.reads.begin(), passwords.reads.end(),
                                [page](const auto& item) { return item.second == page; }) ||
      std::any_of(passwords.sign_ins.begin(), passwords.sign_ins.end(),
                  [page](const auto& item) { return item.second->page() == page; });
  if (busy || passwords.reads.size() + passwords.sign_ins.size() >= kMaximumRequests)
    return ReplyLater(request, page, ARX_SIGN_IN_BUSY);
  passwords.reads[request] = page;
  Service().GetCredentials(client, false, Logger(), base::BindOnce(
      [](uint64_t request, uint64_t page, content::WeakDocumentPtr document,
         actor_login::CredentialsOrError result) {
        auto& passwords = Passwords();
        if (!passwords.reads.erase(request)) return;
        if (!result.has_value())
          return ReplyLater(request, page, ErrorStatus(result.error()));
        auto* frame = document.AsRenderFrameHostIfValid();
        auto found = passwords.pages.find(page);
        auto* contents = found == passwords.pages.end() ? nullptr : found->second.get();
        if (!frame || !contents || contents->GetPrimaryMainFrame() != frame)
          return ReplyLater(request, page, ARX_SIGN_IN_STALE);
        const url::Origin origin = frame->GetLastCommittedOrigin();
        Listing listing{document, base::UnguessableToken::Create().ToString(), {}, {}};
        frame->ForEachRenderFrameHost([&](content::RenderFrameHost* host) {
          if (&host->GetPage() == &frame->GetPage())
            listing.frames[host->GetFrameToken().ToString()] = host->GetWeakDocumentPtr();
        });
        base::ListValue credentials;
        for (const auto& credential : result.value()) {
          if (!ExactMatch(credential, origin) || listing.credentials.size() >= kMaximumCredentials)
            continue;
          base::DictValue item;
          item.Set("id", credential.id.value());
          item.Set("username", base::UTF16ToUTF8(credential.username));
          item.Set("form", credential.immediatelyAvailableToLogin);
          credentials.Append(std::move(item));
          listing.credentials.push_back(credential);
        }
        base::DictValue body;
        body.Set("document", listing.token);
        body.Set("origin", origin.Serialize());
        body.Set("credentials", std::move(credentials));
        passwords.listings[page] = std::move(listing);
        ReplyLater(request, page, ARX_SIGN_IN_OK, Write(base::Value(std::move(body))));
      }, request, page, main->GetWeakDocumentPtr()));
}

void AttemptSignIn(content::WebContents* contents, uint64_t page, uint64_t request,
                   const char* document, const char* frame, uint32_t credential,
                   uint32_t timeout_ms) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& passwords = Passwords();
  const size_t document_length = document ? strnlen(document, kMaximumTokenBytes + 1) : 0;
  const size_t frame_length = frame ? strnlen(frame, kMaximumTokenBytes + 1) : 0;
  if (!request || passwords.reads.contains(request) || passwords.sign_ins.contains(request) ||
      !document_length || document_length > kMaximumTokenBytes ||
      frame_length > kMaximumTokenBytes || timeout_ms < kMinimumTimeout ||
      timeout_ms > kMaximumTimeout)
    return ReplyLater(request, page, ARX_SIGN_IN_INVALID);
  if (!Ordinary(contents) || !ArxActorLoginClient::FromWebContents(contents))
    return ReplyLater(request, page, ARX_SIGN_IN_UNAVAILABLE);
  const bool busy = std::any_of(passwords.reads.begin(), passwords.reads.end(),
                                [page](const auto& item) { return item.second == page; }) ||
      std::any_of(passwords.sign_ins.begin(), passwords.sign_ins.end(),
                  [page](const auto& item) { return item.second->page() == page; });
  if (busy || passwords.reads.size() + passwords.sign_ins.size() >= kMaximumRequests)
    return ReplyLater(request, page, ARX_SIGN_IN_BUSY);

  // The listing's document must still be the page's main frame document.
  auto listing = passwords.listings.find(page);
  auto* main = contents->GetPrimaryMainFrame();
  if (listing == passwords.listings.end() ||
      listing->second.token != std::string(document, document_length) ||
      listing->second.document.AsRenderFrameHostIfValid() != main || !Ready(main))
    return ReplyLater(request, page, ARX_SIGN_IN_STALE);

  content::RenderFrameHost* bound = main;
  if (frame_length) {
    const std::string token(frame, frame_length);
    bound = nullptr;
    main->ForEachRenderFrameHost([&](content::RenderFrameHost* host) {
      if (!bound && host->GetFrameToken().ToString() == token) bound = host;
    });
    auto listed = listing->second.frames.find(token);
    if (!bound || bound->IsFencedFrameRoot() || bound->IsNestedWithinFencedFrame() ||
        !bound->IsActive() || !Ready(bound) || &bound->GetPage() != &main->GetPage() ||
        listed == listing->second.frames.end() ||
        listed->second.AsRenderFrameHostIfValid() != bound)
      return ReplyLater(request, page, ARX_SIGN_IN_STALE);
  }

  const auto& credentials = listing->second.credentials;
  auto chosen = std::find_if(credentials.begin(), credentials.end(),
      [credential](const auto& item) { return item.id.value() == static_cast<int32_t>(credential); });
  if (chosen == credentials.end() || !ExactMatch(*chosen, main->GetLastCommittedOrigin()))
    return ReplyLater(request, page, ARX_SIGN_IN_INVALID);

  auto& owned = passwords.sign_ins[request];
  owned = std::make_unique<SignIn>(contents, page, request, bound, *chosen, timeout_ms);
  owned->Start();
}

void CancelSignIn(uint64_t request) {
  auto& passwords = Passwords();
  if (auto read = passwords.reads.find(request); read != passwords.reads.end()) {
    ReplyLater(request, read->second, ARX_SIGN_IN_CANCELLED);
    passwords.reads.erase(read);
    return;
  }
  auto found = passwords.sign_ins.find(request);
  if (found == passwords.sign_ins.end()) return;
  found->second->Finish(ARX_SIGN_IN_CANCELLED, "cancelled");
  passwords.sign_ins.erase(found);
}
}  // namespace arx
