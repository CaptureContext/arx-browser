#ifndef ARX_DOCUMENT_PROTOTYPE_RECORDER_H_
#define ARX_DOCUMENT_PROTOTYPE_RECORDER_H_

#include "base/memory/weak_ptr.h"
#include "components/paint_preview/arx/document_capture.mojom.h"
#include "content/public/renderer/render_frame_observer.h"
#include "mojo/public/cpp/bindings/associated_receiver.h"

namespace arx::document {

class DocumentRecorder final : public content::RenderFrameObserver,
                               public mojom::DocumentRecorder {
 public:
  explicit DocumentRecorder(content::RenderFrame* frame);
  ~DocumentRecorder() override;

  void Inspect(InspectCallback callback) override;
  void Record(mojom::GeometryPtr expected, mojom::LimitsPtr limits,
              RecordCallback callback) override;

 private:
  void Bind(mojo::PendingAssociatedReceiver<mojom::DocumentRecorder> receiver);
  void OnDestruct() override;
  mojom::GeometryPtr Geometry() const;

  bool recording_ = false;
  mojo::AssociatedReceiver<mojom::DocumentRecorder> receiver_{this};
  base::WeakPtrFactory<DocumentRecorder> weak_factory_{this};
};

}  // namespace arx::document

#endif
