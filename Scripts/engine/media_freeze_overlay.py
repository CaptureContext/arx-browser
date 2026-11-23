"""Keep actual PiP and exact observed media candidates runnable through PM.

This resource exemption does not authorize entry, create playback or change page
visibility. Anchors intentionally fail closed against the pinned Chromium source.
"""


def apply(source):
    from .overlay import replace_once

    public = source / "components/performance_manager/public/freezing/freezing.h"
    replace_once(public, "class Graph;", "class Graph;\nclass FreezingPolicy;")
    replace_once(public, "// Used to discard frozen pages with growing private memory footprint.", """// Resource-only exemption for one exact PageNode while an embedder observes a
// currently playing video with an automatic PiP handler, or its legitimate
// pending entry. This does not grant PiP, activation, visibility or playback.
// Main-sequence only, matching FreezingVote. Missing PM/policy is a safe no-op.
// Destroying the page or removing the policy makes destruction a no-op; a
// replacement page/policy cannot inherit or lose another object's exemption.
class ScopedMediaRunnableLease {
 public:
  explicit ScopedMediaRunnableLease(content::WebContents* web_contents);
  ~ScopedMediaRunnableLease();
  ScopedMediaRunnableLease(const ScopedMediaRunnableLease&) = delete;
  ScopedMediaRunnableLease& operator=(const ScopedMediaRunnableLease&) = delete;

 private:
  base::WeakPtr<PageNode> page_node_;
  base::WeakPtr<FreezingPolicy> policy_;
};

// Used to discard frozen pages with growing private memory footprint.""")
    implementation = source / "components/performance_manager/freezing/freezing.cc"
    replace_once(implementation, "CanFreezeDetails::CanFreezeDetails() = default;", """ScopedMediaRunnableLease::ScopedMediaRunnableLease(
    content::WebContents* web_contents) {
  if (!PerformanceManager::IsAvailable()) {
    return;
  }
  page_node_ = PerformanceManager::GetPrimaryPageNodeForWebContents(web_contents);
  auto* policy =
      PerformanceManager::GetGraph()->GetRegisteredObjectAs<FreezingPolicy>();
  if (page_node_ && policy) {
    policy_ = policy->GetMediaLeaseWeakPtr();
    policy->AddMediaRunnableLease(page_node_.get());
  }
}

ScopedMediaRunnableLease::~ScopedMediaRunnableLease() {
  if (page_node_ && policy_) {
    policy_->RemoveMediaRunnableLease(page_node_.get());
  }
}

CanFreezeDetails::CanFreezeDetails() = default;""")
    reasons = source / "components/performance_manager/public/freezing/cannot_freeze_reason.h"
    replace_once(reasons, "  kMax = kWebUI,  // Upper bound for EnumSet.", """  kPictureInPicture,
  kMediaRunnableLease,
  kMax = kMediaRunnableLease,  // Upper bound for EnumSet.""")
    strings = source / "components/performance_manager/freezing/cannot_freeze_reason.cc"
    replace_once(strings, '    case CannotFreezeReason::kWebUI:\n      return "WebUI";', '    case CannotFreezeReason::kWebUI:\n      return "WebUI";\n    case CannotFreezeReason::kPictureInPicture:\n      return "picture in picture";\n    case CannotFreezeReason::kMediaRunnableLease:\n      return "observed automatic picture in picture candidate";')
    header = source / "components/performance_manager/freezing/freezing_policy.h"
    replace_once(header, "  // Returns details about whether a page can be frozen.", """  // Exact-page resource exemptions, independently reference counted.
  void AddMediaRunnableLease(PageNode* page_node);
  void RemoveMediaRunnableLease(PageNode* page_node);
  base::WeakPtr<FreezingPolicy> GetMediaLeaseWeakPtr() {
    return media_lease_weak_factory_.GetWeakPtr();
  }

  // Returns details about whether a page can be frozen.""")
    replace_once(header, "  void OnIsVisibleChanged(const PageNode* page_node) override;", """  void OnIsVisibleChanged(const PageNode* page_node) override;
  void OnHasPictureInPictureChanged(const PageNode* page_node) override;""")
    replace_once(header, "  base::WeakPtrFactory<FreezingPolicy> weak_factory_{this};", """  base::WeakPtrFactory<FreezingPolicy> media_lease_weak_factory_{this};
  base::WeakPtrFactory<FreezingPolicy> weak_factory_{this};""")
    policy = source / "components/performance_manager/freezing/freezing_policy.cc"
    replace_once(policy, "  int num_freeze_votes = 0;", """  int num_freeze_votes = 0;

  // Resource-only leases held by exact-page media observers.
  int num_media_runnable_leases = 0;""")
    replace_once(policy, "freezing::CanFreezeDetails FreezingPolicy::GetCanFreezeDetails(", """void FreezingPolicy::AddMediaRunnableLease(PageNode* page_node) {
  if (GetFreezingState(page_node).num_media_runnable_leases++ == 0) {
    OnCannotFreezeReasonChange(page_node, /*add=*/true,
                              CannotFreezeReason::kMediaRunnableLease);
  }
}

void FreezingPolicy::RemoveMediaRunnableLease(PageNode* page_node) {
  auto& count = GetFreezingState(page_node).num_media_runnable_leases;
  CHECK_GT(count, 0);
  if (--count == 0) {
    OnCannotFreezeReasonChange(page_node, /*add=*/false,
                              CannotFreezeReason::kMediaRunnableLease);
  }
}

freezing::CanFreezeDetails FreezingPolicy::GetCanFreezeDetails(""")
    replace_once(policy, "void FreezingPolicy::OnTakenFromGraph(Graph* graph) {", """void FreezingPolicy::OnTakenFromGraph(Graph* graph) {
  // Scopes surviving removal must never decrement a replacement policy.
  media_lease_weak_factory_.InvalidateWeakPtrs();
  for (const auto* page_node : graph->GetAllPageNodes()) {
    auto& state = GetFreezingState(page_node);
    if (state.num_media_runnable_leases != 0) {
      state.num_media_runnable_leases = 0;
      OnCannotFreezeReasonChange(page_node, /*add=*/false,
                                CannotFreezeReason::kMediaRunnableLease);
    }
  }""")
    replace_once(policy, "  if (page_node->IsAudible()) {\n    page_freezing_state.cannot_freeze_reasons.Put(CannotFreezeReason::kAudible);\n  }", """  if (page_node->IsAudible()) {
    page_freezing_state.cannot_freeze_reasons.Put(CannotFreezeReason::kAudible);
  }

  if (page_node->HasPictureInPicture()) {
    page_freezing_state.cannot_freeze_reasons.Put(
        CannotFreezeReason::kPictureInPicture);
  }""")
    replace_once(policy, "void FreezingPolicy::OnIsAudibleChanged(const PageNode* page_node) {", """void FreezingPolicy::OnHasPictureInPictureChanged(const PageNode* page_node) {
  OnCannotFreezeReasonChange(page_node, page_node->HasPictureInPicture(),
                            CannotFreezeReason::kPictureInPicture);
}

void FreezingPolicy::OnIsAudibleChanged(const PageNode* page_node) {""")

    # Reuse upstream's real graph fixtures and strict Freezer expectations.
    from .config import PACKAGE
    tests = source / "components/performance_manager/freezing/freezing_policy_unittest.cc"
    basic_marker = "// A page with no `CannotFreezeReason` that is alone in its browsing instance is"
    replace_once(tests, basic_marker,
                 (PACKAGE / "Native/media_freeze_unittests.inc").read_text() + "\n" + basic_marker)
    infinite_marker = "TEST_F(FreezingPolicyInfiniteTabsTest, ManyVisibleTabs) {"
    replace_once(tests, infinite_marker,
                 (PACKAGE / "Native/media_freeze_infinite_tabs_unittest.inc").read_text() + "\n" + infinite_marker)
