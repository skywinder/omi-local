# Repository improvement plan

Reviewed on 2026-11-26 against committed Next `667be72`, Local `sky-dev`
`69284ad`, and the original Omi checkout and Next pin `782a793765`.
This is a source review, not a fresh server or device acceptance run. The
original repository was not fetched during this review. Existing device evidence
is recorded in the [feature inventory](../clients/next/FEATURES.md) and
[migration ledger](../clients/next/README.md#migration-ledger).

## Direction

Develop new mobile features in Next. Reuse pinned Omi models, presentation and
tested behavior through explicit paired APIs. Keep Local as the common server,
processing registry and durable audio delivery implementation. Keep the older
Local app available for compatibility checks and delivery of its own queue.
Do not build the same new product feature independently in both mobile clients.

Next already follows this direction; replacing it with the complete cloud Omi
client would repeat pairing, startup, capture and authorization work. Updating
the source pin makes upstream code available, but does not enable its screens
or server services. Keep local data authoritative and inference providers explicit.
Here, local means self-hosted storage and processing under the owner's control;
it does not mean every feature runs without a server or on the phone.

## Implemented: remove these from the new-feature backlog

| Area | Current source behavior | Remaining boundary |
| --- | --- | --- |
| Capture and delivery | Phone/CV1 recording, shared durable phone journal, exact server receipts, Finish without stopping listening, reconnect and retry status | Long locked-screen runs, iOS call interruption and system termination need their own acceptance |
| Live | Draft/final text, translation, silence boundaries, capture timer and controls | Verify language corrections and recovery on the selected iPhone artifact |
| CV1 archive | Oldest fragment, bounded series and full sync; checkpoints, overlap checks and resume after Bluetooth reconnect | Legacy firmware can release data before phone persistence; full-sync code is not proof of lossless recovery |
| Archive | Playback and transcript seek, edits, categories, favorites, archive/restore, folders, manual speaker names | Automatic recognition of the same person across recordings is not implemented |
| Offline use and export | Cached cards, explicitly downloaded recordings with a 1 GiB phone budget, TXT/WAV export | Downloaded audio is distinct from on-device speech recognition |
| Search | Full-transcript keyword search and a local semantic index with cited timestamps | Measure relevance and latency on a representative archive; keyword search still scans pages |
| Summaries | Structured notes and sources, templates, provider selection, regeneration and one resumable background queue shared by web and Next | Published template/model and inline choices implemented; verify long-job return on iPhone |
| Chat | Recording and archive questions, citations, saved archive history and named archive threads | Streaming answers and complete removal of legacy shared history remain separate work |
| Tasks | Create/edit/complete/reopen, opt-in suggestions with sources, explicit acceptance and phone reminders | iOS notification delivery and cross-phone cancellation need acceptance |
| Recaps and goals | User-requested and opt-in scheduled daily recaps; goals, lifecycle and manual progress with source links | Scheduled generation has synthetic coverage; real model/device acceptance and suggested progress remain |
| Web | English primary interface, recording dates, provider settings, editable summary templates, inline regeneration controls with published provenance, archive controls and transcript player | Device acceptance and representative provider runs remain |

Goal pause/resume/achieve/abandon changes have been copied from the active Next
checkout into this integration branch. The donor checkout is unchanged. Their
transaction tests and Next widget flow pass, including conflicts, retries and
older-server capability handling. Physical iPhone acceptance remains open.

## Integration progress, 2026-11-27

The integration branch now contains both committed Local build identity and
Next full-sync changes. Web summary controls and goal lifecycle are integrated
against that combined tree. Automatic daily recaps now have an opt-in server
scheduler and Next settings; source implementation is complete with synthetic
acceptance, while live deployment/device acceptance remains open. The owner deferred external task/calendar integrations; continue
with local features. Recording-level provenance is now implemented in web and Next. Retrieval evidence
checks also found and repaired late-segment truncation and hybrid window loss;
14 fixed synthetic cases pass. Live archive answer quality is still unverified. Device acceptance
remains open; source implementation does not establish the installed version.

Reviewed local memory is implemented in this branch: source-linked proposals,
explicit confirmation/correction/rejection, confirmed-fact search, encrypted
history and deletion. Source changes invalidate search eligibility on read.
The hosted memory control plane stays disabled; the paired feature reuses Omi's
evidence contract with its own single local review authority. Model-quality and
physical acceptance are still open. Read-only archive MCP is now implemented
with a separate scoped key, canonical quote pagination and revision checks.
The real SDK stdio session, authorization, revocation and long-recording paths
pass on synthetic fixtures; connecting an assistant to the live archive remains
open. See [MCP setup](../tools/archive-mcp/README.md).

## Next work, in order

These are proposed implementation slices, not deployment approval. Finish one
verifiable slice before starting the next. Sizes are relative engineering scope,
not measured delivery dates.

| Priority | Work | Source to reuse | Completion evidence | Size |
| --- | --- | --- | --- | --- |
| Done in source | Reconcile committed `sky-dev` and Next changes on an integration branch | Local build/firmware display (`69284ad`); Next Live and full CV1 sync (`a07f8fb` through `667be72`) | Both ancestors retained in `4f72dc5`; donor worktree unchanged | Small |
| P0.2 | Accept the selected build on iPhone, then repeat a two-phone interruption run | Existing Local delivery and Next capture; do not replace either protocol | Calls, Bluetooth reconnect, locked screens, process restart, matching receipts, playable audio and explicit gaps; verify reminders, search, chat and summary return on iPhone | Medium |
| P0.3 | Accept legacy CV1 import separately from receiver-acknowledged recovery | Current Next importer and Local journal | Disposable test audio on iOS; full-sync Stop/reconnect/restart without duplicate accepted parts; report firmware-induced gaps honestly | Medium |
| Acceptance remains | Recording-level summary UX implemented | Existing Local web dialog/catalog and shared summary jobs | Published provenance and inline selection passed controlled browser/queue checks; verify real provider and iPhone return | Small–medium |
| Acceptance remains | Goal lifecycle and opt-in scheduled recaps implemented | Current goal work, Omi recap semantics and Local generation API | Synthetic retry/timezone/publication checks and Next tests passed; verify real model and device | Medium |
| P1.3 | Measure and improve retrieval before adding more AI behavior | Local semantic index and full-transcript search; Omi retrieval tests where applicable | A fixed set of archive questions tests sources from old, long and edited recordings; latency and stale/deleted-source exclusion are measured | Medium |
| Acceptance remains | Reviewed source-linked local memory implemented | Omi memory models, provenance and correction concepts; Local transcripts, providers and search | Extraction/review/source invalidation tested synthetically; real-model quality and device remain | Large |
| Connection remains | Read-only archive MCP implemented | Omi MCP contracts and Local paired authorization/search | SDK session and scoped authorization pass; select assistant and explicitly grant live archive access | Medium |
| Deferred by owner (2026-11-26) | Add one selected external task or calendar integration | Omi adapter for the chosen service; existing Local task IDs | Explicit external connection, stable local/external mapping, retries without duplicate tasks and visible failures | Medium |

P2.2 can precede memory if using the archive from other assistants is the more
valuable next workflow. A full integration marketplace is not a prerequisite.
The browser's existing `list_recordings` and `open_recording` tools are not a
standalone MCP server.

## Larger Omi features: defer until their foundation exists

| Feature | Decision and dependency |
| --- | --- |
| Automatic speaker identity | Separate enrollment, consent and correction flow after manual labels; reuse the configured diarization service and preserve uncertain matches |
| Memory graph and full Review | Build on accepted, source-linked memory and deletion semantics; start with review of proposed facts before graph visualization |
| Episodes and merged recordings | First define recorded-time grouping, source audio ownership and citation offsets; a logical collection is a smaller first slice than destructive audio merging |
| Dream and autonomous goal progress | Require trustworthy memory, review, bounded local jobs and visible evidence; never silently turn model suggestions into facts or progress |
| Full upstream Home v3 | Reuse selected components only after paired APIs express active capture, queued uploads and pending finish; a visual replacement alone adds no local capability |
| Phone-only STT | Separate offline-compute project with model storage, language, battery and device measurements; server-backed offline delivery already exists |
| Desktop Rewind, broad messaging, public sharing | Separate capture/access/OAuth projects; not required for the current personal audio workflow |
| Cloud billing, subscriptions and hosted job infrastructure | Outside this self-hosted product's scope |

## Synchronization and verification

At review time the committed branches diverged by one `sky-dev` commit and four
Next commits. Neither branch was a complete replacement for the other. The
original checkout already matched the Next pin; that does not establish that
GitHub has no newer commits. Before the next pin update, fetch and inspect the
actual delta using [the Next update procedure](../clients/next/README.md#updating-the-original).

Use `sky-dev` for new development of Omi Local Next and the shared local server.
Start feature branches from the current `sky-dev`. Open a release pull request
into `main` for an integrated release and tag the merged commit. Bring the
release commit back into `sky-dev` and keep `sky/omi-local-next` aligned as a
compatibility branch. The source pin for upstream Omi lives in
`clients/next/upstream.json`. Keep shared backend
models and contracts compatible, but adapt hosted identity, triggers and jobs
through Local's explicit paired surface. Track individual inherited-code
backports using [the existing audit](UPSTREAM_SYNC.md); do not merge unrelated
upstream history into the standalone snapshot.

For behavior changes run the relevant documented tests, then the applicable
offline/transport/Next gates. Web-only work needs no iOS rebuild. A pin, Flutter,
native-startup or BLE change requires its corresponding build and device gate.
Record implemented, tested, built, installed and deployed separately. Do not
infer the installed app from a branch name or an old device observation.

Keep clean-machine setup and restore into separate storage as release gates.
They remain open until a restored recording, transcript and conversation are
actually usable. Preserve the native/Docker storage boundary and existing audio.
