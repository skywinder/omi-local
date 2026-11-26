# Omi Local backend compatibility

The initial comparison used the original [Omi revision ba4d7ac](https://github.com/BasedHardware/omi/tree/ba4d7ac0a2aa6c64f1c9a95ac0535dd4198cf593). Next now pins [782a793](https://github.com/BasedHardware/omi/commit/782a7937650c8e0f71455ebc0aae182eb86ab28b). The existing Local client and the Next client can use
the same paired deployment. The test server has its own deployed revision and is
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

## Paired server acceptance, November 25

The test server now serves page metadata, projected cards and authenticated WAV ranges.
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

The configured summary model classified synthetic speech about compilers as
`technology` and returned a subject emoji. The import and regeneration paths
retained the model labels. A manual category update passed through the live
paired HTTP endpoint on a temporary conversation in the emulator. Readback
confirmed the new category. Repeating the same update preserved the revision,
a stale edit returned 409, an invalid category returned 422, and an unsigned
request returned 401. The probe removed only its own fixture.

The Local storage contract from `625034a` now covers large grouped recordings
in Next's backend. The detail and metadata-edit responses expand the stored
preview from the checksummed transcript. Segment and speaker changes against a
file-backed preview return a conflict. A fixture with 1,500 segments verified
complete expansion and rejection of a changed file. Each test server release keeps
its previous Compose file list for rollback, including the original provider
and capture adjustments.

The paired archive search on the test server returned a snippet from a real file-backed
recording. Its segment identifier and millisecond timestamp matched the paired
detail response. The same check verified pagination was available, authentication
was required and an empty query was rejected. The isolated HTTP regression also
covers a match beyond the Firestore preview, deleted rows and a corrupt file.
Each search page expands at most one file and resumes after the last scanned document.

## Next slices

1. The signed package was installed and launched alongside Omi Local. Check category selection,
   filtering, playback, phone microphone capture and CV1 delivery to the same archive.
2. Verify folder operations on the deployed owner collection and exercise them
   from Next. Bring the offline capability flags and task routes across with
   their owner checks. Continue measuring archive search on the iPhone.

Run `make test-offline` for the archive adapter and the offline HTTP surface.
Run `make test-transport-unit` for transport/auth and offline route coverage.
For shared client behavior, use `make test-transport-app` and the pinned Next
suite. Confirm playback and capture on isolated data before any live rollout.
