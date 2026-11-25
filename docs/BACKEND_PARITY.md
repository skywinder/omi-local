# Omi Local backend compatibility

The initial comparison used the original [Omi revision ba4d7ac](https://github.com/BasedHardware/omi/tree/ba4d7ac0a2aa6c64f1c9a95ac0535dd4198cf593). Next now pins [6f771e1](https://github.com/BasedHardware/omi/commit/6f771e1f5f50768ed7a7c8fd539b1f4b5ef426ed). The existing Local client and the Next client can use
the same paired deployment. Bastion has its own deployed revision and is
checked separately from this worktree.

## What can track the original

| Area | Original Omi | Local and Next | Update practice |
| --- | --- | --- | --- |
| Archive and details | FastAPI, Firestore, and the `Conversation` and `Structured` models. The list includes page metadata, read budgets and Home projections. | Same wire models and `/v1/conversations` read routes. The paired archive also projects saved audio awaiting import. | Compare shared request parameters and response fields at every pin update. Keep the merge of pending WAVs in the Local adapter. |
| Identity and access | Firebase user authentication, hosted account and entitlement checks. Cloud job endpoints have separate service authentication. | Paired owner and app key, Firestore emulator, a limited offline route table and loopback-only backend egress. | Update shared models and route behavior with an explicit paired authorization check. Keep cloud authentication and job ingress outside the offline surface. |
| Live and durable audio | Realtime listening and provider routing, hosted storage and asynchronous finalization. | Legacy listen clients and Next share the paired server. Next saves durable parts, verifies receipts, and can group them by sample position. | Preserve both transport versions and their ownership rules. Keep audio payloads and the queue behind the Local adapter. |
| Transcription, diarization and summaries | Maintained provider policies, inference services, managed gateway and cloud background jobs. | Local harness owns provider selection, staging and retry. The trusted importer publishes through the Conversation lifecycle. | Adopt upstream output fields and lifecycle semantics where applicable. Keep the runtime, credentials and provider adapters in the harness. |
| Playback | Hosted audio artifacts and a managed merge pipeline. | Owner-checked local WAV and HTTP range playback on compatible servers. An older deployment may store audio without exposing this API to Next. | Keep playback independent from transcript availability. Check the actual deployed route and capability. |
| Product writes | Canonical Firestore collections for conversations, tasks, folders, recaps and goals. | Local reuses those collections and adds paired mutations, including expected values and revisions where writes can conflict. | Reuse schema and ownership rules first. Adapt triggers and side effects around the shared write. |

The maintenance unit is a user-facing contract, for example archive list,
detail and playback. For each upstream update, compare that contract against
both Git revisions, then verify the existing Local client, Next, and the
paired server independently. Keep mobile and backend update decisions
separate so a server-only improvement can ship to the installed clients.

## First slice: archive pagination

The Local adapter in [local_recording_rows.py](../backend/utils/local_recording_rows.py)
combines Firestore rows and pending recordings. The existing array response
remains in place. The paired list now emits the upstream
`X-Omi-Conversation-Page-Size` and `X-Omi-Has-More` headers. One lookahead row
distinguishes a full final page from a page with a continuation. A truncated
read retains `X-Omi-List-Truncated` and omits an end-of-list claim. When
Firestore yields only a prefix, the adapter avoids advancing past pending
recordings that could follow unread canonical rows.

Clients with offset pagination still send the same request. Next already
reads both page headers through the original Conversation API adapter.
The original's indexed Home, opaque cursors, translation on open, and
first-open background work require their own contracts.

## Card and detail reads

Next adds `list_fields_only=true` to its paired archive request. Firestore
projects the Conversation fields plus Local title and category overrides and
skips both stored transcript fields. Next opens the full detail by ID.
The existing Local app still receives the full list. Older paired servers
accept the extra query parameter and serve their existing response.

## Bastion acceptance, November 25

Bastion now serves page metadata, projected cards and authenticated WAV ranges.
A ten-row page measured 118,001 bytes for the existing client and 54,991 bytes
for Next, with matching IDs and summaries. The next ten rows had distinct
IDs. Opening a saved recording returned its original transcript. Its first 44
WAV bytes returned HTTP 206 with a RIFF/WAVE header. The same audio request
without the paired key returned 401.

The deployment retained the active image and its existing Compose overlays,
including the waiting-for-parts rows and host-specific provider code. The
release directory recorded in the app container's Compose config-file label
contains the reviewed file hashes and `rollback.sh` for this change. A fresh
Firestore and Auth export preceded the app restart.

## Next slices

1. Align paired category edits and classification with the Bastion processing
   pipeline, including owner overrides when summaries regenerate.
2. Check the existing client and Next on the same physical iPhone against the
   updated archive and playback routes, then verify new microphone and CV1 audio.

Run `make test-offline` for the archive adapter and the offline HTTP surface.
Run `make test-transport-unit` for transport/auth and offline route coverage.
For shared client behavior, use `make test-transport-app` and the pinned Next
suite. Confirm playback and capture on isolated data before any live rollout.
