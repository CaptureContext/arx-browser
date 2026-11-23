#ifndef ARX_CHROMIUM_BOOTSTRAP_H
#define ARX_CHROMIUM_BOOTSTRAP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int32_t thread_status;
  int32_t zone_status;
  uint32_t thread_count;
  uint32_t zone_count;
  bool is_main_thread;
  char default_zone_name[128];
} ArxBootstrapState;

// Copies a bounded observation. Never registers or unregisters allocator zones.
ArxBootstrapState ArxReadBootstrapState(void);

// Called only from Debug entry points. Does nothing unless the smoke runner's
// ARX_ENGINE_SMOKE_TITLE environment value is nonempty.
void ArxReportBootstrapEntryForSmoke(void);

typedef enum {
  ARX_BOOTSTRAP_OK = 0,
  ARX_BOOTSTRAP_WRONG_THREAD,
  ARX_BOOTSTRAP_MULTITHREADED,
  ARX_BOOTSTRAP_INSPECTION_FAILED,
  ARX_BOOTSTRAP_ALREADY_REGISTERED,
  ARX_BOOTSTRAP_UNEXPECTED_ZONE,
  ARX_BOOTSTRAP_NOT_PREPARED,
} ArxBootstrapStatus;

// Process-global, main-thread-only startup. Registration happens at most once.
ArxBootstrapStatus ArxPrepareAllocator(void);
bool ArxPrepareAllocatorAndReportFailure(void);
ArxBootstrapStatus ArxVerifyBeforeFrameworkLoad(void);
ArxBootstrapStatus ArxVerifyAfterFrameworkLoad(void);
const char *ArxBootstrapStatusDescription(ArxBootstrapStatus status);

#ifdef __cplusplus
}
#endif

#endif
