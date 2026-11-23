#ifndef ARX_INSPECTION_INSPECTOR_H_
#define ARX_INSPECTION_INSPECTOR_H_

#include <map>
#include <string>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "components/arx_inspection/inspection.mojom.h"
#include "content/public/renderer/render_frame_observer.h"
#include "mojo/public/cpp/bindings/associated_receiver.h"
#include "third_party/blink/public/web/web_node.h"
#include "third_party/blink/public/web/arx_form_actions.h"
#include "third_party/blink/public/web/arx_keypress_actions.h"
#include "third_party/blink/public/web/arx_form_state_actions.h"
#include "third_party/blink/public/web/arx_keyboard_actions.h"
#include "third_party/blink/public/web/arx_pointer_actions.h"

namespace arx::inspection {
class Inspector final : public content::RenderFrameObserver,
                        public mojom::Inspector {
 public:
  explicit Inspector(content::RenderFrame* frame);
  ~Inspector() override;
  void Inspect(const std::string& scope, const std::string& snapshot,
               mojom::LimitsPtr limits, InspectCallback callback) override;
  void Validate(const std::string& scope, const std::string& snapshot,
                const std::string& reference, ValidateCallback callback) override;
  void Forget(const std::string& snapshot) override;
  void Click(const std::string& scope, const std::string& snapshot,
             const std::string& reference, const std::string& operation,
             ClickCallback callback) override;
  void FormAction(const std::string& scope, const std::string& snapshot,
                  const std::string& reference, const std::string& operation,
                  mojom::FormActionKind kind, const std::vector<uint8_t>& payload,
                  FormActionCallback callback) override;
  void PointerAction(const std::string& scope, const std::string& snapshot,
                     const std::string& reference, const std::string& operation,
                     mojom::FormActionKind kind, const std::vector<uint8_t>& payload,
                     PointerActionCallback callback) override;
  void KeyboardAction(const std::string& scope, const std::string& snapshot,
                      const std::string& reference, const std::string& operation,
                      mojom::FormActionKind kind, const std::vector<uint8_t>& payload,
                      KeyboardActionCallback callback) override;
  void FormStateAction(const std::string& scope, const std::string& snapshot,
                       const std::string& reference, const std::string& operation,
                       mojom::FormActionKind kind, const std::vector<uint8_t>& payload,
                       FormStateActionCallback callback) override;
  void Scroll(const std::string& scope, const std::string& snapshot,
              const std::string& reference, const std::string& operation,
              mojom::ScrollAxis axis, double delta_css_pixels, ScrollCallback callback) override;
  void DidCreateNewDocument() override;
  void OnDestruct() override;

 private:
  struct Handle {
    std::string token;
    int id;
    blink::WebNode node;
    blink::ArxFormBaselineStatus baseline_status = blink::ArxFormBaselineStatus::kUnsupported;
    blink::ArxFormBaseline baseline;
    blink::ArxFormBaselineStatus key_baseline_status = blink::ArxFormBaselineStatus::kUnsupported;
    blink::ArxKeypressBaseline key_baseline;

  };
  struct Snapshot {
    std::string scope;
    std::string document;
    uint64_t version;
    base::TimeTicks expires;
    std::vector<Handle> handles;
  };
  void Bind(mojo::PendingAssociatedReceiver<mojom::Inspector> receiver);
  void Clear();
  void Prune();
  std::map<std::string, Snapshot> snapshots_;
  mojo::AssociatedReceiver<mojom::Inspector> receiver_{this};
  base::RepeatingTimer expiry_;
  base::WeakPtrFactory<Inspector> weak_{this};
};
}  // namespace arx::inspection
#endif
