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
Queued replies expose the worker phase and the number of completed source
chunks when known. This is a chunk count. Combining and publication are
separate phases. Resuming after a restart keeps the last saved count visible.
Failures expose bounded diagnostic codes without provider response bodies.

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

## Paired archive management

The web library reads favorites, archiving and category metadata from paired
Conversations after a recording has been imported. Browser requests use opaque
recording tokens. The harness resolves them to import keys and sends the paired
key to the backend on loopback. The backend checks the owner, recording
provenance and availability inside the write transaction. A category edit
compares the previously shown category. The backend keeps a manual category
when later processing updates the summary. Archiving sets only the browser's
`archived` flag. The mobile client uses the shared favorite and category fields.
When note metadata is temporarily unavailable, audio and transcripts remain
available in the web library.

Next reads `local_folders_version`, `local_speaker_labels_version`, and
`local_task_suggestions_version` from the authenticated paired profile. When
updating an existing deployment, verify those flags together with the live
routes. A router present in Git can still be absent from a running deployment.

Folders use the existing Firestore collection. Moves and ordering compare the
expected state, and deleting a folder clears its recording assignments while
preserving the recordings. Manual speaker names belong to the paired owner.
Their assignments compare the prior label on stable transcript segment IDs.
Task suggestions use the configured summary model after consent and include a
transcript citation. Only accepting a suggestion creates a task.

On November 26 Bastion enabled all three capabilities. An isolated owner
verified folder moves, stale-write rejection, deletion that preserved the
recording, manual speaker assignment and suggestions from the selected model
with transcript timestamps. Requests without a paired key were rejected.

## Daily recaps and manual goal progress

The paired profile advertises `local_daily_recaps_version` and
`local_goals_version`. A day recap uses the calendar bounds chosen on the
phone, including shorter and longer days at daylight saving transitions.
The preview lists eligible sources and the selected summary model. After
consent the server uses the applied model through the private library relay,
resolves citations to the saved conversations, and checks the archive revision
before publishing. An identical retry returns the saved overview.

Goals reuse the original Firestore collection and read route. A paired owner
can add a goal and append a manual progress event with an optional metric and
recording link. Replays return the same event. A conflicting revision or an
unavailable source is rejected before changing the goal.

Bastion enabled both capabilities on November 26. An isolated owner verified
generation through the applied model, listing the saved recap, creating a
goal, and checking a replayed progress event with a recording reference.
In Next, open **Daily Recaps** or **Goals** from the archive menu. Open
**Log progress** from a completed conversation to attach it to a goal entry.

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

Archive chat uses this same socket for up to six semantic excerpts and alternates
them with keyword matches under the existing context budget. It sends only text
from the verified, cited segment. Summary passages and neighboring lines can help
the index rank a source. They cannot be cited as that segment. New or revised
transcripts remain searchable by words while the index catches up. A missing or
stale semantic index leaves the existing bounded keyword scan available.

An updated client requests `stored=true` when reading archive chat and explicitly
opts into saving a turn. Legacy requests keep their session-only response. The
paired owner has one shared archive chat history with a paged read. Turns are
encrypted in the local Firestore emulator. Append compares the reported head and
the direct source revisions in the same transaction. A repeated request returns
the stored result. The server checks source availability again before presenting
an old answer or using it as model context.

Named conversations use separate routes under
`/v1/local/conversations/chat/threads`. Each one has an encrypted title, its
own history and head, and an owner-scoped transcript lookup. Existing clients
can still read and append to the shared history from the original route.
Deletion clears a named conversation's messages and title in a transaction.
It keeps the empty ID as a fence against replaying creation or publishing an
in-flight reply. There can be up to 40 active named conversations, each with
up to 250 replies, so a complete thread fits in a single deletion transaction.
The Bastion acceptance used two paired clients and an isolated owner to check
independent follow-ups, access from another owner, and deletion during inference.
Deletion applies to the live database. Existing backup snapshots retain their
own lifecycle.

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

Paired category backfill has a separate capability and accepts up to eight
owner-selected completed recording IDs. The loopback provider gets numbered,
bounded excerpts after the client confirms the model. The backend validates a
complete result before writing and compares each recording's Firestore revision.
It updates only its category when no explicit manual or known category exists.
An unclear result leaves the previous label available for manual editing.

The Local storage contract from `625034a` now covers large grouped recordings
in Next's backend. The detail and edit responses expand the preview from the
checksummed transcript. Segment text and speaker changes compare against the
complete transcript inside the recording transaction. Firestore stores the
bounded encrypted edits and a current first-line preview. Detail, search, summary
generation, chat and task suggestions read the same edited segments. Chat uses
only checked files for evidence and keeps its deadline when scanning the archive.
Returning a segment to its original text or speaker removes its override.
Older Bastion images need the paired chat router, its offline allowlist and
the loopback library's chat provider module in the same release. Verify that
the library imports the provider before restarting the app. Each Bastion release
keeps its previous Compose file list for rollback, including the original
provider and capture adjustments.

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
