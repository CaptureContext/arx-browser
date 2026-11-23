#ifndef ARX_BATTERY_SAVER_BRIDGE_H_
#define ARX_BATTERY_SAVER_BRIDGE_H_

#include <cstdint>

// DEV-915 Battery Saver, exported outside the ABI table so engines built before
// it still load (ChromiumOptionalExports.swift looks them up). Main thread,
// once the engine runs.

// Whether Battery Saver is on now: it throttles background timers and frame
// rates and freezes background tabs, as Chrome's Energy Saver does.
typedef void (*ArxBatterySaverHandler)(void* context, bool active);

extern "C" {
// Sets Chrome's local-state pref performance_tuning.battery_saver_mode.state:
// 0 never, 1 when the battery is low (Chrome's 20%), 2 on battery power, 3
// always. The app sends 3 while macOS Low Power Mode is on. False before the
// engine runs, for another value, or while policy manages the pref.
__attribute__((visibility("default")))
bool ArxEngineSetBatterySaverMode(int32_t state);

// Whether Battery Saver is active now.
__attribute__((visibility("default")))
bool ArxEngineBatterySaverIsActive();

// Sets or clears (NULL) the one handler that hears Battery Saver turn on and
// off, after a posted task. False before the engine's manager exists.
__attribute__((visibility("default")))
bool ArxEngineObserveBatterySaver(ArxBatterySaverHandler handler, void* context);
}

#endif  // ARX_BATTERY_SAVER_BRIDGE_H_
