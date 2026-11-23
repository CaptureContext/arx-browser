# TaskManagerFeature

Window ▸ Task Manager (DEV-898): every Arx process with its memory (physical footprint, as Activity Monitor shows it), CPU over the last second and process ID, and the tabs and extensions running in each renderer. End Process ends a selected renderer, a tab's or an extension's, the way Chrome's Task Manager does; Arx itself, the GPU process and utility processes can't be ended.

The feature samples `BrowserEngineClient.processTable` once a second while its window is open (`ui(.present)` to `ui(.dismissed)`) and never otherwise. CPU is the change in each process's CPU time between two samples, in percent of one core, so the first sample shows none. Rows sort with Arx itself first, then by memory, CPU or process ID.

The engine reports which page or extension runs in each live renderer (`ArxEngineCopyProcesses`, an export outside the ABI table); `BrowserProcessSampler` in BrowserEngineClient reads every process's counters with `proc_pid_rusage` and each helper's role from its `--type=` switch, as `Scripts/core/process_metrics.py` does for the benchmark. With an engine built before the export, `processTable` is nil and the window says so.

AppFeature owns the window (`BrowserWindow.renderTaskManagerWindow`) and names each row's tabs and extensions, since only it knows their titles. Verify with TaskManagerFeatureTests.
