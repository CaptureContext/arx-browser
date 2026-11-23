#include <cassert>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <tuple>
#include <utility>
#include <vector>
#include "external_handoff_authority.h"
#define CHECK(condition) assert(condition)
using arx::ExternalHandoffAuthority;
namespace base {
template<class Signature> struct RepeatingCallback;
template<class R> struct RepeatingCallback<R()> {
  std::function<R()> function;
  RepeatingCallback() = default;
  template<class F> RepeatingCallback(F value) : function(std::move(value)) {}
  explicit operator bool() const { return bool(function); }
  R Run() const { return function(); }
};
struct OnceClosure {
  std::function<void()> function;
  OnceClosure() = default;
  template<class F> OnceClosure(F value) : function(std::move(value)) {}
  explicit operator bool() const { return bool(function); }
  void Run() { auto action = std::exchange(function, {}); if (action) action(); }
};
template<class F, class... A> auto BindRepeating(F function, A... args) {
  return [function, args = std::make_tuple(args...)]() mutable { return std::apply(function, args); };
}
template<class F, class... A> auto BindOnce(F function, A... args) {
  return BindRepeating(function, args...);
}
template<class T> struct WeakPtr {
  T* value;
  std::weak_ptr<int> lifetime;
  explicit operator bool() const { return value && !lifetime.expired(); }
  T* operator->() const { assert(*this); return value; }
  T* get() const { return *this ? value : nullptr; }
};
struct TimeTicks {
  int value = 0;
  static int now;
  static TimeTicks Now() { return {now}; }
  TimeTicks operator+(int seconds) { return {value + seconds}; }
  bool operator>=(TimeTicks other) const { return value >= other.value; }
};
int TimeTicks::now = 0;
int Seconds(int seconds) { return seconds; }
}
using Guard = base::RepeatingCallback<bool()>;
struct Profile {
  bool private_profile = false;
  bool IsOffTheRecord() { return private_profile; }
  static Profile* FromBrowserContext(Profile* profile) { return profile; }
};
struct GURL {
  std::string value;
  GURL() = default;
  explicit GURL(const char* input) : value(input) {}
  bool operator==(const GURL& other) const { return value == other.value; }
  bool is_empty() const { return value.empty(); }
};
namespace url { constexpr char kAboutBlankURL[] = "about:blank"; }
namespace content {
struct WebContents;
struct GlobalRenderFrameHostToken { int process, token; };
struct RenderFrameHost;
struct WeakDocumentPtr {
  RenderFrameHost* frame = nullptr;
  std::weak_ptr<int> lifetime;
  RenderFrameHost* AsRenderFrameHostIfValid() const { return lifetime.expired() ? nullptr : frame; }
};
struct RenderFrameHost {
  static std::map<std::pair<int,int>, RenderFrameHost*> registry;
  WebContents* owner;
  std::shared_ptr<int> document = std::make_shared<int>(0);
  bool active = true;
  WeakDocumentPtr GetWeakDocumentPtr() { return {this, document}; }
  static RenderFrameHost* FromFrameToken(GlobalRenderFrameHostToken token) {
    return registry[{token.process, token.token}];
  }
};
std::map<std::pair<int,int>, RenderFrameHost*> RenderFrameHost::registry;
struct Controller {
  bool pending = false;
  void* GetPendingEntry() { return pending ? this : nullptr; }
};
struct WebContents {
  Profile* profile;
  RenderFrameHost frame{this};
  std::shared_ptr<int> lifetime = std::make_shared<int>(0);
  Controller controller;
  GURL url{"about:blank"};
  bool visible = true, attached = true;
  int attachment = 1;
  void* consent_host = nullptr;
  explicit WebContents(Profile* value) : profile(value) {}
  base::WeakPtr<WebContents> GetWeakPtr() { return {this, lifetime}; }
  RenderFrameHost* GetPrimaryMainFrame() { return &frame; }
  Profile* GetBrowserContext() { return profile; }
  const GURL& GetLastCommittedURL() { return url; }
  Controller& GetController() { return controller; }
};
struct NavigationHandle {
  int64_t identifier = 1;
  bool primary = true, same = false, renderer = true, committed = false;
  bool is_synchronous_renderer_commit_ = false, initial_empty = false, error = false;
  RenderFrameHost* committing_frame = nullptr;
  std::optional<int> token = 10;
  GURL url{"owned:cancel"};
  const std::optional<int>& GetInitiatorFrameToken() { return token; }
  int GetInitiatorProcessId() { return 5; }
  bool IsRendererInitiated() { return renderer; }
  int64_t GetNavigationId() { return identifier; }
  bool IsInPrimaryMainFrame() { return primary; }
  bool IsSameDocument() { return same; }
  bool HasCommitted() { return committed; }
  bool IsErrorPage() { return error; }
  bool IsNavigatingFromInitialEmptyDocument() { return initial_empty; }
  RenderFrameHost* GetRenderFrameHost() { return committing_frame; }
  // PRODUCTION_BOOTSTRAP_QUERY
  const GURL& GetURL() { return url; }
};
}
bool LiveSource(content::WebContents* contents, const content::WeakDocumentPtr& document) {
  auto* frame = document.AsRenderFrameHostIfValid();
  return frame && frame->active && frame->owner == contents;
}
bool IsPageExternalTarget(content::WebContents*, const GURL& target) {
  return target.value == "owned:cancel";
}
struct SourceHost {
  content::WebContents* contents;
  int attachment;
  explicit SourceHost(content::WebContents* value) : contents(value), attachment(value->attachment) {}
  bool SameAttachment(content::WebContents* value) const {
    return contents == value && value->attached && attachment == value->attachment;
  }
  bool Visible(content::WebContents* value) const { return SameAttachment(value) && value->visible; }
};
struct MediaWork {
  static int physical;
  static bool refuse;
  std::unique_ptr<int> keep_alive;
  static Profile* owner;
  explicit MediaWork(Profile* profile) {
    owner = profile;
    if (!refuse) { keep_alive = std::make_unique<int>(0); ++physical; }
  }
  ~MediaWork() { if (keep_alive) --physical; }
};
int MediaWork::physical = 0;
bool MediaWork::refuse = false;
Profile* MediaWork::owner = nullptr;
namespace consent_testing {
void PublishedAttributionDrained(const GURL&) {}
void PublishedAttributionDiagnostic(content::WebContents*, int, int) {}
}
// PRODUCTION_CLASS
struct ConsentHost {
  content::WebContents* contents;
  bool configured = true;
  std::shared_ptr<PublishedBlankAttribution> blank_attribution_;
  explicit ConsentHost(content::WebContents* value) : contents(value) { value->consent_host = this; }
  static ConsentHost* FromWebContents(content::WebContents* value) {
    return static_cast<ConsentHost*>(value->consent_host);
  }
  bool enabled() { return configured; }
  content::WebContents* web_contents() { return contents; }
  // The 100 ms source poll (DEV-935) needs the real window fixture.
  int polls = 0;
  void UpdatePolling() { ++polls; }
  // PRODUCTION_ADMISSION
};
int main() {
  Profile ordinary, foreign, private_profile;
  private_profile.private_profile = true;
  content::WebContents source(&ordinary), child(&ordinary), other(&foreign), private_child(&private_profile);
  ConsentHost source_host(&source), host(&child), foreign_host(&other), private_host(&private_child);
  content::RenderFrameHost::registry[{5,10}] = &source.frame;
  content::RenderFrameHost::registry[{5,11}] = &child.frame;
  bool epoch = true;
  auto create = [&] {
    return std::make_shared<PublishedBlankAttribution>(&child, &source,
        source.frame.GetWeakDocumentPtr(), source.frame.GetWeakDocumentPtr(), Guard([&] { return epoch; }));
  };
  auto arm = [&](ConsentHost& receiver) {
    receiver.BindPublishedBlank(&source, source.frame.GetWeakDocumentPtr(),
        source.frame.GetWeakDocumentPtr(), Guard([&] { return epoch; }));
  };
  // Actual production admission refuses foreign/cross-OTR/configured/pending or
  // already-navigated children before retaining any evidence or physical work.
  arm(foreign_host); arm(private_host);
  assert(!foreign_host.blank_attribution_ && !private_host.blank_attribution_);
  child.controller.pending = true; arm(host); assert(!host.blank_attribution_);
  child.controller.pending = false; child.url = GURL("https://owned.test"); arm(host);
  assert(!host.blank_attribution_); child.url = GURL("about:blank");
  host.configured = false; arm(host); assert(!host.blank_attribution_); host.configured = true;
  source_host.configured = false; arm(host); assert(!host.blank_attribution_); source_host.configured = true;
  epoch = false; arm(host); assert(!host.blank_attribution_); epoch = true;
  std::vector<std::shared_ptr<PublishedBlankAttribution>> bounded;
  for (int i=0; i<16; ++i) bounded.push_back(create());
  arm(host); assert(!host.blank_attribution_ && PublishedBlankAttribution::Count() == 16);
  bounded.clear(); arm(host); assert(host.blank_attribution_); host.blank_attribution_.reset();
  assert(PublishedBlankAttribution::Count() == 0 && MediaWork::physical == 0);
  {
    content::WebContents private_source(&private_profile), same_private_child(&private_profile);
    ConsentHost private_source_host(&private_source), same_private_host(&same_private_child);
    private_source.visible = false;
    Profile other_private_profile; other_private_profile.private_profile = true;
    content::WebContents other_private_child(&other_private_profile);
    ConsentHost other_private_host(&other_private_child);
    other_private_host.BindPublishedBlank(&private_source, private_source.frame.GetWeakDocumentPtr(),
        private_source.frame.GetWeakDocumentPtr(), Guard([] { return true; }));
    assert(!other_private_host.blank_attribution_);
    same_private_host.BindPublishedBlank(&private_source, private_source.frame.GetWeakDocumentPtr(),
        private_source.frame.GetWeakDocumentPtr(), Guard([] { return true; }));
    auto private_proof = same_private_host.blank_attribution_;
    assert(private_proof);
    content::RenderFrameHost::registry[{5,10}] = &private_source.frame;
    content::NavigationHandle request; private_proof->NavigationStarted(&request);
    auto completion = private_proof->Completion();
    auto decision = private_proof->Decision(private_source.frame.GetWeakDocumentPtr());
    assert(completion && decision.Run() && MediaWork::owner == &private_profile);
    private_proof->Finish(); private_proof.reset(); same_private_host.blank_attribution_.reset();
    assert(MediaWork::physical == 1); completion.Run(); decision = Guard();
    assert(MediaWork::physical == 0);
    content::RenderFrameHost::registry[{5,10}] = &source.frame;
  }
  // First request only: ordinary HTTP, fragments, other frames, browser loads
  // and unrelated renderer initiators consume rather than lend foreign authority.
  for (int variant=0; variant<6; ++variant) {
    auto proof = create(); content::NavigationHandle navigation;
    if (variant == 0) navigation.url = GURL("https://owned.test");
    if (variant == 1) navigation.same = true;
    if (variant == 2) navigation.primary = false;
    if (variant == 3) navigation.renderer = false;
    if (variant == 4) navigation.token = 11;
    if (variant == 5) navigation.token.reset();
    proof->NavigationStarted(&navigation);
    assert(!proof->live() && !proof->Completion());
    content::NavigationHandle retry; proof->NavigationStarted(&retry); assert(!proof->live());
  }
  // Real AddNewContents precedes Chromium's synchronous initial blank commit.
  // Exercise the actual overlay predicate plus start/finish before resolution.
  auto bootstrap = [&] {
    content::NavigationHandle navigation;
    navigation.identifier = 20;
    navigation.url = GURL("about:blank");
    navigation.token.reset(); // Chromium's synthetic request has no initiator.
    navigation.initial_empty = true;
    navigation.is_synchronous_renderer_commit_ = true;
    navigation.committing_frame = &child.frame;
    return navigation;
  };
  {
    auto current = create(); auto initial = bootstrap();
    current->NavigationStarted(&initial);
    assert(current->live() && !current->deciding() && !current->Completion());
    // Completion before external navigation is an invalid Chrome entry and
    // intentionally consumes authority. Repeat with correct native ordering.
    assert(!current->live());
  }
  {
    auto current = create(); auto initial = bootstrap();
    current->NavigationStarted(&initial); initial.committed = true;
    current->NavigationFinished(&initial);
    assert(current->live() && !current->deciding());
    content::NavigationHandle external; current->NavigationStarted(&external);
    auto done = current->Completion(); auto decision = current->Decision(source.frame.GetWeakDocumentPtr());
    assert(done && decision.Run()); done.Run();
  }
  // Every discriminator is necessary. A URL-only or initial-empty-only later
  // about:blank, browser load, subframe or fragment spends the proof normally.
  for (int variant=0; variant<7; ++variant) {
    auto current = create(); auto initial = bootstrap();
    if (variant == 0) initial.is_synchronous_renderer_commit_ = false;
    if (variant == 1) initial.initial_empty = false;
    if (variant == 2) initial.renderer = false;
    if (variant == 3) initial.primary = false;
    if (variant == 4) initial.same = true;
    if (variant == 5) initial.url = GURL("about:blank#later");
    if (variant == 6) initial.identifier = 0;
    current->NavigationStarted(&initial); assert(!current->live());
  }
  // A bootstrap is never a second resolution, nor a deadline/doc/host refresh.
  for (int variant=0; variant<7; ++variant) {
    auto current = create(); auto initial = bootstrap();
    current->NavigationStarted(&initial);
    initial.committed = true;
    if (variant == 0) initial.committed = false;
    if (variant == 1) initial.error = true;
    if (variant == 2) initial.committing_frame = &source.frame;
    if (variant == 3) child.frame.document = std::make_shared<int>(0);
    if (variant == 4) epoch = false;
    if (variant == 5) base::TimeTicks::now = 30;
    if (variant == 6) ++child.attachment;
    current->NavigationFinished(&initial); assert(!current->live());
    epoch = true; base::TimeTicks::now = 0;
  }
  {
    auto current = create(); auto initial = bootstrap();
    current->NavigationStarted(&initial);
    content::NavigationHandle external; current->NavigationStarted(&external);
    assert(!current->live()); // cannot overlap the synchronous bootstrap
  }
  {
    auto current = create(); auto initial = bootstrap();
    current->NavigationStarted(&initial); initial.committed = true;
    current->NavigationFinished(&initial);
    initial.identifier = 21; current->NavigationStarted(&initial);
    assert(!current->live()); // even the same proven marker cannot repeat
  }
  {
    auto current = create(); content::NavigationHandle external;
    current->NavigationStarted(&external);
    auto initial = bootstrap(); current->NavigationStarted(&initial);
    assert(!current->live());
  }
  // Hiding the original opener is legitimate foreground adoption. The actual
  // child still needs its own visible exact attachment and genuine Chrome path.
  source.visible = false;
  auto proof = create(); content::NavigationHandle navigation;
  proof->NavigationStarted(&navigation); assert(proof->deciding());
  auto completion = proof->Completion(); assert(completion && MediaWork::physical == 1);
  auto guard = proof->Decision(source.frame.GetWeakDocumentPtr()); assert(guard.Run());
  proof->NavigationFinished(&navigation); assert(guard.Run()); // external ERR_ABORTED
  proof->Finish(); assert(!guard.Run()); proof.reset();
  assert(MediaWork::physical == 1); // real outstanding guard/callback holds profile/path
  completion.Run(); assert(MediaWork::physical == 1);
  guard = Guard(); assert(MediaWork::physical == 0);
  // Deadline and attachment/document/profile/epoch loss refuse the publication
  // guard. A failed proof cannot be revived by restoring a view or reusing IDs.
  for (int variant=0; variant<7; ++variant) {
    base::TimeTicks::now = 0; child.visible = true; child.attached = true; epoch = true;
    auto current = create(); content::NavigationHandle request; current->NavigationStarted(&request);
    auto done = current->Completion(); auto decision = current->Decision(source.frame.GetWeakDocumentPtr());
    assert(done && decision.Run());
    if (variant == 0) base::TimeTicks::now = 30;
    if (variant == 1) ++child.attachment;
    if (variant == 2) child.visible = false;
    if (variant == 3) epoch = false;
    if (variant == 4) child.profile = &foreign;
    if (variant == 5) source.frame.document = std::make_shared<int>(0);
    if (variant == 6) child.frame.document = std::make_shared<int>(0);
    assert(!decision.Run()); current->Finish();
    child.profile = &ordinary; child.visible = true; epoch = true; base::TimeTicks::now = 0;
    assert(!decision.Run()); done.Run(); current.reset(); decision = Guard();
    assert(MediaWork::physical == 0);
  }
  {
    auto current = create(); content::NavigationHandle first; current->NavigationStarted(&first);
    auto done = current->Completion(); auto decision = current->Decision(source.frame.GetWeakDocumentPtr());
    content::NavigationHandle second; second.identifier = 2; current->NavigationStarted(&second);
    assert(!decision.Run()); done.Run();
  }
  {
    MediaWork::refuse = true;
    auto current = create(); content::NavigationHandle first; current->NavigationStarted(&first);
    assert(!current->Completion() && !current->live() && MediaWork::physical == 0);
    MediaWork::refuse = false;
  }
  {
    auto current = create(); content::NavigationHandle first; current->NavigationStarted(&first);
    auto done = current->Completion(); auto decision = current->Decision(source.frame.GetWeakDocumentPtr());
    child.lifetime.reset(); assert(!decision.Run()); current->Finish(); current.reset();
    assert(MediaWork::physical == 1); done.Run(); decision = Guard(); assert(MediaWork::physical == 0);
  }
  assert(PublishedBlankAttribution::Count() == 0);
}
