# Performance baselines

The performance gate's baselines (DEV-902): one `<model>.json` per Mac model (`sysctl hw.model`, such as `Mac16,10.json`), holding the metrics of the last release measured on that kind of Mac. `make perf-gate ARGS='--current build/release/Arx.app --record'` compares a release with its Mac model's file and, once the gate passes, replaces the file; commit it with the release. A model without a file needs `--override "<reason>"` for its first release. See [Scripts/README.md](../README.md#performance-gate).

Each file holds `model`, `chip`, `memory_gb`, `macos`, `release` (`<version> (<build>)`), `recorded` (UTC), `sessions`, `launches`, `metrics` (every key in `perf-gate.json`) and, when the gate was overridden, `note` with the reason.

`load/<model>.json` files hold `make load-ladder`'s ceilings (DEV-1027), in a folder of their own so the gate's baseline checks don't read them: for the awake and unloaded ladders, the highest tab count that passed every limit, the count that broke and which limits it broke, the steps climbed, and the limits and Mac they were measured with. `make load-ladder ARGS='--record'` writes the file for this Mac's model; a `--quick` run never does. See [Scripts/README.md](../README.md#load-ladder).
