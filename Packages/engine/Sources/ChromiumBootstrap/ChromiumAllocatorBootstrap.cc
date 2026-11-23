#include "include/ChromiumBootstrap.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "base/allocator/early_zone_registration_apple.h"
#include "partition_alloc/shim/early_zone_registration_utils_apple.h"

namespace {

// Access only on the main thread. No dynamic initializer or allocator is used.
bool prepared = false;
bool framework_loaded = false;

bool Named(const ArxBootstrapState& state, const char* name) {
  return strcmp(state.default_zone_name, name) == 0;
}

bool Readable(const ArxBootstrapState& state) {
  return state.thread_status == KERN_SUCCESS && state.zone_status == KERN_SUCCESS &&
         state.thread_count > 0 && state.zone_count > 0;
}

void SmokeMarker(const char* marker) {
  // The Settings acceptance runner deliberately omits the app smoke title.
  const char* title = getenv("ARX_ENGINE_SMOKE_TITLE");
  const char* settings = getenv("ARX_EXTENSION_SETTINGS_SMOKE_ROOT");
  if ((title && title[0]) || (settings && settings[0]))
    (void)write(STDERR_FILENO, marker, strlen(marker));
}

}  // namespace

ArxBootstrapStatus ArxPrepareAllocator(void) {
  if (!pthread_main_np()) return ARX_BOOTSTRAP_WRONG_THREAD;
  const auto state = ArxReadBootstrapState();
  if (!Readable(state)) return ARX_BOOTSTRAP_INSPECTION_FAILED;
  if (prepared) {
    return Named(state, framework_loaded ? allocator_shim::kPartitionAllocZoneName.data()
                                       : allocator_shim::kDelegatingZoneName.data())
               ? ARX_BOOTSTRAP_OK : ARX_BOOTSTRAP_UNEXPECTED_ZONE;
  }
  if (state.thread_count != 1) return ARX_BOOTSTRAP_MULTITHREADED;
  if (allocator_shim::IsZoneAlreadyRegistered(allocator_shim::kDelegatingZoneName) ||
      allocator_shim::IsZoneAlreadyRegistered(allocator_shim::kPartitionAllocZoneName)) {
    return ARX_BOOTSTRAP_ALREADY_REGISTERED;
  }

  // Exact upstream implementation. Its unregister/register sequence is only
  // safe here, before any other thread can concurrently free an allocation.
  partition_alloc::EarlyMallocZoneRegistration();
  const auto installed = ArxReadBootstrapState();
  if (!Readable(installed) ||
      !Named(installed, allocator_shim::kDelegatingZoneName.data())) {
    return ARX_BOOTSTRAP_UNEXPECTED_ZONE;
  }
  prepared = true;
  SmokeMarker("ARX_BOOTSTRAP_REGISTERED\n");
  return ARX_BOOTSTRAP_OK;
}

ArxBootstrapStatus ArxVerifyBeforeFrameworkLoad(void) {
  if (!pthread_main_np()) return ARX_BOOTSTRAP_WRONG_THREAD;
  if (!prepared) return ARX_BOOTSTRAP_NOT_PREPARED;
  if (framework_loaded) return ARX_BOOTSTRAP_ALREADY_REGISTERED;
  const auto state = ArxReadBootstrapState();
  if (!Readable(state)) return ARX_BOOTSTRAP_INSPECTION_FAILED;
  return Named(state, allocator_shim::kDelegatingZoneName.data())
             ? ARX_BOOTSTRAP_OK : ARX_BOOTSTRAP_UNEXPECTED_ZONE;
}

ArxBootstrapStatus ArxVerifyAfterFrameworkLoad(void) {
  if (!pthread_main_np()) return ARX_BOOTSTRAP_WRONG_THREAD;
  if (!prepared) return ARX_BOOTSTRAP_NOT_PREPARED;
  const auto state = ArxReadBootstrapState();
  if (!Readable(state)) return ARX_BOOTSTRAP_INSPECTION_FAILED;
  if (!Named(state, allocator_shim::kPartitionAllocZoneName.data()) ||
      allocator_shim::IsZoneAlreadyRegistered(allocator_shim::kDelegatingZoneName)) {
    return ARX_BOOTSTRAP_UNEXPECTED_ZONE;
  }
  framework_loaded = true;
  SmokeMarker("ARX_BOOTSTRAP_FRAMEWORK_VERIFIED\n");
  return ARX_BOOTSTRAP_OK;
}

const char* ArxBootstrapStatusDescription(ArxBootstrapStatus status) {
  switch (status) {
    case ARX_BOOTSTRAP_OK: return "Allocator startup verified.";
    case ARX_BOOTSTRAP_WRONG_THREAD: return "Allocator startup must run on the main thread.";
    case ARX_BOOTSTRAP_MULTITHREADED: return "Allocator startup refused because the process already has multiple threads.";
    case ARX_BOOTSTRAP_INSPECTION_FAILED: return "Allocator startup could not inspect process threads and malloc zones.";
    case ARX_BOOTSTRAP_ALREADY_REGISTERED: return "A Chromium allocator zone was already registered outside the expected startup sequence.";
    case ARX_BOOTSTRAP_UNEXPECTED_ZONE: return "The default allocator zone does not match the expected Chromium startup phase.";
    case ARX_BOOTSTRAP_NOT_PREPARED: return "The host must prepare the allocator at first entry before loading Chromium.";
  }
  return "Unknown allocator startup failure.";
}

bool ArxPrepareAllocatorAndReportFailure(void) {
  const auto status = ArxPrepareAllocator();
  if (status == ARX_BOOTSTRAP_OK) return true;
  static const char prefix[] = "Arx startup stopped: ";
  const char* message = ArxBootstrapStatusDescription(status);
  (void)write(STDERR_FILENO, prefix, sizeof(prefix) - 1);
  (void)write(STDERR_FILENO, message, strlen(message));
  (void)write(STDERR_FILENO, "\n", 1);
  return false;
}
