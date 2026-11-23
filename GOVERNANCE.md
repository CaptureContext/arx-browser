# How decisions are made

## Roles

- **Owner.** Maxim Krouk (CaptureContext) started Arx and has the final word on what it is: its look, its scope, its releases, and who maintains it.
- **Maintainers.** People with merge rights. Today that is the owner alone. They triage issues, review and merge changes, and cut releases.
- **Contributors.** Anyone who reports a bug, answers a question, tests a build or, once pull requests open, sends one.
- **Agents and automation.** Maintainers use coding agents (Claude Code, Codex) and run them by hand. The repository's own automation only checks and annotates: it runs the checks, comments on a pull request and may add a label such as `new dependency`. Nothing automatic merges, releases, or closes an issue.

## How a change gets in

Arx doesn't accept pull requests yet; [CONTRIBUTING.md](CONTRIBUTING.md) says why and what comes first. Until then every change is made by a maintainer, and the way to influence Arx is an issue or a discussion.

1. **Bugs.** Open an issue with the bug report form. A maintainer confirms it, fixes the cause and proves the fix: a test that fails before and passes after, or a before and after for anything visible.
2. **Anything people see** (layout, motion, controls, words on screen) is decided by the owner. A request is easiest to judge with a screenshot or a mockup.
3. **New features, new settings, and changes to what Arx stores, syncs or sends** start as a feature request or a discussion. The owner answers yes, no or "not now" there, with a reason.
4. **Dependencies.** A new one needs a licence compatible with GPL-3.0 and a row in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
5. **Disagreements** go to the owner, whose call is final.

When pull requests open, a change will also need the contributor agreement described in CONTRIBUTING.md, the proof above, and one maintainer's approval.

## Releases

The owner releases from `main`. Every release is signed and notarized, and its source is published with it, as the GPL requires. Fixed issues are closed with the version that fixed them.

## Name and licence

Arx's code is under the GNU General Public License, version 3 ([LICENSE](LICENSE)). The name and icon are reserved; a distributed fork takes its own ([TRADEMARKS.md](TRADEMARKS.md)).

## Becoming a maintainer

Not open yet. When it is, it will follow from sustained, well-proven contributions and helpful reviews, by the owner's invitation.

## Changing this page

The owner changes it, and says why in the commit.
