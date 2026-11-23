# StyleCheck

Command-line checker: `StyleCheck [--github] PATH...` checks each Swift file, or every `.swift` file under a directory (skipping `.build`, `build`, `Forks` and hidden directories), in parallel. It prints one `path:line:column: warning: [rule-id] message` per finding, or a GitHub `::warning` annotation with `--github`, then a count per rule on standard error. It exits 0 whatever it finds and 2 for a usage error. `--list-rules` prints each rule's ID, guide section and summary.

`make style` builds it and passes it the repository's Swift files.
