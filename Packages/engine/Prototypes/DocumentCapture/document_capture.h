#ifndef ARX_DOCUMENT_PROTOTYPE_CAPTURE_H_
#define ARX_DOCUMENT_PROTOTYPE_CAPTURE_H_

#include <vector>

#include "base/functional/callback_forward.h"
#include "base/unguessable_token.h"
#include "components/paint_preview/arx/document_capture.mojom.h"

namespace content { class WebContents; }

namespace arx::document {

struct Result {
  mojom::Status status;
  mojom::GeometryPtr geometry;
  std::vector<uint8_t> png;
  bool was_loading = false;
};

// Native implementation behind the ABI16 document-capture adapter.
// Layout pixels are encoded 1:1; the adapter reports zoom/device/raster scale
// separately and preserves the caller's document/session authorization.
base::UnguessableToken CaptureDocumentPrototype(
    content::WebContents* contents, mojom::LimitsPtr limits,
    base::OnceCallback<void(Result)> callback);
// Owned-fixture seam only. Holds after Inspect and before recording. There is no
// outstanding renderer/compositor work while held; cancel/timeout may retire it.
// The caller must eventually run or discard the continuation. No shipping ABI.
base::UnguessableToken CaptureDocumentPrototypeForTesting(
    content::WebContents* contents, mojom::LimitsPtr limits,
    base::OnceCallback<void(base::OnceClosure)> before_record,
    base::OnceCallback<void(Result)> callback);
void CancelDocumentPrototype(const base::UnguessableToken& operation);
void StopDocumentPrototype();

}  // namespace arx::document

#endif
