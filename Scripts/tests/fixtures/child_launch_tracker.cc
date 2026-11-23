#include "profile_erasure/child_launch_tracker.h"

#include <cassert>
#include <iostream>
#include <thread>

using arx::erasure::ChildIdentity;
using arx::erasure::ChildLaunchTracker;

int main() {
  int owner = 0, vanished_owner = 0, failed = 0, unknown = 0;
  {
    ChildLaunchTracker tracker;
    tracker.StartLaunch(&owner);
    assert(!tracker.FinishObservation().complete);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    tracker.StartLaunch(&vanished_owner);
    // An absent weak host does not lose the launch token or its exact identity.
    tracker.Launched(&vanished_owner, {91, 100, 200});
    const auto result = tracker.FinishObservation();
    assert(result.complete && result.identities.size() == 1);
    assert((result.identities[0] == ChildIdentity{91, 100, 200}));
    assert(!tracker.FinishObservation().complete);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    tracker.StartLaunch(&owner);
    // Missing post reply, or a launch still outstanding at native shutdown.
    assert(!tracker.FinishObservation().complete);
    tracker.Launched(&owner, {91, 100, 200});
    assert(!tracker.FinishObservation().complete);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    tracker.StartLaunch(&failed);
    tracker.DidNotLaunch(&failed);
    assert(tracker.FinishObservation().complete);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    tracker.StartLaunch(&unknown);
    tracker.Unknown(&unknown);
    assert(!tracker.FinishObservation().complete);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    tracker.StartLaunch(&owner);
    tracker.Launched(&owner, {0, 100, 200});
    assert(!tracker.FinishObservation().complete);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    tracker.StartLaunch(&owner);
    tracker.StartLaunch(&owner);
    tracker.DidNotLaunch(&owner);
    assert(!tracker.FinishObservation().complete);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    tracker.Launched(&owner, {91, 100, 200});
    assert(!tracker.FinishObservation().complete);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    tracker.StartLaunch(&owner);
    tracker.Launched(&owner, {91, 100, 200});
    tracker.StartLaunch(&owner);
    tracker.Launched(&owner, {91, 100, 201});
    const auto result = tracker.FinishObservation();
    // PID reuse is a distinct process, not deduplicated by PID alone.
    assert(result.complete && result.identities.size() == 2);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    for (size_t i = 0; i <= ChildLaunchTracker::kMaximumChildren; ++i) {
      tracker.StartLaunch(&owner);
      tracker.Launched(&owner, {static_cast<int32_t>(i + 1), 100, 200});
    }
    const auto result = tracker.FinishObservation();
    assert(!result.complete);
    assert(result.identities.size() == ChildLaunchTracker::kMaximumChildren);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    int tokens[ChildLaunchTracker::kMaximumChildren + 1] = {};
    for (auto& token : tokens) tracker.StartLaunch(&token);
    for (auto& token : tokens) tracker.DidNotLaunch(&token);
    assert(!tracker.FinishObservation().complete);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    int tokens[128] = {};
    std::vector<std::thread> workers;
    for (int worker = 0; worker < 8; ++worker) {
      workers.emplace_back([&, worker] {
        for (int index = worker; index < 128; index += 8) {
          tracker.StartLaunch(&tokens[index]);
          tracker.Launched(&tokens[index], {index + 1, 100, 200});
        }
      });
    }
    for (auto& worker : workers) worker.join();
    const auto result = tracker.FinishObservation();
    assert(result.complete && result.identities.size() == 128);
  }
  {
    ChildLaunchTracker tracker;
    tracker.StartObservation();
    tracker.StartObservation();
    assert(!tracker.FinishObservation().complete);
  }
  std::cout << "ARX_ERASURE_LAUNCH_POLICY_SUCCESS 13 scenarios\n";
}
