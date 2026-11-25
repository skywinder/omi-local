# Keeping Omi Local current

Omi Local has an independent snapshot history. Preserve that history and import
reviewed changes in small batches. A merge with `--allow-unrelated-histories`
would restore removed cloud, desktop and deployment components and overwrite
local behavior; it is not the update procedure.

## Comparison on 2026-10-28

| Tree | Revision | Meaning |
| --- | --- | --- |
| BasedHardware/omi | `95f97c1e850f162f1d3d381b5a71afa4359768ac` | Fetched upstream main, dated October 28 |
| Original snapshot | `2ce52f13f4724eee989158da6318dc6f27aa744e` | September 2 source baseline; unchanged provenance |
| Omi Local main | `e669d41` | PR #17 merged October 27 |
| Local acceptance branch | `88d0633` | `sky-uat`, including recording recovery, timer fixes and wearable recovery notes |

The first integration branch joins Local main and the acceptance branch before
adding backports. It preserves the older development checkout and its uncommitted
work. Changes found there include already published onboarding, recording cards,
translation and provider fixes; those must not be reapplied over newer versions.
Machine-generated watch-scheme edits are not part of this integration.

Upstream advanced by 7,417 reachable commits since the previously checked
`6140722462`; 642 first-parent entries in that interval touch `app/` (including
tests, documentation and merges). These are change counts, not feature counts.
The original snapshot is 8,729 reachable upstream commits behind this observation.
The shared package version is not a useful synchronization marker: both trees
still declare `1.0.543+992`. Compare Git revisions and behavior instead.

## What changed upstream

| Area | Examples | Local integration decision |
| --- | --- | --- |
| Capture and Bluetooth | Persistent native reconnect intent, capture ownership, recovery across settings changes | High priority for a separate adapted change; preserve Local Stop/mute and phone-input ownership |
| Offline audio | Durable pendant custody, upload refusal recovery, oldest-first drains, background audio decode | Local has its own paired outbox and durable receipts; do not replace it with the cloud uploader |
| Transcript and Home | Retain open transcripts during list refresh; lighter rendering; live preview on Home; noise folding | Transcript retention and rendering are candidates; noise counts and episode features need corresponding backend APIs |
| Data robustness | Malformed preference/record isolation, atomic audio indexes, device-delete ownership | First batch below |
| Desktop, search and plans | Desktop restore/search changes, saved-transcript chat search, Omi Pro billing | Separate product/cloud dependencies; not imported into the local iOS/CV1 runtime |

Local-specific behavior remains authoritative: paired origins and Keychain,
server-scoped caches, independent Live/final STT/diarization, bidirectional live
translation, durable phone outbox, native/Docker separation and local egress policy.
Firmware updates require a separate hardware decision; this procedure does not
flash a device. Wearable-buffer recovery remains governed by [its plan](WEARABLE_RECOVERY.md).

## First backport batch

| Upstream change | Imported behavior |
| --- | --- |
| [#13491](https://github.com/BasedHardware/omi/pull/13491) | A malformed saved device no longer throws on startup |
| [#13500](https://github.com/BasedHardware/omi/pull/13500) | Skip individual unreadable cache entries; preserve unreadable unsynced memories on add/remove |
| [#13493](https://github.com/BasedHardware/omi/pull/13493) | A malformed action or event does not discard the rest of a conversation |
| [#13504](https://github.com/BasedHardware/omi/pull/13504) | Serialize and atomically replace the WAL index; recover empty/torn indexes from backup |
| [#13510](https://github.com/BasedHardware/omi/pull/13510) | A phone recording delete cannot send a delete to an unrelated device recording |

The preference patch also covers Local's per-server conversation caches. Reading
a bad entry leaves stored bytes intact and never reads another server's cache.
New decode logs contain types, not preference contents or server/account namespaces.
These fixes target inherited app code, not a migration of the separate Local outbox.
An additional local regression fix extends index recovery to valid JSON with an
invalid index structure (`[]`, `{}` or a non-list `wals` value). Such files cannot
overwrite the good backup. A valid empty index remains empty, preserving deletion.

Original upstream tests reproduce the affected failures before the backport.
The adapted batch and index follow-up pass 44 focused tests and `make test-transport-app`, including
the analyzer ratchet. The Makefile runs the new tests in the existing transport-app
CI lane. Physical iPhone/CV1 behavior and endurance are a separate acceptance gate;
unit tests do not establish installation or deployment.

Validation for this branch: `make test-transport-app` passed 473 Flutter tests
and the analyzer; `make test-offline` passed 891 Python tests and 26 web tests
with 3 skips. The optimized audit passed its 4 independent-history tests and
produced the same 4,785 pending commit identities as the initial implementation
against the real source repository. This backlog includes retained upstream cloud
code and new paths; it is not a list of 4,785 changes required by Local.

## Repeatable update procedure

1. Inspect both repositories and current Local working trees. Keep dirty trees
   intact. Fetch the source with `git -C /path/to/omi fetch --no-tags origin main`.
   Fast-forward its clean main checkout only; never reset local changes.
2. Fetch Local's origin. Start an isolated `sky/upstream-sync-*` worktree from the
   current acceptance branch, incorporating Local main without dropping acceptance
   fixes. Inspect any conflicts before selecting upstream patches.
3. Run the read-only backlog from the Local worktree:

   ```bash
   python3 scripts/upstream_audit.py --upstream /path/to/omi --format markdown
   # Full paths and classifications for further review:
   python3 scripts/upstream_audit.py --upstream /path/to/omi --format json
   ```

   The report compares committed trees and warns about dirty Local work. It reads
   the original snapshot baseline, not the most recently observed head, so older
   unreviewed changes remain in the backlog. Categories indicate where local
   adaptation is likely; they do not prove that a patch applies or is safe.
   The inventory covers `app/` and `backend/`; inspect merge-only resolutions with
   `git diff <previous-observed-head> origin/main -- app backend` in the source.
4. Inspect the source commit and later changes in the same subsystem. Port the
   relevant production code and behavioral tests, preserving Local contracts.
   Record exact source SHAs and adaptations in `upstream-sync.json`. Only explicit
   `backported`, `already_local` or `out_of_scope` decisions leave the pending list;
   `deferred` entries remain visible. `observed_head` is an observation, not a
   declaration that every earlier change was integrated.
5. Run `make test-transport-app` and `make test-offline` using the pinned Flutter
   SDK, prepared Python environment and Node on PATH. Commit by testable surface.
   Follow the repository's publication and iPhone attestation gates separately.

The audit never fetches, changes branches, applies patches, installs, publishes or
schedules work. Its synthetic independent-history tests run in the existing
transport-unit/offline harness inventory.
