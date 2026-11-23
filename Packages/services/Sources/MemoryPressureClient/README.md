# MemoryPressureClient

The system's memory pressure, as `@Dependency(\.memoryPressure)`. AppFeature's tab unloading (DEV-873) listens to it and unloads every hidden tab it may as soon as the level turns critical, and keeps doing so on each sweep while it stays critical.

## Behaviour

- **`levels()`** yields the kernel's current level (`kern.memorystatus_vm_pressure_level`) when it can be read, then each change from a dispatch memory-pressure source (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`) for normal, warning and critical. These are the macOS signals Chromium's own `SystemMemoryPressureEvaluator` reads. Ending the stream cancels its source.
- The events run on the main queue; the levels are `normal`, `warning` and `critical`, ordered.

`testValue` is unimplemented, so a test that starts tab unloading supplies its own levels. `previewValue` never reports pressure.
