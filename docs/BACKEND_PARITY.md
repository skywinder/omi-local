# Omi Local backend compatibility

The initial comparison used the original [Omi revision ba4d7ac](https://github.com/BasedHardware/omi/tree/ba4d7ac0a2aa6c64f1c9a95ac0535dd4198cf593). Next now pins [782a793](https://github.com/BasedHardware/omi/commit/782a7937650c8e0f71455ebc0aae182eb86ab28b). The existing Local client and the Next client can use
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

## Structured recording notes

The summary provider receives numbered transcript lines. Each generated
section can cite those numbers. During import or regeneration the paired
backend resolves them to the real transcript segments. Mixed-speaker lines
can map to several canonical segments. The stored `structured.sections` and
its Markdown projection use Omi's existing Conversation fields.

Regeneration checks the transcript, segment identities, prior notes and
request ID before publication. Provider responses with only an overview
remain readable. Source links use the local archive. Decisions and next
steps appear in the summary, ready for review before any task is created.

Servers advertising `local_summary_jobs_version: 1` expose the same durable
queue in the library and paired app. The `summary-jobs` route accepts an
idempotent request and returns status by request ID. Keep provider consent
bound to the exact selected snapshot and template. The library saves unfinished
work privately and reuses completed chunks or a saved candidate after restart.
The worker can load verified file-backed transcripts and accepts up to two
million formatted characters. It rechecks the source at publication. The old
`regenerate-summary` endpoint retains its synchronous response for older apps.

## Paired task reminders

The paired profile advertises `local_task_reminders_version: 1`. The existing task
mutation compares the prior typed deadline inside its transaction. A day keeps an
ISO local date and IANA zone. An exact time keeps an absolute instant and its
zone. The mutation derives the next notification time and mirrors a timed
deadline into the legacy `due_at` field. Legacy deadlines stay readable without
automatically opting any phone into notifications.

The owner-scoped `GET /v1/local/action-items/reminders/schedule` route uses a
single Firestore time index, returns up to 48 future reminders, and includes up
to 48 recently due reminders for Android alarms that may still be pending.
Phones only schedule new future alarms. Notification permission, opt-in and
delivery are native to each paired phone. Local uses no hosted notification service.
A failed schedule read leaves the last confirmed device schedule intact.

## Semantic archive search

Next offers **Words** and **Meaning** in the archive search screen. The paired
`POST /v1/local/conversations/semantic-search` route uses an optional CPU worker
over a private Unix socket. The worker uses the pinned
[multilingual E5 ONNX model](https://huggingface.co/intfloat/multilingual-e5-small/tree/614241f622f53c4eeff9890bdc4f31cfecc418b3/onnx).
It verifies the model and tokenizer hashes from `local_semantic_model.py` at
startup, reads them from disk and performs inference without an internet
connection. A missing worker or index returns 503 for Meaning. Word search
continues through its existing separate route.

The index stores source IDs, Firestore revisions, passage positions and vectors.
Firestore and checksummed transcript files remain authoritative. The paired
API reads ranked candidates from the current archive revision, skips stale or
removed sources, and returns transcript evidence with the original segment IDs
and times. A partial scan cannot publish because the local exporter must send a
complete inventory marker for the same owner.

For an isolated rollout, use Python 3.11 or later with `onnxruntime==1.24.4` and
`tokenizers==0.22.2` in a separate environment. Place `model.onnx` and
`tokenizer.json` from the pinned revision in a local model directory. Use the
live backend's paired configuration with a loopback Firestore emulator to run
`backend/scripts/export_local_semantic_sources.py --owner-digest`. Stream the
same command without the option straight to `python -m dev_harness.local_semantic
--model MODEL_DIR --index INDEX --owner DIGEST build` from `scripts/dev-harness`.
Run the exporter only through a trusted local pipe. It emits private transcript
text for the running indexer. Repeating a full scan reuses vectors for unchanged
records and removes sources that disappeared. Put the index on private storage.

Start the worker with the same model, index and owner arguments plus
`--socket ABSOLUTE_SOCKET_PATH serve`. The backend defaults to
`$OMI_HARNESS_STATE_ROOT/services/semantic-search/queries.sock`. A deployment can
override that path with `OMI_LOCAL_SEMANTIC_SOCKET`. Grant the paired backend
access to that private socket. The worker can run in a network-disabled process.
The [optional Docker overlay](DOCKER.md#semantic-archive-search) starts an independent
refresh loop in the paired runtime. It streams a complete inventory to the worker
on startup and every five minutes. Queries use a separate socket and keep reading
the last complete index while an update runs. A new or edited recording appears in
Meaning after its next successful scan. Deletions are excluded by the canonical read
as soon as the conversation becomes unavailable. Firestore assigns new revisions
after importing an emulator snapshot. The worker rebinds existing vectors to those
revisions when the indexed text and passage positions have the same digest.

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
complete expansion and rejection of a changed file. Each Bastion release keeps
its previous Compose file list for rollback, including the original provider
and capture adjustments.

Next can opt in to resolving a saved-recording detail with
`GET /v1/conversations/{id}?resolve_local_recording=true`. For the paired owner,
the route returns the completed conversation when the capture has one successful
import receipt and the stored result matches it. Clients use the returned ID
for playback and edits. The plain detail route keeps exact-ID lookup. If a group
is waiting for parts or a capture has multiple imported results, Next requests
`include_recording_results=true` on the same route. The response keeps the
temporary card ID and includes a compact list of results. Group children follow
the stored recording ID and sample-boundary identity. Each published result is
checked against its import receipt and the owner's current Conversation record.
The list omits transcript bodies. Full playback and edits open the selected
result by its own ID. Older clients retain the exact lookup and single-result
resolution behavior.

An exact detail read with `include_recording_results=true` still returns the
requested conversation. When its import receipt proves the relationship, the
response adds `local_transcript.recording_results_id`. For grouped audio, the
link points to the group's results and also checks the original sample boundary.
For multiple passes over one ungrouped capture, it points to that capture's
results. Next uses the same opt-in detail route to open the list.

The paired archive search on Bastion returned a snippet from a real file-backed
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
