#include "chrome/browser/arx/form_edits_bridge.h"

#import <Foundation/Foundation.h>

#include <cstdint>
#include <set>
#include <utility>
#include <vector>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/ref_counted.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"
#include "url/url_constants.h"

namespace arx {
namespace {
constexpr base::TimeDelta kTimeout = base::Milliseconds(2000);
// A page with more frames than this is treated as holding input.
constexpr size_t kMaximumFrames = 128;

// Read-only, in one frame: its document and open shadow roots. Child frames
// are read on their own, so a cross-origin one is too. Returns a boolean only.
constexpr char16_t kScript[] = uR"JS((() => {
  const roots = [];
  const gather = (root) => {
    roots.push(root);
    for (const element of root.querySelectorAll('*'))
      if (element.shadowRoot) gather(element.shadowRoot);
  };
  gather(document);
  const typed = (field) => {
    if (field.disabled || field.readOnly) return false;
    if (field.tagName === 'SELECT') {
      const options = Array.from(field.options);
      if (field.multiple) return options.some((option) => option.selected !== option.defaultSelected);
      // The last option marked selected is the one a single choice starts at.
      const initial = options.map((option) => option.defaultSelected).lastIndexOf(true);
      // Without a default, a dropdown starts at its first option that can be chosen and a
      // list box (size above 1) with nothing chosen.
      // An option in a disabled group can't be chosen either.
      const usable = (option) => !option.disabled && !(option.parentElement && option.parentElement.tagName === 'OPTGROUP' && option.parentElement.disabled);
      const start = initial >= 0 ? initial : field.size > 1 ? -1 : options.findIndex(usable);
      return field.selectedIndex !== start;
    }
    const type = (field.type || '').toLowerCase();
    if (type === 'checkbox' || type === 'radio') return field.checked !== field.defaultChecked;
    // A file chosen for upload can't come back once the page closes (DEV-1092).
    if (type === 'file') return !!field.files && field.files.length > 0;
    if (['hidden', 'submit', 'button', 'reset', 'image'].includes(type)) return false;
    // A range or color input has a value of the browser's own before anyone touches it.
    if (type === 'range' || type === 'color') {
      const initial = document.createElement('input');
      for (const name of ['type', 'min', 'max', 'step', 'value'])
        if (field.hasAttribute(name)) initial.setAttribute(name, field.getAttribute(name));
      return field.value !== initial.value;
    }
    // A number half typed ("-", "1e") reads as empty but is held as bad input.
    if (field.validity && field.validity.badInput) return true;
    // A changed value counts, a cleared default too; then an empty field doesn't.
    if (field.value !== field.defaultValue) return true;
    if (field.value.trim() === '') return false;
    const search = type === 'search' || field.getAttribute('role') === 'searchbox' || field.closest('[role=search]')
      || ['q', 'query', 'search', 's'].includes((field.name || '').toLowerCase());
    return !search;
  };
  return roots.some((root) =>
    Array.from(root.querySelectorAll('input, textarea, select')).some(typed)
    || Array.from(root.querySelectorAll('[contenteditable]')).some((area) => area.isContentEditable && area.textContent.trim() !== '')
  ) === true;
})())JS";

class Pending : public base::RefCounted<Pending> {
 public:
  uint64_t page = 0;
  uint64_t request = 0;
  FormEditsReply reply = nullptr;
  uintptr_t context = 0;
  size_t remaining = 0;
  bool unknown = false;
  bool done = false;
  base::WeakPtr<content::WebContents> contents;
  content::WeakDocumentPtr primary;
  // Each frame's document as the check found it, and the frames it read.
  std::vector<content::WeakDocumentPtr> documents;
  std::set<content::GlobalRenderFrameHostId> frames;

 private:
  friend class base::RefCounted<Pending>;
  ~Pending() = default;
};

void ReplyLater(FormEditsReply reply, uintptr_t context, uint64_t request,
                uint64_t page, int32_t result) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](FormEditsReply reply, uintptr_t context, uint64_t request,
             uint64_t page, int32_t result) {
            reply(reinterpret_cast<void*>(context), request, page, result);
          },
          reply, context, request, page, result));
}

// A frame whose document the script can read: the web, and the blank, srcdoc,
// data and blob documents pages make. Chrome's and extensions' own frames are
// left alone.
bool Readable(content::RenderFrameHost* frame) {
  if (!frame->IsActive() || !frame->IsRenderFrameLive()) return false;
  const GURL& url = frame->GetLastCommittedURL();
  return url.SchemeIsHTTPOrHTTPS() || url.IsAboutBlank() || url.IsAboutSrcdoc() ||
         url.SchemeIs(url::kDataScheme) || url.SchemeIsBlob();
}

// The page still shows the document the check started on, and every frame it
// read still holds the document it read: one that navigated or went away
// meanwhile may hold input nobody checked.
bool Current(const Pending& pending) {
  auto* contents = pending.contents.get();
  if (!contents || contents->IsBeingDestroyed()) return false;
  auto* primary = pending.primary.AsRenderFrameHostIfValid();
  if (!primary || primary != contents->GetPrimaryMainFrame()) return false;
  // A frame that navigated to another process keeps its old host while it
  // unloads, so the host must still be the active one.
  for (const auto& document : pending.documents) {
    auto* frame = document.AsRenderFrameHostIfValid();
    if (!frame || !frame->IsActive()) return false;
  }
  // A frame added since, such as one a page mounts late, wasn't read.
  bool unread = false;
  primary->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
    if (Readable(frame) && !pending.frames.contains(frame->GetGlobalId())) unread = true;
  });
  return !unread;
}

// Answers in a later task, checking the documents again there: a frame that
// changed after the last answer must not get a clean result.
void Finish(const scoped_refptr<Pending>& pending, int32_t result) {
  if (pending->done) return;
  pending->done = true;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](scoped_refptr<Pending> pending, int32_t result) {
                       if (result == kFormEditsNone && !Current(*pending))
                         result = kFormEditsUnknown;
                       pending->reply(reinterpret_cast<void*>(pending->context),
                                      pending->request, pending->page, result);
                     },
                     pending, result));
}

void FrameAnswered(const scoped_refptr<Pending>& pending, base::Value result) {
  if (pending->done) return;
  if (result.is_bool() && result.GetBool()) {
    Finish(pending, kFormEditsTyped);
    return;
  }
  if (!result.is_bool()) pending->unknown = true;
  if (--pending->remaining == 0)
    Finish(pending, pending->unknown ? kFormEditsUnknown : kFormEditsNone);
}
}  // namespace

void CheckFormEdits(content::WebContents* contents, uint64_t page,
                    uint64_t request, FormEditsReply reply, void* context) {
  if (!reply) return;
  const auto opaque = reinterpret_cast<uintptr_t>(context);
  auto* primary = contents && !contents->IsBeingDestroyed() && !contents->IsCrashed()
                      ? contents->GetPrimaryMainFrame()
                      : nullptr;
  if (!primary || !primary->IsRenderFrameLive() ||
      !primary->GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) {
    ReplyLater(reply, opaque, request, page, kFormEditsNone);
    return;
  }

  std::vector<content::RenderFrameHost*> frames;
  bool too_many = false;
  primary->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
    if (!Readable(frame)) return;
    if (frames.size() == kMaximumFrames) {
      too_many = true;
      return;
    }
    frames.push_back(frame);
  });
  if (too_many || frames.empty()) {
    ReplyLater(reply, opaque, request, page, too_many ? kFormEditsUnknown : kFormEditsNone);
    return;
  }

  auto pending = base::MakeRefCounted<Pending>();
  pending->page = page;
  pending->request = request;
  pending->reply = reply;
  pending->context = opaque;
  pending->remaining = frames.size();
  pending->contents = contents->GetWeakPtr();
  pending->primary = primary->GetWeakDocumentPtr();
  for (auto* frame : frames) {
    pending->documents.push_back(frame->GetWeakDocumentPtr());
    pending->frames.insert(frame->GetGlobalId());
  }

  // A frame that goes away drops its callback; the timeout answers for it.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce([](scoped_refptr<Pending> pending) { Finish(pending, kFormEditsUnknown); },
                     pending),
      kTimeout);
  for (auto* frame : frames) {
    frame->ExecuteJavaScriptInIsolatedWorld(
        kScript, base::BindOnce(&FrameAnswered, pending),
        ISOLATED_WORLD_ID_CHROME_INTERNAL);
  }
}

}  // namespace arx

extern "C" __attribute__((visibility("default")))
bool ArxEngineCheckPageFormEdits(
    uint64_t page, uint64_t request,
    void (*reply)(void* context, uint64_t request, uint64_t page, int32_t result),
    void* context) {
  CHECK([NSThread isMainThread]);
  auto* contents = arx::PageContents(page);
  if (!contents || !reply) return false;
  arx::CheckFormEdits(contents, page, request, reply, context);
  return true;
}
