#include "ChromiumBootstrap.h"
#include "base/allocator/early_zone_registration_apple.h"
#include "partition_alloc/shim/early_zone_registration_utils_apple.h"

#include <assert.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static ArxBootstrapStatus worker_status;

static void* Worker(void* prepare) {
  if (prepare) worker_status = ArxPrepareAllocator();
  pthread_mutex_lock(&lock);
  pthread_mutex_unlock(&lock);
  return nullptr;
}

int main(int argc, char** argv) {
  assert(argc == 2);
  const auto initial = ArxReadBootstrapState();
  assert(initial.thread_status == 0 && initial.zone_status == 0);
  assert(initial.thread_count == 1 && initial.is_main_thread);
  assert(ArxVerifyBeforeFrameworkLoad() == ARX_BOOTSTRAP_NOT_PREPARED);
  assert(ArxVerifyAfterFrameworkLoad() == ARX_BOOTSTRAP_NOT_PREPARED);

  if (strcmp(argv[1], "already-registered") == 0) {
    partition_alloc::EarlyMallocZoneRegistration();
    const auto before = ArxReadBootstrapState();
    assert(ArxPrepareAllocator() == ARX_BOOTSTRAP_ALREADY_REGISTERED);
    const auto after = ArxReadBootstrapState();
    assert(before.zone_count == after.zone_count);
    assert(strcmp(before.default_zone_name, after.default_zone_name) == 0);
    return 0;
  }
  if (strcmp(argv[1], "multi-threaded") == 0 || strcmp(argv[1], "wrong-thread") == 0) {
    const bool wrong_thread = strcmp(argv[1], "wrong-thread") == 0;
    pthread_t worker;
    pthread_mutex_lock(&lock);
    assert(pthread_create(&worker, nullptr, Worker, wrong_thread ? &worker : nullptr) == 0);
    if (!wrong_thread) {
      assert(ArxPrepareAllocator() == ARX_BOOTSTRAP_MULTITHREADED);
      assert(!ArxPrepareAllocatorAndReportFailure());
    }
    pthread_mutex_unlock(&lock);
    assert(pthread_join(worker, nullptr) == 0);
    if (wrong_thread) assert(worker_status == ARX_BOOTSTRAP_WRONG_THREAD);
    const auto after = ArxReadBootstrapState();
    assert(initial.zone_count == after.zone_count);
    assert(strcmp(initial.default_zone_name, after.default_zone_name) == 0);
    assert(ArxVerifyBeforeFrameworkLoad() == ARX_BOOTSTRAP_NOT_PREPARED);
    return 0;
  }

  assert(strcmp(argv[1], "prepare") == 0);
  auto* allocation = static_cast<unsigned long*>(malloc(64));
  assert(allocation);
  *allocation = 0x12345678;
  auto* original_zone = allocator_shim::GetDefaultMallocZoneOrDie();
  assert(original_zone->size(original_zone, allocation) >= 64);
  assert(ArxPrepareAllocatorAndReportFailure());
  const auto prepared = ArxReadBootstrapState();
  assert(strcmp(prepared.default_zone_name, "DelegatingDefaultZoneForPartitionAlloc") == 0);
  assert(original_zone->size(original_zone, allocation) >= 64 && *allocation == 0x12345678);
  auto* later = malloc(64);
  assert(later && original_zone->size(original_zone, later) >= 64);
  free(later);
  free(allocation);
  assert(ArxVerifyBeforeFrameworkLoad() == ARX_BOOTSTRAP_OK);
  // No framework was loaded: do not claim its replacement happened.
  assert(ArxVerifyAfterFrameworkLoad() == ARX_BOOTSTRAP_UNEXPECTED_ZONE);
  assert(ArxPrepareAllocator() == ARX_BOOTSTRAP_OK);
  assert(ArxReadBootstrapState().zone_count == prepared.zone_count);
  return 0;
}
