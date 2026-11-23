# Profile erasure boundary

The native journal records immutable installation/root identity, the UUID which
owns `Default`, registered ordinary UUIDs, retired identities, exact directory
identities and removal progress. A retired UUID cannot register again. The
bounded format permits 128 identities and 256 observed children, with a 128-KiB
file limit; exhaustion fails closed instead of dropping old retirement records.
It accepts no deletion path in a queued request.

The journal lock only serializes journal ownership, including the end of native
shutdown. It is not a replacement for Chromium's ProcessSingleton. The bridge
must acquire the actual singleton. The generic executor additionally requires
strict acquisition without lock recovery plus the prior owner's clean receipt
and proven process exit. The separate quarantine route requires a later kernel
boot boundary as described below. The owner is PID plus kernel process start time, not PID alone.
Unknown process state or surviving recorded children leaves work pending.

`BeginRun` durably invalidates the previous clean receipt before any work.
`FinishCleanRun` is terminal and must run only after successful Chromium teardown
and complete helper tracking. Missing prior shutdown proof remains sticky:
an orderly later exit cannot account for helpers orphaned by an earlier crash.
Surviving profiles may still open, but later runs continue to deny deletion until
an independent recovery mechanism proves absence of the old writers.
`FinishStartup` seals deletion authority before any profile is loaded; profile
registration also seals it. No API deletes a loaded Chromium profile.

The filesystem executor uses directory descriptors and no-follow component
opening, checks root and target inode/device identity, rejects symlinks, hard
links, non-owned files, writable shared entries and mounted descendants, and
renames each exact target into a request-specific quarantine without replacing
an existing entry. Data and cache are independently journaled because they may
be on different volumes. Identical data/cache roots are deduplicated. The ledger
persists each identity as volume UUID plus inode, never `st_dev`: macOS renumbers
devices across reboots and OS updates. Live checks within a run still compare
`st_dev`. Version 2 ledgers, which stored `st_dev`, are read by inode against the
live roots and rewritten as version 3 on the next save. The cache
root must come from Chromium's `GetUserCacheDirectory`, not a caller guess.

Journal writes are bounded, owner-only and atomically replaced after file sync;
parent directories are synced after publication, rename and removal. Each target
is verified absent at both original and quarantine names before a verified
receipt is recorded. A rename/removal interrupted before its journal update can
resume under proven authority. An ambiguous path, write failure, dirty prior
shutdown or late recreation never produces success. Shared Local State, storage
keys, other profile directories, downloads and exports are outside the executor.

`Scripts.tests.test_profile_erasure` compiles these production files with
ASan/UBSan and exercises real filesystem/process behavior in native-created
owner-only temporary roots. It covers ordinary/Default and identical/separate
cache removal, survivors, interruption at durable boundaries, persistent denial
after dirty-owner restart, process identity, concurrent journal owners, root and
target replacement, symlinks/hard links, immutable mapping, stale requests,
retirement bounds and late recreation. These tests do not establish Chromium
startup responsiveness, profile unloading or native private-parent behavior;
those require the separate bridge and packaged owned-profile acceptance.

Verified state is cleared before revalidation and is never published from a
failed journal save. A later recreation/substitution invalidates the current
receipt. `Snapshot.durable` distinguishes a conservatively retired in-memory
identity after failed persistence from an acknowledged durable request. Root
nesting checks walk directory-descriptor ancestry, including filesystem case
aliases, rather than comparing path spelling.

The bridge is unconfigured under ordinary Run. ABI16 supplies a separate explicit
retirement opt-in; app composition supplies a durable root-bound identity and intent record.
Its strict singleton attempt falls back to Chromium's usual notification/lock
recovery only on a failed strict lock acquisition. Strict acquisition requires
creating a new lock entry; an existing matching PID symlink never counts as
new ownership. The fallback clears strict authority:
it may use a valid retirement ledger for ordinary browsing but cannot use the
generic clean-receipt executor. The boot-quarantine path has its own authority.
Other acquisition failures remain startup errors. Corrupt or unowned retirement
metadata still fails closed because surviving identities cannot be established.

The content helper tracker registers each launch before posting it, captures
PID and birth identity before checking its weak owner, and remains active until
ChromeMain returns. Missing launch replies, unreadable identities, duplicate
tokens, and bounded-tracker exhaustion deny a clean receipt. The tracker never
kills or guesses ownership of a process. The isolated policy harness executes
these production rules under ASan/UBSan; real packaged shutdown acceptance is
still required before enablement.

A pristine journal does not prove that an already-used root has no writers from
pre-journal browser runs. `Configure` currently has no independently validated
bootstrap proof for that case, including legacy `Default` adoption. This is an
whole-root adoption blocker. Neither creating a new ledger nor deleting an old
ledger establishes clean-lineage deletion authority. The per-target quarantine
route below establishes an independent, narrower writer-absence boundary.

`CreatedRoots::Create` now provides a separate, move-only creation-provenance
capability. It creates new mode-0700 children with the same unpredictable
128-bit name beneath already-owned data/cache parents. Identical parents share
one child. Existing entries are never adopted or replaced. The capability pins
both parent and root descriptors, exact inode/device identities, path mappings,
and the creating PID/birth identity. A fork, path substitution, parent
replacement, or loss of private permissions invalidates validation. Discarding
or moving a capability closes descriptors without deleting directories; partial
creation failure preserves both existing data and any newly created directory.
The caller must eventually derive the cache parent from Chromium's actual cache
mapping. The current bridge does not call this factory.

Creation provenance proves that these directory identities were newly created;
it does not prove continuous writer admission after their paths become known.
In particular, the capability has no operation that grants deletion authority,
no durable bootstrap receipt, and no conversion into journal authority. Its
validation can remain true after ordinary content is written. The policy tests
explicitly demonstrate that a validated creation capability still cannot make
an unproven configured startup finish clean.

Generic bridge startup now calls `RequirePriorCleanBoundary` before `BeginRun`.
This one-way restriction prevents an empty or missing ledger on an already-used
root from starting a clean lineage. It preserves usable retirement metadata and
surviving-profile registration. The low-level journal fixture's initial-clean
precondition is confined to native-created test roots whose writers and paths
are controlled by that fixture; it is not evidence for adopting an application
root. Existing proven prior clean boundaries continue to work.

The current Chromium startup creates the user-data directory before acquiring
its singleton. A future fresh-install bootstrap therefore needs a private
transaction that creates an unexposed root/cache pair, acquires the actual
strict singleton before exposing either path to a runtime, and transfers that
same held singleton into ChromeMain without releasing or reacquiring it. This
transaction and its packaged lifecycle acceptance are not implemented here.
An existing root with no journal is observationally compatible with both a
writer-free prior run and a prior run that left an unknown helper. Directory
inspection, a free singleton, and creating a ledger cannot distinguish those
histories. Existing-root and legacy-Default adoption remain unavailable until
independent writer-absence and admission proof is supplied.

The separate boot-quarantine policy provides a narrower legacy route.
`StageForNextBoot` accepts only already-durable, consent-bound retired records,
requires startup singleton ownership before profiles load, and publishes a
boot-staging disposition before its first rename. It moves the exact recorded
data/cache identities into `.arx-erasing-<request UUID>` without removing target
contents. Both quarantine phases must be durably published and revalidated
before the kernel boot UUID is read and sealed into the record. An interrupted
or unavailable seal is established in the later recovery boot, never backdated
to an earlier rename. The ordinary executor cannot unlink any boot-staged item,
including an item whose two-root staging was interrupted before its seal.

`ResumeQuarantinedAfterBoot` requires a different authoritative kernel boot
session and validates both roots, both private quarantine identities, and both
original paths before removing either target. A same-boot attempt, missing or
malformed boot UUID, interrupted seal, root substitution, or original-path
recreation cannot authorize removal or success. Original recreations remain
untouched; they are never adopted by inode guesswork. The existing bounded
no-follow filesystem executor and durable absence checks perform removal only
after that gate. This per-target route does not establish a clean lineage for
an entire existing application root.

The supported threat boundary is specific: ordinary older Arx binaries resolve
only their original `Default` and `Arx-<profile UUID>` names. Renaming into the
private quarantine namespace prevents those ordinary post-reboot loaders from
reaching the retired inode. Pre-quarantine helpers may keep writing through
held handles during the staging boot; the boot boundary excludes those old
processes. A later binary recreating an original name receives a different
identity, which blocks the receipt rather than being removed. Deliberately
opening a private quarantine path through an external program, unsupported
Chromium invocation, or a deliberately constructed alias is outside this
boundary. The current profile creation guard also rejects quarantine names;
the executable loader policy test exercises that production guard.

The kernel reader uses `sysctlbyname("kern.bootsessionuuid")`, validates exactly
37 returned bytes including the terminator, normalizes the uppercase kernel
UUID to lowercase, and rejects nil/malformed/unreadable values. It never uses
uptime, wall-clock boot estimates, executable UUIDs, or process enumeration.
Apple XNU exposes the backing boot UUID as a [read-only sysctl](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_sysctl.c#L2921).
The value is generated by [initializeBootSessionUUID](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOPMrootDomain.cpp#L4165)
called during [root-domain startup](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOPMrootDomain.cpp#L1790);
the sleep/wake UUID is a separate value. No private process-generation API has
been added. Kernel read failures remain unavailable, including tool-sandbox
`EPERM`. Boot identifiers remain in the owner-only journal, outside public
snapshots and logs.

The journal payload is now schema 2 within its existing private metadata path.
Schema-1 files fail closed instead of losing or silently reinterpreting their
retirement records; no production migration is implemented. The boot reader
has a native-only dependency seam for modeled boot transitions in owned policy
fixtures. Tests do not reboot the Mac or claim actual reboot acceptance. They
exercise a live owned writer after quarantine, same-boot denial, both-root
publication/removal interruptions, failed persistence, source recreation,
replacement quarantine identities, and surviving profiles. A separate read-only
probe verifies the real kernel reader without printing its UUID.

ABI16 adds an explicit opt-in run entry point bound to a persisted installation
UUID and permanent legacy-profile owner. Ordinary Run variants do not configure
retirement. The configured startup resumes eligible later-boot quarantines before
staging remaining retired targets; generic clean-lineage Execute stays unused.
The immutable public snapshot distinguishes awaiting startup, quarantine pending,
Mac restart required, verification pending, verified erasure, and blocked records.
It exposes profile/request UUIDs and revision, never paths or boot identifiers.
The queue rejects pages, pending preparation, private identities and downloads.

The Swift client acknowledges only an exact durable request with a newer journal
revision. Cancellation after dispatch cannot discard an irreversible retirement
receipt. The service holds profile admission closed through failures until
persisted intent is reconciled, while other profiles retain normal browsing.
The app must persist explicit intent before dispatch and its root-bound identity
before opt-in startup; existing retain-data removal remains independent.

The isolated app factory now binds durable installation identity, original
legacy ownership and consent before opt-in startup/dispatch. Combined ABI16
build, signed packaged lifecycle, actual reboot/resume acceptance and final
ownership review remain required before main integration.
Schema-1 metadata remains blocked without migration. Tests model boot transitions;
all filesystem mutations are confined to native-created owner-only temporary roots.
