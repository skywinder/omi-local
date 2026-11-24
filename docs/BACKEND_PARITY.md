# Omi Local backend compatibility

Comparison baseline is the original [Omi revision ba4d7ac](https://github.com/BasedHardware/omi/tree/ba4d7ac0a2aa6c64f1c9a95ac0535dd4198cf593),
also pinned by Next. The existing Local client and the Next client can use
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

## Next slices

1. Compare the shared list/detail fields used by both clients, then bring the
   original's lightweight list projection to paired reads with legacy client
   coverage. Keep transcript content on the detail route for callers that need it.
2. Verify WAV playback on an isolated paired runtime, including old recordings,
   authenticated range requests and fallback on a deployment without playback.
   Record the capabilities of the deployment before pointing a phone at it.
3. Work through processing and optional product features using the same route,
   model and lifecycle comparison. Update capability checks alongside each
   added behavior.

Run `make test-offline` for the archive adapter and the offline HTTP surface.
Run `make test-transport-unit` for transport/auth and offline route coverage.
For shared client behavior, use `make test-transport-app` and the pinned Next
suite. Confirm playback and capture on isolated data before any live rollout.
