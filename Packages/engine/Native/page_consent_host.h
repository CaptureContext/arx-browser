#ifndef ARX_PAGE_CONSENT_HOST_H_
#define ARX_PAGE_CONSENT_HOST_H_

#include "content/public/browser/media_stream_request.h"
#include "base/functional/callback.h"
#include "content/public/browser/weak_document_ptr.h"
#include <memory>
#include "third_party/blink/public/mojom/mediastream/media_stream.mojom-forward.h"

class Profile;
namespace base { class FilePath; }
namespace content { class RenderFrameHost; class WebContents; }
namespace url { class Origin; }
class GURL;

namespace arx {
// Opt-in is per exact WebContents. Disabling never falls back to Chrome UI that
// requires an unrelated Browser window. Existing consent is invalidated first.
void ConfigurePageConsentHosting(content::WebContents*, bool enabled);
void TearDownPageConsentHosting(content::WebContents*);
void RequestPageMediaAccess(content::WebContents*, const content::MediaStreamRequest&,
                            content::MediaResponseCallback);
bool CheckPageMediaAccess(content::RenderFrameHost*, const url::Origin&,
                          blink::mojom::MediaStreamType);
// Includes the physical dispatcher callback lifetime, even after its page closes.
// Callers must hold both ordinary retirement and OTR destruction while true.
bool HasPageConsentWork(Profile*);
// Independent of engine profile maps. Snapshot paths outlive page/map removal.
bool HasPageConsentWorkForPath(const base::FilePath&);
// Native-only target=_blank handoff. The caller has consumed exact creation
// proof and a real fresh gesture. No child is published as a browser tab.
bool IsPageExternalTarget(content::WebContents*, const GURL&);
content::WebContents* AdoptPageExternalTarget(
    std::unique_ptr<content::WebContents>, content::WebContents* source,
    content::WeakDocumentPtr initiator, content::WeakDocumentPtr source_primary,
    const GURL&, base::RepeatingCallback<bool()> source_epoch_current);
// Already accepted same-context blank child: attribution only, not gesture/policy
// admission. The exact child remains owned by its published Page and visible host.
void BindPublishedBlankChildProvenance(content::WebContents* child, content::WebContents* source,
    content::WeakDocumentPtr initiator, content::WeakDocumentPtr source_primary,
    base::RepeatingCallback<bool()> source_epoch_current);
void StopPageExternalTargets();
}  // namespace arx
#endif
