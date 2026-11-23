#ifndef ARX_DOCUMENT_PROTOTYPE_FIXTURE_H_
#define ARX_DOCUMENT_PROTOTYPE_FIXTURE_H_

#include <memory>
#include <optional>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "components/paint_preview/arx/document_capture.h"
#include "components/paint_preview/arx/fixture_contract.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/weak_document_ptr.h"
#include "url/gurl.h"

namespace network { class SimpleURLLoader; }

namespace arx::document::testing {

// Developer fixture only. Caller must provide its freshly owned disposable
// WebContents/profile/window and keep this object alive through completion.
// This class creates no UI, does not read user pages, and has no shipping ABI.
class OwnedCaptureFixture final : public content::WebContentsObserver {
 public:
  OwnedCaptureFixture(content::WebContents* contents, GURL loopback_origin,
                      base::OnceCallback<void(bool)> completion);
  ~OwnedCaptureFixture() override;
  void Start();
  void DidStopLoading() override;
  void DidStartNavigation(content::NavigationHandle* handle) override;
  void DidFinishNavigation(content::NavigationHandle* handle) override;
  void WebContentsDestroyed() override;

 private:
  using State = base::DictValue;
  using StateCallback = base::OnceCallback<void(State)>;
  using Response = base::OnceCallback<void(int, std::optional<std::string>)>;
  void Finish(bool success);
  void Navigate(const char* mode, base::OnceClosure loaded);
  GURL URL(const std::string& route, const std::string& query = {}) const;
  void Fetch(GURL url, Response response);
  void Fetched(Response response, std::optional<std::string> body);
  void AwaitState(int after, StateCallback callback);
  void StateReceived(int after, StateCallback callback, int code,
                     std::optional<std::string> body);
  void Before(State state);
  void CopyViewport(base::OnceCallback<void(ViewportSamples)> callback);
  void BeginPositive(ViewportSamples samples);
  void Captured(Result result);
  void After(State state);
  void ViewportVerified(ViewportSamples samples);
  void CheckCancellation();
  void Cancelled(Result result);
  void WaitDrained(base::OnceClosure continuation);
  void DrainResult(base::OnceClosure continuation, Result result);
  void CheckNavigation();
  void Navigated(Result result);
  void NavigationReady();
  void MaybeNavigationFinished();
  void CheckFrame();
  void HoldForFrame(base::OnceClosure resume);
  void Framed(Result result);
  void MaybeFrameFinished();
  void CheckRecordingBudget();
  void BudgetRejected(Result result);
  void AfterBudget(State state);
  void RepaintState(State state);
  void Repainted(ViewportSamples samples);
  bool RepaintSourceIsCurrent() const;
  void RunNextVariant();
  void BeforeVariant(State state);
  void VariantViewportBefore(ViewportSamples samples);
  void VariantCaptured(Result result);
  void AfterVariant(State state);
  void VariantViewportAfter(ViewportSamples samples);
  void VariantFinished();
  void CheckLimits();
  void LimitResult(Result result);

  const GURL origin_;
  base::OnceCallback<void(bool)> completion_;
  std::string run_;
  GURL expected_;
  base::OnceClosure loaded_;
  base::OnceClosure resume_record_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  base::OneShotTimer timeout_;
  base::OneShotTimer repaint_timeout_;
  content::WeakDocumentPtr repaint_document_;
  base::TimeTicks repaint_started_;
  uint32_t repaint_attempts_ = 0;
  bool repaint_wait_reported_ = false;
  State before_;
  ViewportSamples viewport_before_{};
  ViewportSamples repaint_last_samples_{};
  gfx::Size viewport_size_;
  float device_scale_ = 0;
  base::UnguessableToken operation_;
  const char* phase_ = "startup";
  bool navigation_check_ = false;
  bool navigation_ready_ = false;
  bool navigation_invalidated_ = false;
  bool frame_command_done_ = false;
  bool frame_invalidated_ = false;
  size_t variant_ = 0;
  double variant_factor_ = 1;
  bool allow_loading_state_ = false;
  bool finished_ = false;
  base::WeakPtrFactory<OwnedCaptureFixture> weak_factory_{this};
};

}  // namespace arx::document::testing
#endif
