#include "chrome/browser/arx/focused_link_bridge.h"

#import <AppKit/AppKit.h>

#include <optional>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/ref_counted.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/native_ui_types.h"
#include "url/gurl.h"

namespace arx {
namespace {
constexpr size_t kMaximumLinkBytes = 8192;
constexpr base::TimeDelta kTimeout = base::Milliseconds(2000);

// Read-only. Follows focus into open shadow roots; text fields and other
// controls never count as links, even inside one. An SVG link's href is an
// SVGAnimatedString, resolved against the link's base URL.
constexpr char16_t kScript[] = uR"JS((() => {
  let element = document.activeElement;
  while (element && element.shadowRoot && element.shadowRoot.activeElement)
    element = element.shadowRoot.activeElement;
  if (!element || element === document.body || element === document.documentElement) return null;
  if (element.isContentEditable || element.closest('input, textarea, select, button')) return null;
  const link = element.closest('a[href], area[href]');
  if (!link) return null;
  const href = link.href;
  if (typeof href === 'string') return href;
  if (!href || typeof href.baseVal !== 'string') return null;
  try { return new URL(href.baseVal, link.baseURI).href; } catch { return null; }
})())JS";

class Pending : public base::RefCounted<Pending> {
 public:
  uint64_t page = 0;
  uint64_t request = 0;
  uint64_t generation = 0;
  FocusedLinkReply reply = nullptr;
  bool done = false;
  base::WeakPtr<content::WebContents> contents;
  content::WeakDocumentPtr primary;
  content::WeakDocumentPtr frame;

 private:
  friend class base::RefCounted<Pending>;
  ~Pending() = default;
};

void ReplyLater(FocusedLinkReply reply, uint64_t request, uint64_t page, uint64_t generation,
                std::optional<std::string> url) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
      [](FocusedLinkReply reply, uint64_t request, uint64_t page, uint64_t generation,
         std::optional<std::string> url) {
        reply(request, page, generation, url ? url->data() : nullptr, url ? url->size() : 0);
      }, reply, request, page, generation, std::move(url)));
}

bool Visible(content::WebContents* contents) {
  NSView* view = contents->GetNativeView().GetNativeNSView();
  return view && view.window && view.window.visible && !view.window.miniaturized &&
      !view.hiddenOrHasHiddenAncestor;
}

bool Ordinary(content::WebContents* contents) {
  if (!contents || contents->IsBeingDestroyed() || contents->IsCrashed() ||
      contents->GetBrowserContext()->IsOffTheRecord()) return false;
  auto* primary = contents->GetPrimaryMainFrame();
  return primary && primary->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() && Visible(contents);
}

std::optional<std::string> AcceptedLink(const base::Value& result) {
  if (!result.is_string()) return std::nullopt;
  const GURL link(result.GetString());
  if (!link.is_valid() || !link.SchemeIsHTTPOrHTTPS() || link.has_username() ||
      link.has_password() || link.spec().size() > kMaximumLinkBytes) return std::nullopt;
  return link.spec();
}

// The page, its document and the frame the script ran in must all be the ones asked about.
bool Current(const Pending& pending) {
  auto* contents = pending.contents.get();
  if (!Ordinary(contents)) return false;
  auto* primary = pending.primary.AsRenderFrameHostIfValid();
  auto* frame = pending.frame.AsRenderFrameHostIfValid();
  return primary && frame && primary == contents->GetPrimaryMainFrame() &&
      frame->GetOutermostMainFrame() == primary;
}

void Finish(const scoped_refptr<Pending>& pending, std::optional<std::string> url) {
  if (pending->done) return;
  pending->done = true;
  if (url && !Current(*pending)) url.reset();
  ReplyLater(pending->reply, pending->request, pending->page, pending->generation, std::move(url));
}
}  // namespace

void RequestFocusedLink(content::WebContents* contents, uint64_t page, uint64_t request,
                        uint64_t generation, FocusedLinkReply reply) {
  if (!reply) return;
  if (!Ordinary(contents)) {
    ReplyLater(reply, request, page, generation, std::nullopt);
    return;
  }
  auto* frame = contents->GetFocusedFrame();
  auto* primary = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive() ||
      frame->GetOutermostMainFrame() != primary) {
    ReplyLater(reply, request, page, generation, std::nullopt);
    return;
  }

  auto pending = base::MakeRefCounted<Pending>();
  pending->page = page;
  pending->request = request;
  pending->generation = generation;
  pending->reply = reply;
  pending->contents = contents->GetWeakPtr();
  pending->primary = primary->GetWeakDocumentPtr();
  pending->frame = frame->GetWeakDocumentPtr();

  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE, base::BindOnce(
      [](scoped_refptr<Pending> pending) { Finish(pending, std::nullopt); }, pending), kTimeout);
  frame->ExecuteJavaScriptInIsolatedWorld(
      kScript,
      base::BindOnce([](scoped_refptr<Pending> pending, base::Value result) {
        Finish(pending, AcceptedLink(result));
      }, pending),
      ISOLATED_WORLD_ID_CHROME_INTERNAL);
}
}  // namespace arx
