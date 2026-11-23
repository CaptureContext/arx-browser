#include <cassert>
#include <functional>
#include <memory>
#include <optional>
#include <utility>
#include <vector>
#define FROM_HERE 0
#define CHECK(value) assert(value)
namespace base {
struct TimeTicks {};
template<class T> struct WeakPtr {
  T* value = nullptr;
  T* get() const { return value; }
  T* operator->() const { return value; }
  explicit operator bool() const { return value; }
};
struct Callback {
  std::function<void(std::optional<bool>)> body;
  Callback(std::function<void(std::optional<bool>)> body) : body(std::move(body)) {}
  Callback(Callback&& other) : body(std::exchange(other.body, {})) {}
  bool is_null() const { return !body; }
};
std::vector<std::function<void()>> tasks;
std::function<void()> BindOnce(Callback callback, std::optional<bool> result) {
  auto owned = std::make_shared<Callback>(std::move(callback));
  return [owned, result] { owned->body(result); };
}
struct SingleThreadTaskRunner {
  static SingleThreadTaskRunner* GetCurrentDefault() { static SingleThreadTaskRunner value; return &value; }
  void PostTask(int, std::function<void()> task) { tasks.push_back(std::move(task)); }
};
void Drain() { auto pending = std::exchange(tasks, {}); for (auto& task : pending) task(); }
}
struct Manager;
struct RenderFrameHostImpl {
  using ArxBeforeUnloadRequest = std::shared_ptr<base::Callback>;
  ArxBeforeUnloadRequest arx_before_unload_request_;
  bool is_waiting_for_beforeunload_completion_ = true;
  bool has_shown_beforeunload_dialog_ = true;
  struct Timer { bool stopped = false; void Stop() { stopped = true; } };
  std::unique_ptr<Timer> beforeunload_timeout_ = std::make_unique<Timer>();
  std::vector<int> beforeunload_pending_replies_ = {1};
  base::TimeTicks send_before_unload_start_time_;
  enum class PageCloseState { kNotClosing };
  PageCloseState page_close_state_;
  bool IsInBackForwardCache() const { return false; }
  bool IsPendingDeletion() const { return false; }
  static void NoHandler(base::WeakPtr<RenderFrameHostImpl> self, base::WeakPtr<Manager> manager, ArxBeforeUnloadRequest request);
  void ResetWaitingState();
  void DispatchOrdinary() {
    bool arx_callback = false;
    // PRODUCTION_ORDINARY_TRANSITION
  }
  void FinishArxBeforeUnload(std::optional<bool> result);
  static bool ArxBeforeUnloadMatches(RenderFrameHostImpl*, base::WeakPtr<RenderFrameHostImpl>, const ArxBeforeUnloadRequest&);
};
struct Manager {
  RenderFrameHostImpl* frame = nullptr;
  int completions = 0;
  RenderFrameHostImpl* current_frame_host() { return frame; }
  void BeforeUnloadCompleted(bool proceed) { assert(proceed); ++completions; }
};
// PRODUCTION_METHODS
void RenderFrameHostImpl::NoHandler(base::WeakPtr<RenderFrameHostImpl> self,
    base::WeakPtr<Manager> manager, ArxBeforeUnloadRequest request) {
// PRODUCTION_NO_HANDLER
}
int main() {
  for (bool waiting : {true, false}) {
    RenderFrameHostImpl frame, other;
    frame.is_waiting_for_beforeunload_completion_ = waiting;
    int cancelled = 0, completed = 0;
    frame.arx_before_unload_request_ = std::make_shared<base::Callback>([&](auto result) {
      assert(!result); assert(!frame.is_waiting_for_beforeunload_completion_);
      ++cancelled;
    });
    auto old = frame.arx_before_unload_request_;
    assert(RenderFrameHostImpl::ArxBeforeUnloadMatches(&frame, {&frame}, old));
    frame.DispatchOrdinary();
    assert(!frame.arx_before_unload_request_);
    assert(old->is_null());
    assert(cancelled == 0);  // Posted, never reentrant into Chromium's reset stack.
    // The ordinary round is independent and may complete after the old RFH dies.
    Manager manager{&frame};
    RenderFrameHostImpl::NoHandler({}, {&manager}, {});
    assert(manager.completions == 1);
    RenderFrameHostImpl::NoHandler({}, {&manager}, old);
    assert(manager.completions == 1);
    frame.arx_before_unload_request_ = std::make_shared<base::Callback>([&](auto result) {
      assert(result && *result); ++completed;
    });
    auto current = frame.arx_before_unload_request_;
    // A delayed vanilla no-handler completion cannot finish a new owned round.
    RenderFrameHostImpl::NoHandler({}, {&manager}, {});
    RenderFrameHostImpl::NoHandler({&frame}, {&manager}, old);
    assert(manager.completions == 1 && completed == 0);
    // Old renderer, simulated, continuation, no-handler and aggregate tasks
    // all use this exact production predicate before applying their ACK.
    assert(!RenderFrameHostImpl::ArxBeforeUnloadMatches(&frame, {&frame}, old));
    assert(!RenderFrameHostImpl::ArxBeforeUnloadMatches(&frame, {&frame}, {}));
    assert(!RenderFrameHostImpl::ArxBeforeUnloadMatches(&other, {&frame}, current));
    assert(!RenderFrameHostImpl::ArxBeforeUnloadMatches(nullptr, {}, old));
    base::Drain();
    assert(cancelled == 1 && completed == 0);
    assert(RenderFrameHostImpl::ArxBeforeUnloadMatches(&frame, {&frame}, current));
    frame.FinishArxBeforeUnload(true);
    assert(current->is_null());
    assert(completed == 0);
    base::Drain();
    assert(completed == 1);
    assert(!RenderFrameHostImpl::ArxBeforeUnloadMatches(&frame, {&frame}, current));
    assert(RenderFrameHostImpl::ArxBeforeUnloadMatches(&frame, {&frame}, {}));
    // Vanilla no-handler completion remains valid with a surviving manager.
    assert(RenderFrameHostImpl::ArxBeforeUnloadMatches(nullptr, {}, {}));
  }
}
