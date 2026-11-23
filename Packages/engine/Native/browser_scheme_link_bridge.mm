// DEV-1193. A page's chrome:// link, which Blink refuses in the renderer, offered to
// the app as any app's link is (ABI50, external_link_bridge.h): App Links' built-in
// handler for Chrome's pages asks Chrome or Arx, guarded by the document that asked.

#include "chrome/browser/arx/browser_scheme_link_hooks.h"

#include <memory>
#include <utility>

#include "base/functional/callback_helpers.h"
#include "chrome/browser/arx/external_link_bridge.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/weak_document_ptr.h"
#include "mojo/public/cpp/bindings/self_owned_receiver.h"
#include "third_party/blink/public/mojom/arx/browser_scheme_link.mojom.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace arx {
namespace {

// Links longer than this are no browser page; the app drops them too.
constexpr size_t kMaximumLinkLength = 8192;

// One per bound report. The frame is looked up again when the report arrives,
// so a frame that went, or a document that's no longer active, reports nothing.
class BrowserSchemeLinkHost : public blink::mojom::ArxBrowserSchemeLinkHost {
 public:
  explicit BrowserSchemeLinkHost(content::GlobalRenderFrameHostId frame)
      : frame_(frame) {}

  void ReportRefusedLink(const GURL& url) override {
    content::RenderFrameHost* frame = content::RenderFrameHost::FromID(frame_);
    // The browser's own record of the person's activation decides, not the
    // renderer's word: a page can't open the question without a click or key.
    if (!frame || !frame->IsActive() || !frame->HasTransientUserActivation() ||
        !url.is_valid() || !url.SchemeIs("chrome") || url.has_username() ||
        url.has_password() || url.spec().size() > kMaximumLinkLength) {
      return;
    }
    content::WebContents* contents = content::WebContents::FromRenderFrameHost(frame);
    if (!contents || !OffersExternalLinks(contents)) return;
    // The same guard Chrome's external-protocol path takes (page_consent_overlay.py):
    // the offer, and the app's later recheck (external_link_is_current), hold only
    // while the frame that asked shows that document, hasn't started leaving it,
    // and its page is still shown where it was. No guard, no offer.
    auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents);
    if (!manager || !manager->delegate()) return;
    base::RepeatingCallback<bool()> source_guard =
        manager->delegate()->GetDialogDecisionGuard(contents, frame->GetWeakDocumentPtr());
    if (!source_guard || !source_guard.Run()) return;
    // Chrome's own path for a refused chrome:// link is to do nothing: the
    // navigation stays refused whatever the app answers.
    OfferExternalLink(contents, url, frame->GetLastCommittedOrigin(),
                      ui::PAGE_TRANSITION_LINK, /*has_user_gesture=*/true,
                      std::move(source_guard), base::DoNothing());
  }

 private:
  const content::GlobalRenderFrameHostId frame_;
};

}  // namespace

void BindBrowserSchemeLinkHost(
    content::RenderFrameHost* frame,
    mojo::PendingReceiver<blink::mojom::ArxBrowserSchemeLinkHost> receiver) {
  if (!frame) return;
  mojo::MakeSelfOwnedReceiver(
      std::make_unique<BrowserSchemeLinkHost>(frame->GetGlobalId()),
      std::move(receiver));
}

}  // namespace arx
