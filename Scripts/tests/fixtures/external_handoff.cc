#include <cassert>
#include <functional>
#include <map>
#include <memory>
#include <vector>
#include "external_handoff_authority.h"
#define FROM_HERE 0
namespace base {
template <class T> class WeakPtr {
 public:
  T* value = nullptr;
  std::weak_ptr<int> lifetime;
  explicit operator bool() const { return value && !lifetime.expired(); }
  T* operator->() const { assert(*this); return value; }
  T* get() const { return *this ? value : nullptr; }
};
template <class T> class WeakPtrFactory {
 public:
  T* value;
  std::shared_ptr<int> lifetime = std::make_shared<int>(0);
  explicit WeakPtrFactory(T* owner) : value(owner) {}
  WeakPtr<T> GetWeakPtr() { return {value, lifetime}; }
  void InvalidateWeakPtrs() { lifetime.reset(); }
};
std::vector<std::function<void()>> tasks;
struct SingleThreadTaskRunner {
  static SingleThreadTaskRunner* GetCurrentDefault() { static SingleThreadTaskRunner runner; return &runner; }
  void PostTask(int, std::function<void()> task) { tasks.push_back(std::move(task)); }
};
template <class F, class T> auto BindOnce(F function, WeakPtr<T> owner) {
  return [function, owner] { function(owner); };
}
struct TimeTicks { static int now; static int Now() { return now; } };
int TimeTicks::now = 0;
}  // namespace base
struct Timer { bool stopped = false; void Stop() { stopped = true; } };
struct Guard { bool* valid; bool Run() const { return *valid; } };
struct Document { int* frame; int* AsRenderFrameHostIfValid() const { return frame; } };
struct Contents { int frame; int* GetPrimaryMainFrame() { return &frame; } };
class ExternalChild {
 public:
  using Owners = std::map<uint64_t, std::unique_ptr<ExternalChild>>;
  static Owners& Pending() { static Owners owners; return owners; }
  static int physical, destroyed;
  ExternalChild(uint64_t id, bool* source) : id_(id), source_{source}, initial_{&contents_->frame} { ++physical; }
  ~ExternalChild() { weak_factory_.InvalidateWeakPtrs(); --physical; ++destroyed; }
  // PRODUCTION_FINISH
  // PRODUCTION_CURRENT
  // PRODUCTION_CHECK
  uint64_t id_;
  std::unique_ptr<Contents> contents_ = std::make_unique<Contents>();
  Guard source_;
  Document initial_;
  arx::ExternalHandoffAuthority authority_;
  bool terminal_ = false;
  int deadline_ = 30;
  Timer timer_;
  base::WeakPtrFactory<ExternalChild> weak_factory_{this};
};
int ExternalChild::physical = 0;
int ExternalChild::destroyed = 0;
void Drain() {
  while (!base::tasks.empty()) {
    auto tasks = std::move(base::tasks); base::tasks.clear();
    for (auto& task : tasks) task();
  }
}
ExternalChild* Own(uint64_t id, bool* source) {
  auto owner = std::make_unique<ExternalChild>(id, source);
  auto* result = owner.get(); ExternalChild::Pending().emplace(id, std::move(owner)); return result;
}
int main() {
  using Authority = arx::ExternalHandoffAuthority;
  for (int invalid = 0; invalid < 4; ++invalid) {
    Authority authority;
    assert(!authority.BeginNavigation(invalid == 0 ? 0 : 1, invalid != 1, invalid == 2, invalid != 3));
    assert(!authority.live() && !authority.ProtocolStarted());
  }
  {
    Authority authority;
    assert(authority.BeginNavigation(12, true, false, true));
    assert(authority.ProtocolStarted());
    assert(!authority.NavigationFinished(12, false));  // Chrome ERR_ABORTED with pending dialog.
    assert(authority.deciding());
    assert(authority.Finish()); assert(!authority.Finish());
    assert(!authority.ProtocolStarted() && !authority.BeginNavigation(12, true, false, true));
  }
  for (bool protocol : {false, true}) {
    Authority authority;
    assert(authority.BeginNavigation(12, true, false, true));
    if (protocol) assert(authority.ProtocolStarted());
    assert(authority.NavigationFinished(12, true));  // No hidden committed browsing.
  }
  {
    Authority authority;
    assert(authority.BeginNavigation(1, true, false, true));
    assert(authority.NavigationFinished(1, false));  // Rejected before protocol handler.
  }
  {
    Authority authority;
    assert(authority.BeginNavigation(1, true, false, true)); assert(authority.ProtocolStarted());
    assert(!authority.BeginNavigation(2, true, false, true));  // No redirected or replacement request.
  }
  bool source = true;
  auto* first = Own(1, &source);
  assert(first->Current());
  first->Finish(); first->Finish();
  assert(first->terminal_ && first->timer_.stopped && !first->Current());
  assert(ExternalChild::physical == 1 && ExternalChild::destroyed == 0 && base::tasks.size() == 1);
  Drain(); assert(ExternalChild::physical == 0 && ExternalChild::destroyed == 1);
  // Old queued completion cannot destroy a replacement, even with the same ID.
  auto* old = Own(2, &source); old->Finish();
  ExternalChild::Pending().erase(2);
  auto* replacement = Own(2, &source);
  Drain(); assert(ExternalChild::Pending().at(2).get() == replacement && replacement->Current());
  // Losing and recovering the source before physical cleanup cannot revive it.
  source = false; replacement->CheckSource(); source = true;
  assert(!replacement->Current() && ExternalChild::physical == 1);
  Drain(); assert(ExternalChild::physical == 0);
  auto* timeout = Own(3, &source); base::TimeTicks::now = 30; timeout->CheckSource();
  assert(timeout->terminal_); Drain();
  auto* changed = Own(4, &source); changed->initial_.frame = nullptr; changed->CheckSource();
  assert(changed->terminal_); Drain();
  auto* shutdown = Own(5, &source); shutdown->Finish();
  ExternalChild::Pending().clear(); Drain(); assert(ExternalChild::physical == 0);
}
