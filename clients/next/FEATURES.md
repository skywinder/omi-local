# Omi Local Next feature comparison

Next is the primary iPhone and Android client. The original Local iPhone app can still deliver its own queued recordings. Both clients can pair with the same self-hosted server. Next builds from a pinned upstream Flutter tree and uses Local's durable audio journal.

This comparison covers the 34 features reviewed against upstream Omi. Its baseline is the November 26, 2026 review. For the current work order, see the [repository plan](../../docs/REPOSITORY_PLAN.md). For steps and version-specific device evidence, see the [migration ledger](README.md#migration-ledger), [v0.1.0 device results](../../docs/releases/v0.1.0.md#device-verification), and [original acceptance log](https://github.com/skywinder/omi-local/blob/v0.1.0/clients/next/FEATURES.md).

## Capture and processing

| Capability | Local and paired server | Next and remaining work |
| --- | --- | --- |
| Personal server | Named pairings, key storage, status, and launch presets | Save multiple servers, verify a key, migrate a single pairing, and inspect status. Each outbox belongs to its original pairing. |
| Phone microphone | Captures phone audio | Captures and journals audio on both platforms. An incoming call on a physical iPhone still needs a recovery test. |
| Delivery after an outage | The phone retains each part until the server confirms its checksum | Uses the same journal. Pixel retained the same bytes across restart and a mismatched receipt. An older installation owns its own pending parts. [Delivery contract](../../docs/RECORDING_DURABILITY.md) |
| CV1 controls | Capture, button actions, mute, and Bluetooth recovery | Start, stop, mute, finish a conversation while listening, and optionally start on connection. Manual stop and mute survive reconnects. |
| CV1 storage | Imported audio uses the same phone journal and server receipts | Import the oldest clip, a batch, or the available archive. Resume from checked packet positions. Pixel batch import was verified. Firmware 3.0.21 can advance the ring before phone storage is confirmed. [Recovery limits](../../docs/WEARABLE_RECOVERY.md) |
| Final transcription | Select a local engine or an explicitly configured server | View stages, edit supported profiles, and retry eligible failures. Availability depends on the server and selected model. |
| Speaker labeling | File and live pipelines support configured diarization | See named turns, service, speaker count, and processing failures. Live and final speaker labels have separate states. |
| Live text and translation | Independent streams, adjustable buffering, and provider-backed translation | Draft and confirmed turns, timestamps, speakers, source, and translation. Late results belong to the language selection and stream that requested them. |
| On-device transcription | The supported local workflow processes audio on the paired server or selected provider | Upstream phone-side transcription would need model packaging, device benchmarks, and an explicit processing choice. |

## Library and playback

| Capability | Local and paired server | Next and remaining work |
| --- | --- | --- |
| Conversation list and detail | Saved recordings and processing states | Paginated archive grouped by local day, category filters, and pending cards. Recent cards survive a cold offline launch. |
| Playback | Web playback and seeking | Stream WAV ranges, skip ten seconds, change speed from 0.75× to 2×, follow a turn, or start playback from a timestamp. |
| Find within a conversation | Transcript search in the web player and legacy client | Search the full transcript and jump to the matching turn. |
| Archive keyword search | Server searches transcripts, titles, and summaries, including file-backed text | Results carry the matching turn and timestamp. |
| Semantic search | Optional local CPU worker and index | Select meaning search and open a cited passage. Keyword search remains available independently. |
| Editing and favorites | Server persists edits against stable turn IDs and retains them on reimport of the same result | Edit a title, turn text, or favorite. Edits against a different transcription result require separate reconciliation. |
| Folders | Server stores folders and retains manual assignments on reimport | Create, rename, reorder, delete, move, and filter. Bulk moves handle up to 100 recordings. Reduce folders with more than 450 recordings before deletion. |
| Speaker names | Shared people directory with checks against stale assignments | Assign a name to one turn or a speaker group, mark yourself, or remove a name. Cross-recording voice identification still needs enrollment and correction rules. |
| Merge recordings | No complete local flow | Requires source-audio references, turn offsets, and recovery after an interrupted merge. |

## Assistant and planning

| Capability | Local and paired server | Next and remaining work |
| --- | --- | --- |
| Structured summaries | A shared background queue reads the full transcript, including saved edits | Choose a model and template, regenerate, and open a cited turn. The previous summary remains readable during generation. |
| Recording chat | Stores history with the recording and uses the configured model | Ask follow-up questions and open cited turns. Replies arrive as a complete response. |
| Archive chat | Keyword and semantic retrieval with saved owner-scoped history | Resume the shared chat or create named conversations, refresh them on another paired phone, and delete a named chat. Deleting legacy shared history needs a compatibility decision. |
| Tasks | Server validates the source of a suggested action and handles repeated requests | Create, edit, complete, reopen, and explicitly accept suggested tasks. Reminders are enabled per phone. |
| Daily recaps and goals | Server stores recaps, goals, and progress events | Generate a recap, schedule it in a chosen time zone, link progress to a recording, and pause, resume, complete, or abandon a goal. Progress suggestions are still open. |
| Reviewed memory | Stores facts with versioned Omi sources | Review suggestions, accept or correct a fact, open its quote, and search accepted facts. An edited or unavailable source excludes the fact from search pending review. [Memory contract](../../docs/BACKEND_PARITY.md#reviewed-local-memory) |
| Review, Episodes, and Dream | No standalone local implementation | Each needs its own data model and processing contract. |

## Sharing and upstream-only features

| Capability | Available locally | Remaining work |
| --- | --- | --- |
| Share a recording or task | Export TXT or WAV through the phone's share sheet. Both formats were verified on Pixel. | Public links and shared tasks need access control, revocation, and recipient acceptance. |
| Todoist, Asana, ClickUp, and Google Tasks | Local tasks are available. | External task adapters need OAuth and durable links between local and external items. |
| Google Calendar and messaging | No integrated local calendar or messaging channel. | Each service needs its own authorization. iMessage needs a bridge. Upstream WhatsApp was waitlisted at the review date. |
| MCP access | Separate read-only key for listing, searching, reading, and citing archive transcripts. | Verify the chosen assistant against its intended archive. [MCP setup](../../tools/archive-mcp/README.md) |
| Rewind and Mac screen history | Mac hosts the audio library. | Screen capture and indexing require a desktop client. |
| Home v3 and pending Finish | Next has its own capture controls, active timer, processing cards, and grouped Finish receipts. | Porting upstream Home requires reconciling recording IDs and interruption recovery. |
| Audio held for a plan limit | The local journal and processing cards show delivery and processing delays. | Local provider delays can be surfaced without upstream subscription logic. |
| Date or timed reminders | Next can schedule a task for a date or exact time. A date-only reminder uses 09:00 in the phone's time zone at save time. | Changes from another phone take effect on the next foreground sync. Physical iPhone notification delivery needs verification. |
| Summary templates | One server catalog for initial summaries and regeneration. Next can select a model and instruction and preserves an edited title. | Verify the full background regeneration flow on iPhone. |

## Local features carried into Next

- **Recording.** Finish keeps the CV1 listening. The session timer advances through silence. Battery and input are visible in the archive and Live. A five-second gap without new CV1 packets produces a warning that clears when packets return. Stop cancels interruption recovery.
- **Device diagnostics.** Inspect battery, signal, throughput, disconnect history, unread audio, free storage, clock status, and ring overwrites. The microphone test measures speech, background, and peaks. Gain ranges from 0 to 8, with presets at 2, 4, and 6. Separate tests compare quiet speech after silence and after waking the microphone.
- **Offline use.** Each pairing caches up to 30 recent cards. A separate manual download includes audio, full transcript, and summary within a shared 1 GiB limit per phone. Upload retries identify connection, TLS, pairing, server, receipt, and local-file errors.
- **Recording detail.** Copy a summary, transcript, or ID. Export timestamped TXT or the original WAV. Open processing results for one grouped recording, including partial and failed results. Retry an eligible failed stage using saved audio and successful intermediate results.
- **Navigation.** The archive includes settings, favorites, categories, folders, filters, and CV1 battery access. App shortcuts support device selection, task creation, and mute or unmute during capture.
- **Web and mobile consistency.** Both surfaces use the same archive annotations, edits, summary queue, and provider settings. Processing cards show the failing stage, attempts, and an explanation when older records have no diagnostic code. The Live monitor distinguishes paired sources from sources currently delivering frames.

## Verification and limits

| Workflow | Observed result |
| --- | --- |
| Two phones recording through an outage | An iPhone Air and Pixel 5a each delivered seven contiguous parts with matching receipts. The server recovered 91.58 and 85.88 seconds. Both transcripts contained control words from before, during, and after the outage. |
| CV1 Bluetooth recovery | After toggling Bluetooth on Pixel, Next reconnected and the server produced a 21.88-second recording containing speech from before and after the gap. Audio spoken during the Bluetooth outage was missing. |
| Stored CV1 audio | The Pixel retained an offline 34.24-second batch. After reconnect, the server confirmed the same SHA-256 and decoded 1,712 frames without errors. After a separate Bluetooth interruption, manual import resumed after the last saved packet. |
| CV1 gain and wake threshold | On Pixel, the same quiet phrase at 6/8 delivered zero of five seconds after silence and five of five after waking the device. Raising gain from 6/8 to 7/8 increased speech by 4.6 dB and background by 5.7 dB. The original setting was restored and read back. Calibration created no archive recordings. |
| Long transcripts and summaries | Tests covered a 1,500-turn recording, edits near its end, playback from a citation, and resuming an interrupted summary from two completed chunks. The resumed summary cited 25 turns, including three near the end. A separate recovery run used 221,378 characters. |
| Playback and reminders | iPhone played a 2 h 49 min recording starting from a search result at 1:02:27. Pixel received a background task notification. WAV export matched the server checksum. |
| Release verification | The repeat runs on physical iPhone and Android produced six readable recordings and 19 confirmed parts. [Release results](../../docs/releases/v0.1.0.md#device-verification) |

Hardware checks still open include long outages with both screens locked, incoming-call recovery on iPhone, Bluetooth restoration after iOS terminates the process, and physical CV1 import on firmware that acknowledges durable storage. A successful short run does not establish endurance.

## Upstream revisions

The original comparison used [4ff550235f](https://github.com/BasedHardware/omi/commit/4ff550235fc0ac6f6cc11168297a986e60a6a2b8). Next uses [782a793765](https://github.com/BasedHardware/omi/commit/782a7937650c8e0f71455ebc0aae182eb86ab28b).

- The November 25 upstream update shortened experimental batch chunks from 60 to 15 seconds, stopped polling empty onboarding graphs, and waited for microphone file operations in tests. Paired uploads use Local's receipt protocol.
- The November 26 update resolved Finish by source recording ID and checked bootloader compatibility before CV1 firmware updates. Next uses group receipts for Finish. Its UI does not offer the upstream firmware updater.
- Porting an upstream feature requires both an enabled local route and permission for its method and path. Multi-user libraries would also require ownership rules for audio, transcripts, and search results. [Local server routes](../../backend/main.py) · [Repository plan](../../docs/REPOSITORY_PLAN.md)
