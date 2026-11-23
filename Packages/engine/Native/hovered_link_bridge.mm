#include "chrome/browser/arx/hovered_link_bridge.h"

#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/ref_counted.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"

namespace arx {
namespace {
// Hover reports wait for this, so it stays short: an answer takes a few
// milliseconds unless a frame is busy.
constexpr base::TimeDelta kTimeout = base::Milliseconds(250);

// Read-only. [href, where] for the frame's hovered link, or null. `where` is the
// link's target keyword, ASCII case-insensitive and untrimmed as HTML matches it: "self" (no
// target or `_self`), "blank", "top" (`_top`, `_unfencedTop`), "parent", or
// "named" for any other browsing context name and for a link with `download`,
// which may save rather than navigate. An SVG link's href is an
// SVGAnimatedString, resolved against the link's base URL.
constexpr char16_t kScript[] = uR"JS((() => {
  let element = null;
  let root = document;
  for (;;) {
    const hovered = root.querySelectorAll(':hover');
    const deepest = hovered[hovered.length - 1];
    if (!deepest) break;
    element = deepest;
    if (!deepest.shadowRoot) break;
    root = deepest.shadowRoot;
  }
  // The closest link in the composed tree: through the slot a node is shown in,
  // and from a shadow root to its host, as a link may wrap either.
  let link = null;
  const up = (node) => node.assignedSlot || (node instanceof ShadowRoot ? node.host : node.parentNode);
  for (let node = element; node; node = up(node)) {
    if (node.nodeType === Node.ELEMENT_NODE && node.matches('a[href], area[href]')) {
      link = node;
      break;
    }
  }
  if (!link) return null;
  let href = link.href;
  // A download link may save instead of navigating, whatever its target.
  const downloads = link.hasAttribute('download');
  if (typeof href !== 'string') {
    if (!href || typeof href.baseVal !== 'string') return null;
    try { href = new URL(href.baseVal, link.baseURI).href; } catch { return null; }
  }
  // An empty target falls back to the document's base target, as Chromium's does.
  let target = link.getAttribute('target') || '';
  if (target === '') {
    const base = document.querySelector('base[target]');
    target = base ? base.getAttribute('target') || '' : '';
  }
  // Keywords match ASCII case-insensitively and exactly: " _self " is a name.
  const keyword = target.toLowerCase();
  const where = downloads ? 'named'
    : keyword === '' || keyword === '_self' ? 'self'
    : keyword === '_blank' ? 'blank'
    : keyword === '_top' || keyword === '_unfencedtop' ? 'top'
    : keyword === '_parent' ? 'parent'
    : 'named';
  return [href, where];
})())JS";

class Pending : public base::RefCounted<Pending> {
 public:
  GURL link;
  HoveredLinkTargetReply reply;
  size_t outstanding = 0;
  bool done = false;
  std::vector<HoveredLinkTarget> matches;
  base::WeakPtr<content::WebContents> contents;
  content::WeakDocumentPtr primary;

 private:
  friend class base::RefCounted<Pending>;
  ~Pending() = default;
};

void ReplyLater(HoveredLinkTargetReply reply, HoveredLinkTarget target) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(std::move(reply), target));
}

void Finish(const scoped_refptr<Pending>& pending) {
  if (pending->done) return;
  pending->done = true;
  HoveredLinkTarget target = HoveredLinkTarget::kUnknown;
  auto* contents = pending->contents.get();
  auto* primary = pending->primary.AsRenderFrameHostIfValid();
  // The same document must still be the page's, every frame must have answered
  // (one still out may hold the same link with another target), and exactly one
  // must have the link under the pointer.
  if (contents && !contents->IsBeingDestroyed() && primary &&
      primary == contents->GetPrimaryMainFrame() && pending->outstanding == 0 &&
      pending->matches.size() == 1)
    target = pending->matches.front();
  ReplyLater(std::move(pending->reply), target);
}

// Where `where` sends a navigation from `frame`.
HoveredLinkTarget Resolve(content::RenderFrameHost* frame, const std::string& where) {
  const bool is_main = !frame->GetParent();
  const bool parent_is_main = is_main || !frame->GetParent()->GetParent();
  if (where == "blank") return HoveredLinkTarget::kNewContext;
  if (where == "top") return HoveredLinkTarget::kMainFrame;
  if (where == "self") return is_main ? HoveredLinkTarget::kMainFrame : HoveredLinkTarget::kSubframe;
  if (where == "parent")
    return parent_is_main ? HoveredLinkTarget::kMainFrame : HoveredLinkTarget::kSubframe;
  return HoveredLinkTarget::kUnknown;
}

void Answer(const scoped_refptr<Pending>& pending, content::WeakDocumentPtr document,
            base::Value result) {
  if (pending->done) return;
  auto* frame = document.AsRenderFrameHostIfValid();
  if (frame && result.is_list() && result.GetList().size() == 2 &&
      result.GetList()[0].is_string() && result.GetList()[1].is_string() &&
      GURL(result.GetList()[0].GetString()) == pending->link)
    pending->matches.push_back(Resolve(frame, result.GetList()[1].GetString()));
  if (--pending->outstanding == 0) Finish(pending);
}
}  // namespace

void RequestHoveredLinkTarget(content::WebContents* contents, const GURL& link,
                              HoveredLinkTargetReply reply) {
  if (!contents || contents->IsBeingDestroyed() || contents->IsCrashed() || !link.is_valid()) {
    ReplyLater(std::move(reply), HoveredLinkTarget::kUnknown);
    return;
  }
  auto* primary = contents->GetPrimaryMainFrame();
  std::vector<content::RenderFrameHost*> frames;
  primary->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
    if (frame->IsActive() && frame->IsRenderFrameLive() &&
        frame->GetOutermostMainFrame() == primary)
      frames.push_back(frame);
  });
  if (frames.empty()) {
    ReplyLater(std::move(reply), HoveredLinkTarget::kUnknown);
    return;
  }

  auto pending = base::MakeRefCounted<Pending>();
  pending->link = link;
  pending->reply = std::move(reply);
  pending->outstanding = frames.size();
  pending->contents = contents->GetWeakPtr();
  pending->primary = primary->GetWeakDocumentPtr();

  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE, base::BindOnce(
      [](scoped_refptr<Pending> pending) { Finish(pending); }, pending), kTimeout);
  for (auto* frame : frames) {
    frame->ExecuteJavaScriptInIsolatedWorld(
        kScript,
        base::BindOnce(&Answer, pending, frame->GetWeakDocumentPtr()),
        ISOLATED_WORLD_ID_CHROME_INTERNAL);
  }
}
}  // namespace arx
