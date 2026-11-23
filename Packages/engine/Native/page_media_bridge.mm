#include "chrome/browser/arx/page_media_bridge.h"

#import <Foundation/Foundation.h>

#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "base/containers/flat_set.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/arx/page_media_hooks.h"
#include "components/arx_page_media/page_media.mojom.h"
#include "components/performance_manager/public/freezing/freezing.h"
#include "content/public/browser/document_user_data.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "mojo/public/cpp/bindings/associated_receiver.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_registry.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace arx {
namespace {

// The longest message either side passes on, as the renderer agent bounds it.
constexpr size_t kMaximumMessageBytes = 4 * 1024 * 1024;
// The longest script the renderer agent accepts.
constexpr size_t kMaximumScriptBytes = 1024 * 1024;
// More origins than any bridged site list needs.
constexpr size_t kMaximumOrigins = 64;

struct Bridge {
  base::flat_set<std::string> origins;
  std::string script;
  ArxPageMediaHandler handler = nullptr;
  void* context = nullptr;
  // The next document number; 0 is never a document.
  uint64_t next_document = 1;

  bool Bridges(const url::Origin& origin) const {
    return handler && !script.empty() && !origin.opaque() &&
           origins.contains(origin.Serialize());
  }
};

Bridge& CurrentBridge() {
  static base::NoDestructor<Bridge> bridge;
  return *bridge;
}

// The page media host of one bridged document. Chromium deletes it with the
// document, so a message can never reach the app on behalf of the next one.
class PageMediaDocument final : public content::DocumentUserData<PageMediaDocument>,
                                public page_media::mojom::PageMediaHost {
 public:
  ~PageMediaDocument() override = default;

  uint64_t number() const { return number_; }

  void Bind(mojo::PendingAssociatedReceiver<page_media::mojom::PageMediaHost> receiver) {
    receiver_.reset();
    receiver_.Bind(std::move(receiver));
  }

  bool Deliver(std::string message) {
    if (!agent_) render_frame_host().GetRemoteAssociatedInterfaces()->GetInterface(&agent_);
    agent_->Deliver(message);
    return true;
  }

  // page_media::mojom::PageMediaHost
  void Send(const std::string& message) override {
    content::RenderFrameHost& frame = render_frame_host();
    const Bridge& bridge = CurrentBridge();
    // The bridge may have been turned off, or this origin taken off it, since
    // the document started.
    if (message.size() > kMaximumMessageBytes || !frame.IsActive() ||
        !frame.IsInPrimaryMainFrame() || !bridge.Bridges(frame.GetLastCommittedOrigin())) {
      return;
    }
    auto* contents = content::WebContents::FromRenderFrameHost(&frame);
    const uint64_t page = contents ? PageIdentifier(contents) : 0;
    if (!page) return;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&DispatchToApp, page, number_, frame.GetWeakDocumentPtr(),
                                  message));
  }

 private:
  friend class content::DocumentUserData<PageMediaDocument>;
  DOCUMENT_USER_DATA_KEY_DECL();

  explicit PageMediaDocument(content::RenderFrameHost* frame)
      : content::DocumentUserData<PageMediaDocument>(frame),
        number_(CurrentBridge().next_document++) {}

  // Passes on a message `Send` posted, if its document is still the page's
  // current, bridged one. A navigation may commit meanwhile: the message of the
  // previous document must not reach the app as if the next one sent it, where
  // a stale failure could move the new document to WebKit.
  static void DispatchToApp(uint64_t page,
                            uint64_t document,
                            content::WeakDocumentPtr weak_document,
                            std::string message) {
    const Bridge& bridge = CurrentBridge();
    content::RenderFrameHost* frame = weak_document.AsRenderFrameHostIfValid();
    content::WebContents* contents = PageContents(page);
    if (!bridge.handler || !frame || !contents || !frame->IsActive() ||
        !frame->IsInPrimaryMainFrame() ||
        content::WebContents::FromRenderFrameHost(frame) != contents ||
        !bridge.Bridges(frame->GetLastCommittedOrigin())) {
      return;
    }
    PageMediaDocument* current = PageMediaDocument::GetForCurrentDocument(frame);
    if (!current || current->number() != document) return;
    bridge.handler(bridge.context, page, document, message.data(), message.size());
  }

  const uint64_t number_;
  mojo::AssociatedReceiver<page_media::mojom::PageMediaHost> receiver_{this};
  mojo::AssociatedRemote<page_media::mojom::PageMediaAgent> agent_;
};

DOCUMENT_USER_DATA_KEY_IMPL(PageMediaDocument);

void BindPageMediaHost(content::RenderFrameHost* frame,
                       mojo::PendingAssociatedReceiver<page_media::mojom::PageMediaHost> receiver) {
  if (!frame || !frame->IsActive() || !frame->IsInPrimaryMainFrame() ||
      !CurrentBridge().Bridges(frame->GetLastCommittedOrigin())) {
    return;
  }
  auto* contents = content::WebContents::FromRenderFrameHost(frame);
  if (!contents || !PageIdentifier(contents)) return;
  PageMediaDocument::GetOrCreateForCurrentDocument(frame)->Bind(std::move(receiver));
}

// Prepares every cross-document commit of an Arx page's primary main frame:
// the bridge's script for a bridged origin, nothing otherwise, so a stale
// preparation never runs in a later document.
class PageMediaPreparer final : public content::WebContentsObserver,
                                public content::WebContentsUserData<PageMediaPreparer> {
 public:
  ~PageMediaPreparer() override = default;

  // DEV-1151: while Arx's FairPlay helper holds the current document's track,
  // playing or paused, the page is silent and has no player Chromium knows,
  // yet its script answers licence renewals, moves to the next track and takes
  // Now Playing's commands. A lease keeps the page out of every kind of
  // freezing (voting, Battery Saver, infinite tabs) until the app ends it for
  // that document, the document stops being the primary page's, or the page
  // closes. It reuses ScopedMediaRunnableLease, the resource-only exemption
  // media_bridge.mm holds for an automatic picture in picture candidate.
  void SetKeepsRunning(uint64_t document, bool keeps) {
    if (!keeps) {
      // Only the document's own lease: a late end never drops a newer one.
      if (lease_document_ == document) {
        lease_.reset();
        lease_document_ = 0;
      }
      return;
    }
    if (lease_ && lease_document_ == document) return;
    lease_.reset();
    lease_ = std::make_unique<performance_manager::freezing::ScopedMediaRunnableLease>(
        web_contents());
    lease_document_ = document;
  }

  // content::WebContentsObserver
  void PrimaryPageChanged(content::Page& page) override {
    // A lease belongs to one document; the next never inherits it.
    lease_.reset();
    lease_document_ = 0;
  }

  void ReadyToCommitNavigation(content::NavigationHandle* navigation) override {
    // A document restored from the back/forward cache keeps its script.
    if (!navigation->IsInPrimaryMainFrame() || navigation->IsSameDocument() ||
        navigation->IsServedFromBackForwardCache()) {
      return;
    }
    content::RenderFrameHost* frame = navigation->GetRenderFrameHost();
    if (!frame) return;
    const std::optional<url::Origin> origin = navigation->GetOriginToCommit();
    const Bridge& bridge = CurrentBridge();
    const bool bridged = origin && bridge.Bridges(*origin);
    mojo::AssociatedRemote<page_media::mojom::PageMediaAgent> agent;
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&agent);
    // Sent on the frame's channel ahead of the commit, so the renderer has it
    // when the new document's element is created.
    agent->Prepare(bridged ? origin->Serialize() : std::string(),
                   bridged ? bridge.script : std::string());
  }

 private:
  friend class content::WebContentsUserData<PageMediaPreparer>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();

  explicit PageMediaPreparer(content::WebContents* contents)
      : content::WebContentsObserver(contents),
        content::WebContentsUserData<PageMediaPreparer>(*contents) {}

  std::unique_ptr<performance_manager::freezing::ScopedMediaRunnableLease> lease_;
  // The document the lease is for; 0 without one.
  uint64_t lease_document_ = 0;
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(PageMediaPreparer);

}  // namespace

void AttachPageMedia(content::WebContents* contents) {
  if (contents) PageMediaPreparer::CreateForWebContents(contents);
}

void RegisterPageMediaBinders(content::RenderFrameHost& frame,
                              blink::AssociatedInterfaceRegistry& registry) {
  registry.AddInterface<page_media::mojom::PageMediaHost>(
      base::BindRepeating(&BindPageMediaHost, &frame));
}

}  // namespace arx

extern "C" __attribute__((visibility("default")))
void ArxEngineSetPageMediaBridge(const char* const* origins, size_t origin_count,
                                 const char* script, ArxPageMediaHandler handler,
                                 void* context) {
  CHECK([NSThread isMainThread]);
  arx::Bridge& bridge = arx::CurrentBridge();
  bridge.origins.clear();
  bridge.script.clear();
  bridge.handler = handler;
  bridge.context = context;
  if (!handler || !script || !origins || origin_count > arx::kMaximumOrigins) return;
  const std::string source(script);
  if (source.size() > arx::kMaximumScriptBytes) return;
  for (size_t index = 0; index < origin_count; ++index) {
    if (!origins[index]) continue;
    // Only exact, serialized https origins: the script never runs in an opaque,
    // insecure or partly matched one.
    const url::Origin origin = url::Origin::Create(GURL(origins[index]));
    if (origin.opaque() || origin.scheme() != "https" || origin.Serialize() != origins[index]) {
      continue;
    }
    bridge.origins.insert(origin.Serialize());
  }
  if (!bridge.origins.empty()) bridge.script = source;
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineSetPageMediaKeepsRunning(uint64_t page, uint64_t document, bool keeps) {
  CHECK([NSThread isMainThread]);
  auto* contents = arx::PageContents(page);
  auto* preparer = contents ? arx::PageMediaPreparer::FromWebContents(contents) : nullptr;
  if (!preparer || !document) return false;
  if (!keeps) {
    preparer->SetKeepsRunning(document, false);
    return true;
  }
  content::RenderFrameHost* frame = contents->GetPrimaryMainFrame();
  auto* current = frame ? arx::PageMediaDocument::GetForCurrentDocument(frame) : nullptr;
  if (!current || current->number() != document) return false;
  preparer->SetKeepsRunning(document, true);
  return true;
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineSendPageMedia(uint64_t page, uint64_t document, const char* message,
                            size_t length) {
  CHECK([NSThread isMainThread]);
  if (!document || !message || length > arx::kMaximumMessageBytes) return false;
  auto* contents = arx::PageContents(page);
  if (!contents) return false;
  content::RenderFrameHost* frame = contents->GetPrimaryMainFrame();
  auto* current = frame ? arx::PageMediaDocument::GetForCurrentDocument(frame) : nullptr;
  if (!current || current->number() != document) return false;
  return current->Deliver(std::string(message, length));
}
