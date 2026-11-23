#include "chrome/browser/arx/battery_saver_bridge.h"

#import <Foundation/Foundation.h>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/performance_manager/public/user_tuning/battery_saver_mode_manager.h"
#include "components/performance_manager/public/user_tuning/prefs.h"
#include "components/prefs/pref_service.h"

namespace arx {
namespace {

using performance_manager::user_tuning::BatterySaverModeManager;
namespace tuning_prefs = performance_manager::user_tuning::prefs;

// Reports Battery Saver turning on and off to the app's handler.
class BatterySaverObserver final : public BatterySaverModeManager::Observer {
 public:
  void Set(ArxBatterySaverHandler handler, void* context) {
    handler_ = handler;
    context_ = context;
    auto* manager = BatterySaverModeManager::GetInstance();
    if (handler_ && !observing_) {
      manager->AddObserver(this);
      observing_ = true;
    } else if (!handler_ && observing_) {
      manager->RemoveObserver(this);
      observing_ = false;
    }
  }

  void OnBatterySaverActiveChanged(bool is_active) override {
    // Posted: the app never runs inside the manager's notification.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&BatterySaverObserver::Report, is_active));
  }

  void OnBatterySaverModeManagerDestroyed() override {
    observing_ = false;
    handler_ = nullptr;
    context_ = nullptr;
  }

 private:
  static void Report(bool is_active);

  ArxBatterySaverHandler handler_ = nullptr;
  void* context_ = nullptr;
  bool observing_ = false;
};

BatterySaverObserver& SharedBatterySaverObserver() {
  static base::NoDestructor<BatterySaverObserver> observer;
  return *observer;
}

void BatterySaverObserver::Report(bool is_active) {
  auto& observer = SharedBatterySaverObserver();
  if (observer.handler_) observer.handler_(observer.context_, is_active);
}

}  // namespace
}  // namespace arx

extern "C" __attribute__((visibility("default")))
bool ArxEngineSetBatterySaverMode(int32_t state) {
  CHECK([NSThread isMainThread]);
  if (state < static_cast<int32_t>(arx::tuning_prefs::BatterySaverModeState::kDisabled) ||
      state > static_cast<int32_t>(arx::tuning_prefs::BatterySaverModeState::kEnabled)) {
    return false;
  }
  PrefService* local_state = g_browser_process ? g_browser_process->local_state() : nullptr;
  if (!local_state) return false;
  if (local_state->IsManagedPreference(arx::tuning_prefs::kBatterySaverModeState)) return false;
  local_state->SetInteger(arx::tuning_prefs::kBatterySaverModeState, state);
  return true;
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineBatterySaverIsActive() {
  CHECK([NSThread isMainThread]);
  return arx::BatterySaverModeManager::HasInstance() &&
         arx::BatterySaverModeManager::GetInstance()->IsBatterySaverActive();
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineObserveBatterySaver(ArxBatterySaverHandler handler, void* context) {
  CHECK([NSThread isMainThread]);
  if (!arx::BatterySaverModeManager::HasInstance()) return false;
  arx::SharedBatterySaverObserver().Set(handler, context);
  return true;
}
