#include "ChromiumBootstrap.h"

#include <mach/mach.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

ArxBootstrapState ArxReadBootstrapState(void) {
  ArxBootstrapState state = {0};
  state.is_main_thread = pthread_main_np() != 0;

  thread_act_array_t threads = NULL;
  mach_msg_type_number_t count = 0;
  state.thread_status = task_threads(mach_task_self(), &threads, &count);
  if (state.thread_status == KERN_SUCCESS) {
    state.thread_count = count;
    for (mach_msg_type_number_t index = 0; index < count; ++index) {
      mach_port_deallocate(mach_task_self(), threads[index]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads,
                  (vm_size_t)count * sizeof(thread_t));
  }

  vm_address_t *zones = NULL;
  unsigned int zone_count = 0;
  state.zone_status = malloc_get_all_zones(mach_task_self(), NULL, &zones, &zone_count);
  if (state.zone_status == KERN_SUCCESS) {
    state.zone_count = zone_count;
    // malloc_default_zone() denotes the original system zone, not necessarily
    // the current default. Chromium reads the first enumerated zone instead.
    if (zone_count > 0) {
      const malloc_zone_t *zone = (const malloc_zone_t *)zones[0];
      if (zone && zone->zone_name) {
        snprintf(state.default_zone_name, sizeof(state.default_zone_name), "%s", zone->zone_name);
      }
    }
  }
  return state;
}

void ArxReportBootstrapEntryForSmoke(void) {
  const char *title = getenv("ARX_ENGINE_SMOKE_TITLE");
  if (!title || !title[0]) return;
  const ArxBootstrapState state = ArxReadBootstrapState();
  char message[384];
  int length = snprintf(message, sizeof(message),
      "ARX_BOOTSTRAP_ENTRY threads=%u main=%u zones=%u threadStatus=%d zoneStatus=%d defaultZone=%s\n",
      state.thread_count, state.is_main_thread ? 1 : 0, state.zone_count,
      state.thread_status, state.zone_status,
      state.default_zone_name[0] ? state.default_zone_name : "<unnamed>");
  if (length > 0 && (size_t)length < sizeof(message)) {
    (void)write(STDERR_FILENO, message, (size_t)length);
  }
}
