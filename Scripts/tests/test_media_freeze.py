"""Execute extracted production lease/policy/cleanup code without Chromium UI.

The graph/freezer integration is covered separately by the four native tests
injected into Chromium's real FreezingPolicy test translation unit.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.config import PACKAGE
from Scripts.engine.media_freeze_overlay import apply


PREFIX = "components/performance_manager/"
FIXTURES = {
    "public/freezing/freezing.h": """class Graph;
// Used to discard frozen pages with growing private memory footprint.
""",
    "freezing/freezing.cc": "CanFreezeDetails::CanFreezeDetails() = default;\n",
    "public/freezing/cannot_freeze_reason.h": "  kMax = kWebUI,  // Upper bound for EnumSet.\n",
    "freezing/cannot_freeze_reason.cc": """    case CannotFreezeReason::kWebUI:
      return "WebUI";
""",
    "freezing/freezing_policy.h": """  // Returns details about whether a page can be frozen.
  void OnIsVisibleChanged(const PageNode* page_node) override;
  base::WeakPtrFactory<FreezingPolicy> weak_factory_{this};
""",
    "freezing/freezing_policy.cc": """  int num_freeze_votes = 0;
freezing::CanFreezeDetails FreezingPolicy::GetCanFreezeDetails(
void FreezingPolicy::OnTakenFromGraph(Graph* graph) {
}
  if (page_node->IsAudible()) {
    page_freezing_state.cannot_freeze_reasons.Put(CannotFreezeReason::kAudible);
  }
void FreezingPolicy::OnIsAudibleChanged(const PageNode* page_node) {
""",
    "freezing/freezing_policy_unittest.cc": """// A page with no `CannotFreezeReason` that is alone in its browsing instance is
TEST_F(FreezingPolicyInfiniteTabsTest, ManyVisibleTabs) {
""",
}


def method(source, marker):
    """Extract an exact function body using brace depth, preserving its logic."""
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class MediaFreezeTests(unittest.TestCase):
    def fixture(self, root):
        for name, text in FIXTURES.items():
            path = root / PREFIX / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def test_overlay_is_idempotent_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            apply(root)
            first = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
            apply(root)
            self.assertEqual(first, {p: p.read_bytes() for p in root.rglob("*") if p.is_file()})
            public = root / PREFIX / "public/freezing/freezing.h"
            public.write_text("unexpected upstream source")
            with self.assertRaisesRegex(ValueError, "anchor changed"):
                apply(root)

    def test_extracted_reference_counts_weak_scopes_and_native_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            apply(root)
            policy = (root / PREFIX / "freezing/freezing_policy.cc").read_text()
            implementation = (root / PREFIX / "freezing/freezing.cc").read_text()
            public = (root / PREFIX / "public/freezing/freezing.h").read_text()
            bridge = (PACKAGE / "Native/media_bridge.mm").read_text()
            program = HARNESS
            replacements = {
                "LEASE_DECLARATION": method(public, "class ScopedMediaRunnableLease") + ";",
                "LEASE_CONSTRUCTOR": method(implementation, "ScopedMediaRunnableLease::ScopedMediaRunnableLease("),
                "LEASE_DESTRUCTOR": method(implementation, "ScopedMediaRunnableLease::~ScopedMediaRunnableLease()"),
                "ADD_METHOD": method(policy, "void FreezingPolicy::AddMediaRunnableLease("),
                "REMOVE_METHOD": method(policy, "void FreezingPolicy::RemoveMediaRunnableLease("),
                "PIP_METHOD": method(policy, "void FreezingPolicy::OnHasPictureInPictureChanged("),
                "TAKEN_METHOD": method(policy, "void FreezingPolicy::OnTakenFromGraph("),
                "UPDATE_METHOD": method(bridge, "void UpdateMediaRunnableLease("),
                "COMPLETE_METHOD": method(bridge, "void Complete("),
                "INVALIDATE_PREFIX": method(bridge, "void Invalidate(").split(
                    "    if (exit_picture) {\n      base::", 1)[0] + "}",
            }
            for token, text in replacements.items():
                program = program.replace(token, text)
            source = root / "contract.cc"
            source.write_text(program)
            binary = root / "contract"
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                            "-I", str(PACKAGE / "Native"), str(source), "-o", str(binary)],
                           check=True, capture_output=True, timeout=30)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=10)

    def test_entry_checks_and_pre_hide_refresh_remain(self):
        bridge = (PACKAGE / "Native/media_bridge.mm").read_text()
        entry = method(bridge, "content::PictureInPictureResult Enter()")
        self.assertIn("!Supported(action_)", entry)
        self.assertIn("request_generation_ != value_.generation", entry)
        self.assertIn("IsOffTheRecord()", entry)
        before_hide = method(bridge, "void OnVisibilityWillChange(")
        self.assertIn("Refresh();", before_hide)
        invalidation = method(bridge, "void Invalidate(")
        self.assertLess(invalidation.index("media_runnable_lease_.reset()"),
                        invalidation.index("ScheduleRefresh()"))
        refresh = method(bridge, "void Refresh()")
        self.assertIn("UpdateMediaRunnableLease(next, automatic_handler);", refresh)
        self.assertIn("next.playback == 1 && has(SessionAction::kEnterAutoPictureInPicture)", refresh)


# Stubs replace ownership/scheduling infrastructure only. Lease implementation,
# reference-count transitions, PiP observer, bridge lease selection and terminal
# cleanup above are extracted verbatim from production. This does not pretend to
# run PM's full connected-page/MRU graph; the injected Chromium tests do that.
HARNESS = r"""
#include <cassert>
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>
#include "media_freeze_policy.h"
#define CHECK_GT(a,b) assert((a)>(b))
namespace base {
template <class T> class WeakPtr {
 public:
  WeakPtr() = default;
  WeakPtr(T* object, std::weak_ptr<int> lifetime) : object_(object), lifetime_(lifetime) {}
  explicit operator bool() const { return !lifetime_.expired(); }
  T* get() const { return *this ? object_ : nullptr; }
  T* operator->() const { return get(); }
 private:
  T* object_ = nullptr;
  std::weak_ptr<int> lifetime_;
};
}
namespace content {
struct BrowserContext { bool private_mode = false; bool IsOffTheRecord() const { return private_mode; } };
struct WebContents {
  BrowserContext context;
  BrowserContext* GetBrowserContext() { return &context; }
};
}
namespace performance_manager {
struct PageNode {
  int num_media_runnable_leases = 0;
  bool picture = false, lease_reason = false, picture_reason = false;
  bool HasPictureInPicture() const { return picture; }
  std::shared_ptr<int> lifetime = std::make_shared<int>(0);
  base::WeakPtr<PageNode> weak() { return {this, lifetime}; }
};
namespace freezing { enum class CannotFreezeReason { kMediaRunnableLease, kPictureInPicture }; }
using freezing::CannotFreezeReason;
struct Graph;
class FreezingPolicy {
 public:
  std::shared_ptr<int> lifetime = std::make_shared<int>(0);
  struct Factory {
    std::shared_ptr<int>& lifetime;
    void InvalidateWeakPtrs() { lifetime = std::make_shared<int>(0); }
  } media_lease_weak_factory_{lifetime};
  int transitions = 0;
  base::WeakPtr<FreezingPolicy> GetMediaLeaseWeakPtr() { return {this, lifetime}; }
  PageNode& GetFreezingState(const PageNode* page) { return *const_cast<PageNode*>(page); }
  void OnCannotFreezeReasonChange(const PageNode* page, bool add, CannotFreezeReason reason) {
    ++transitions;
    if (reason == CannotFreezeReason::kMediaRunnableLease)
      const_cast<PageNode*>(page)->lease_reason = add;
    else const_cast<PageNode*>(page)->picture_reason = add;
  }
  void AddMediaRunnableLease(PageNode*);
  void RemoveMediaRunnableLease(PageNode*);
  void OnHasPictureInPictureChanged(const PageNode*);
  void OnTakenFromGraph(Graph*);
};
ADD_METHOD
REMOVE_METHOD
PIP_METHOD
struct Graph {
  FreezingPolicy* policy = nullptr;
  std::vector<const PageNode*> pages;
  std::vector<const PageNode*> GetAllPageNodes() { return pages; }
  template <class T> T* GetRegisteredObjectAs() { return policy; }
};
TAKEN_METHOD
struct PerformanceManager {
  static inline bool available = true;
  static inline PageNode* page = nullptr;
  static inline Graph graph;
  static bool IsAvailable() { return available; }
  static Graph* GetGraph() { assert(available); return &graph; }
  static base::WeakPtr<PageNode> GetPrimaryPageNodeForWebContents(content::WebContents*) {
    return page ? page->weak() : base::WeakPtr<PageNode>();
  }
};
namespace freezing {
LEASE_DECLARATION
LEASE_CONSTRUCTOR
LEASE_DESTRUCTOR
}
}
using performance_manager::freezing::ScopedMediaRunnableLease;
enum ArxMediaAction { ARX_MEDIA_PLAY, ARX_MEDIA_ENTER_PICTURE, ARX_MEDIA_ENTER_AUTOMATIC_PICTURE };
enum ArxMediaStatus { ARX_MEDIA_SUCCESS, ARX_MEDIA_STALE, ARX_MEDIA_TIMEOUT, ARX_MEDIA_CANCELLED };
namespace arx {
struct Value { uint64_t generation = 1; bool present = true, video = true, picture = false; int playback = 1; };
struct Observer {
  content::WebContents contents;
  bool crashed_ = false, awaiting_player_ = false, entry_quarantined_ = false;
  uint64_t request_ = 0, request_generation_ = 1;
  Value value_;
  ArxMediaAction action_ = ARX_MEDIA_PLAY;
  struct Timer { void Stop() {} } timeout_, seek_poll_;
  std::unique_ptr<ScopedMediaRunnableLease> media_runnable_lease_;
  content::WebContents* web_contents() { return &contents; }
  void ScheduleRefresh() {}
  void Reply(uint64_t, ArxMediaStatus) {}
  bool IsEntry(ArxMediaAction action) { return action != ARX_MEDIA_PLAY; }
  UPDATE_METHOD
  COMPLETE_METHOD
  INVALIDATE_PREFIX
};
}
int main() {
  using namespace performance_manager;
  content::WebContents contents;
  FreezingPolicy policy;
  PageNode page;
  PerformanceManager::page = &page;
  PerformanceManager::graph.policy = &policy;
  {
    ScopedMediaRunnableLease first(&contents);
    assert(page.num_media_runnable_leases == 1 && page.lease_reason);
    assert(policy.transitions == 1);
    {
      ScopedMediaRunnableLease second(&contents);
      assert(page.num_media_runnable_leases == 2 && policy.transitions == 1);
    }
    assert(page.num_media_runnable_leases == 1 && page.lease_reason);
    page.picture = true;
    policy.OnHasPictureInPictureChanged(&page);
  }
  assert(page.num_media_runnable_leases == 0 && !page.lease_reason && page.picture_reason);
  page.picture = false;
  policy.OnHasPictureInPictureChanged(&page);
  assert(!page.picture_reason);
  // Page destruction revokes its weak identity; a new primary page is untouched.
  auto old_page = std::make_unique<PageNode>();
  PerformanceManager::page = old_page.get();
  auto stale = std::make_unique<ScopedMediaRunnableLease>(&contents);
  old_page.reset();
  PerformanceManager::page = &page;
  stale.reset();
  assert(page.num_media_runnable_leases == 0);
  // Removing a live policy revokes leases independently of page lifetime.
  auto old_policy = std::make_unique<FreezingPolicy>();
  PerformanceManager::graph.policy = old_policy.get();
  stale = std::make_unique<ScopedMediaRunnableLease>(&contents);
  PerformanceManager::graph.pages = {&page};
  old_policy->OnTakenFromGraph(&PerformanceManager::graph);
  assert(page.num_media_runnable_leases == 0 && !page.lease_reason);
  PerformanceManager::graph.policy = &policy;
  auto current = std::make_unique<ScopedMediaRunnableLease>(&contents);
  int before = page.num_media_runnable_leases;
  stale.reset();
  assert(page.num_media_runnable_leases == before);
  current.reset();
  assert(page.num_media_runnable_leases == 0 && !page.lease_reason);
  PerformanceManager::available = false;
  { ScopedMediaRunnableLease missing(&contents); }
  PerformanceManager::available = true;
  PerformanceManager::page = nullptr;
  { ScopedMediaRunnableLease missing(&contents); }
  PerformanceManager::page = &page;
  PerformanceManager::graph.policy = nullptr;
  { ScopedMediaRunnableLease missing(&contents); }
  PerformanceManager::graph.policy = &policy;
  // Every eligibility term denies independently; pending cannot bypass any.
  arx::MediaRunnableFacts facts{true, true, true, true, true, false, false};
  assert(arx::NeedsMediaRunnableLease(facts));
  for (int field = 0; field < 5; ++field) {
    auto invalid = facts;
    switch(field) {
      case 0: invalid.ordinary = false; break;
      case 1: invalid.valid_source = false; break;
      case 2: invalid.video = false; break;
      case 3: invalid.playing = false; break;
      case 4: invalid.automatic_handler = false; break;
    }
    invalid.pending_automatic_entry = true;
    assert(!arx::NeedsMediaRunnableLease(invalid));
  }
  facts.picture = true;
  assert(!arx::NeedsMediaRunnableLease(facts));
  facts.pending_automatic_entry = true;
  assert(arx::NeedsMediaRunnableLease(facts));
  for (int denial = 0; denial < 8; ++denial) {
    arx::Observer observer;
    arx::Value value;
    observer.UpdateMediaRunnableLease(value, true);
    assert(page.num_media_runnable_leases == 1);
    switch(denial) {
      case 0: observer.contents.context.private_mode = true; break;
      case 1: observer.crashed_ = true; break;
      case 2: observer.awaiting_player_ = true; break;
      case 3: observer.entry_quarantined_ = true; break;
      case 4: value.present = false; break;
      case 5: value.video = false; break;
      case 6: value.playback = 2; break;
      case 7: break;
    }
    observer.UpdateMediaRunnableLease(value, denial != 7);
    assert(page.num_media_runnable_leases == 0);
  }
  for (auto status : {ARX_MEDIA_TIMEOUT, ARX_MEDIA_CANCELLED, ARX_MEDIA_STALE}) {
    arx::Observer observer;
    observer.UpdateMediaRunnableLease(observer.value_, true);
    observer.action_ = ARX_MEDIA_ENTER_AUTOMATIC_PICTURE;
    observer.request_ = 1;
    observer.Complete(status);
    assert(observer.entry_quarantined_ && page.num_media_runnable_leases == 0);
    observer.UpdateMediaRunnableLease(observer.value_, true);
    assert(page.num_media_runnable_leases == 0);
  }
  {
    arx::Observer observer;
    observer.UpdateMediaRunnableLease(observer.value_, true);
    int before = policy.transitions;
    observer.Invalidate(false);
    assert(page.num_media_runnable_leases == 1 && policy.transitions == before);
    observer.UpdateMediaRunnableLease(observer.value_, true);
    assert(page.num_media_runnable_leases == 1 && policy.transitions == before);
    observer.Invalidate(true);
    assert(page.num_media_runnable_leases == 0);
  }
  {
    arx::Observer observer;
    observer.UpdateMediaRunnableLease(observer.value_, true);
    observer.action_ = ARX_MEDIA_ENTER_AUTOMATIC_PICTURE;
    observer.request_ = 1;
    observer.value_.picture = true;
    observer.UpdateMediaRunnableLease(observer.value_, true);
    assert(page.num_media_runnable_leases == 1);
    observer.Complete(ARX_MEDIA_SUCCESS);
    assert(!observer.entry_quarantined_ && page.num_media_runnable_leases == 0);
  }
  {
    arx::Observer observer;
    observer.UpdateMediaRunnableLease(observer.value_, true);
    assert(page.num_media_runnable_leases == 1);
  }
  assert(page.num_media_runnable_leases == 0);
}
"""
