#ifndef ARX_INSPECTION_SCRIPT_RUNNER_H_
#define ARX_INSPECTION_SCRIPT_RUNNER_H_

#include <cstdint>
#include <string>

#include "base/memory/weak_ptr.h"
#include "components/arx_inspection/developer.mojom.h"
#include "content/public/renderer/render_frame_observer.h"
#include "mojo/public/cpp/bindings/associated_receiver_set.h"

namespace arx::developer {
inline constexpr size_t kMaximumSourceBytes = 65536;
inline constexpr uint32_t kMaximumResultBytes = 262144;
inline constexpr size_t kMaximumMessageBytes = 2048;

// The wrapper around an agent's script: an async function body whose value is
// awaited and serialized with JSON.stringify inside the developer world.
std::string WrapDeveloperScript(const std::string& source);

// One per render frame, created with the frame's Inspector. Runs agent
// scripts in Arx's developer world (DEV-668), and the app's page translation
// scripts in its translation world (ABI57, DEV-996).
class ScriptRunner final : public content::RenderFrameObserver,
                           public mojom::ScriptRunner {
 public:
  explicit ScriptRunner(content::RenderFrame* frame);
  ~ScriptRunner() override;
  void Evaluate(const std::string& source, uint32_t maximum_bytes,
                EvaluateCallback callback) override;
  // ABI57 (DEV-996): in Arx's translation world.
  void EvaluateTranslation(const std::string& source, uint32_t maximum_bytes,
                           EvaluateTranslationCallback callback) override;
  void OnDestruct() override;

 private:
  void Run(int32_t world, const std::string& source, uint32_t maximum_bytes,
           EvaluateCallback callback);
  void Bind(mojo::PendingAssociatedReceiver<mojom::ScriptRunner> receiver);
  mojo::AssociatedReceiverSet<mojom::ScriptRunner> receivers_;
  base::WeakPtrFactory<ScriptRunner> weak_{this};
};
}  // namespace arx::developer
#endif
