# AppRelocationTests

Covers `AppRelocationClient.relocate(askFirst:)` with test doubles for every case in DEV-703: on a disk image, translocated (asked, declined, suppressed), already in Applications, an older copy installed, a copy running, `/Applications` not writable, a declined administrator prompt, a failed copy and a failed relaunch. Also covers which launches may relocate at all. The live file, Trash, `hdiutil` and authorization operations aren't exercised here; they need a notarized disk image on a clean Mac.
