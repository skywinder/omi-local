# Omi Local Next

Omi Local Next is the primary development client for the paired Omi Local server.
Its iOS application identifier is `org.omilocal.next`. Pair it with the server's
app key in its own Keychain. The existing app owns its pending phone recordings.

The build starts from the complete Flutter app tree at the Git revision in
[upstream.json](upstream.json). The self-hosted Flutter entry point is
`lib/main_local_next.dart`. Upstream supplies the conversation wire model,
theme, localization, and presentation components. The Next overlay owns the paired
session, library navigation and platform startup. The two clients share the
same Local audio journal source and upload receipt protocol.

## Architecture decision, 2026-11-24

Use current upstream Flutter for the product UI and the paired Local server for
recordings and processing. Keep the established Local app available during the
transition and use it for urgent fixes to the current capture workflow. A
self-contained widget or bug fix is cheaper to backport when its data and tests
already exist in Local. Product features that span screens, models and state are
cheaper to keep current in Next. Between the October 28 and November 24 original
revisions, 1,250 files changed under `app/`. Even the subsequent pin update from
`4ff5502` to `ba4d7ac` touched 114 files there. Next accepted that update through
its pinned source, compatibility checks and a separately signed iPhone build.

At the detail milestone, seventeen upstream Dart files were imported directly
by the Next overlay. Seven of those
changed across that interval and four changed between November 17
(`501a543f3e`) and November 24. The search widget and theme were identical
in all three trees. The conversation models, transcript widget and generated
localization changed in both intervals.
The upstream native project also added a PostHog Swift source file. This static
comparison covers direct imports only. A clean build still needs to catch changes
in their dependencies and a device test needs to catch behavioral changes.

The Next bootstrap owns navigation and pairing. The detail route composes the
original Omi transcript, markdown and note source widgets over the paired
archive. The pinned presentation adaptations live in
[`presentation.py`](presentation.py). Upstream's `ConversationDetailProvider`
accepts a read function. Its production route also starts Siri, summary
experiments, identity and live services. Enable actions when the paired server
implements their contracts. Home v3 separately reads
`GET /v1/conversations/live`; the Local v1 archive alone cannot drive its
listening and pending-finish states.

The server owns the durable recording, transcript, processing state and selected
inference provider. The phone owns queued parts until the same paired server
confirms their identity and hash. Keep those responsibilities when adding a
cloud-designed screen. For instance, a search inside an open transcript can
reuse loaded text. Search across recordings needs a local index or query API.
Chat about one recording needs a source-scoped transcript, a selected model,
and an answer linked to the source. A summary generator alone provides none of
the chat session or citation contract.

Keep the connection-specific state and authorization in the paired client.
Give each enabled upstream provider the data operations it needs through a
constructor or an adapter. The archive uses upstream `ConversationApi` for
list and detail with a custom, paired `ApiSend`. Next owns paging state because
the production `ConversationProvider` also writes its shared archive cache,
reconciles Spotlight, and observes cloud merge notifications. The archive
composes Omi's day headers and state tiles, with row actions limited to opening a
recording. Capture remains on the shared Local journal, with live preview as a
separate stream. For provider settings, status and future product screens, use
paired server capabilities to
decide which actions to offer. A missing capability keeps the rest of the archive
usable. Changing the default HTTP base would leave account identity, side
effects and state semantics spread across upstream providers and native startup.

Close the capture and replay acceptance gates before switching everyday use to
Next. Verify archive search and both chat modes on the iPhone. Connect
Home v3 once Local can represent a recording in progress, a queued upload and
a server-side finish with their distinct identifiers and transitions.

Evaluate each upstream update with a clean materialization, the server
contracts for enabled features, and the same screen on an older paired server.
Changes to Flutter, native startup, or BLE need their own verification.
Repeated edits inside upstream widgets or new Next-only versions of whole
product pages signal that the integration boundary needs to move into their
provider or API. Keep the pin and any upstream compatibility edits reviewable
together. Run this check again as each product feature adds new dependencies.

## Prepare and verify

Use a local clone of [BasedHardware/omi](https://github.com/BasedHardware/omi)
containing the pinned revision and Flutter from the version in the pin.
From this worktree, run:

```sh
python3 clients/next/prepare.py /path/to/omi
bash clients/next/check.sh /path/to/omi
```

The prepare command prints the generated app directory under `.local/clients/next`.
Change source in this directory's tracked overlay or the Local shared sources.
Changes made directly in the generated app are disposable. For the legacy app,
use the Flutter version declared in the root app's pubspec.

After the Local `make test-offline` and `make test-transport-app` checks and
Next checks pass, use the Next SDK on PATH for an iOS build. The launcher prints
the build/reuse decision and verifies the package identity, entitlements,
signature, and executable digest before installation:

```sh
python3 clients/next/iphone.py /path/to/omi --simulator
python3 clients/next/iphone.py /path/to/omi --install
```

Use `--simulator --install` for a simulator. A device install requires a paired,
available iPhone and a provisioning profile for the Next bundle.

## Android debug build

Use the pinned Flutter SDK, JDK 17, Gradle 8.14.2 and Android SDK (API 36,
NDK 28.2.13676358). Set `ANDROID_HOME` and run from this worktree:

```sh
python3 clients/next/android.py /path/to/omi
adb install -r /path/to/app-debug.apk
```

Use the exact APK path printed by the build. Android uses the separate
`org.omilocal.next` package with its own saved servers and audio outbox. The
debug build supports the archive, playback, server settings, phone microphone
with Live preview, and CV1 discovery and capture. Grant the Android Nearby
devices permission when scanning for a CV1. Physical background recording
requires separate verification.

## Mobile settings and diagnostics

Open the gear in **Conversations** for recording boundaries, the local upload
queue, saved servers, processing, Live speaker settings and Omi CV1 diagnostics.
Audio uploads include the phone platform and model when available so the web
library can show them alongside the microphone used. On iPhone, the upload
uses the model name or hardware model code when the name is unavailable.

In Conversations, the Omi Bluetooth control sits beside CV1 recording.
The Bluetooth menu shows short IDs for nearby and connected devices so
identically named pendants can be distinguished.

Device Diagnostics reads charge and signal measurements from the wearable.
The recording screen shows the connected CV1's battery percentage after its
first measurement.
The signal chart refreshes every three seconds while visible, including during
capture. Battery notifications update both the status and history on supported
firmware. The day and week charts and connection journal retain observations
on this phone for seven days. RSSI samples in the graph cover the last ten
minutes. Connection events can be copied with timestamps, reason codes, last
measurements and link duration. The journal does not contain Bluetooth
identifiers or audio.
LED brightness and microphone gain require the matching CV1 firmware feature
and a confirmed Bluetooth write. Configure double tap in the same screen.
The default preserves the existing behavior of saving the current audio part.

## Saved servers

Tap the current server name in **Conversations** to open **Saved servers**.
Add or edit a server to enter its name, address and app key. The active server
card opens diagnostics and processing settings. Its menu contains **Disconnect**.
Choose **Connect** to verify an address and key and make it active. A failed
check leaves the previous connection selected. Stop any active recording before
switching. Pending parts stay bound to the original address and key, and retry
when you reconnect to that server. Clear the pending parts through normal
delivery before removing or replacing the corresponding credentials.

The first launch migrates an existing single-server Next pairing into its own
Keychain catalog and retains its ability to journal offline. The existing
Omi Local application keeps its separate data.

To prefill saved entries from a private server preset file, use the format and
permissions described in [Local iPhone setup](../../docs/LOCAL_SETUP.md#prefill-saved-servers).
Opt in at installation on a connected iPhone:

```sh
python3 clients/next/iphone.py /path/to/omi --install --with-server-presets
```

The launcher reads the file selected by `OMI_LOCAL_SERVER_PRESETS_FILE`, or
`.env.servers` by default. It can use an existing `.env` pairing when there is
no preset file. The launch handoff imports entries once into Keychain and keeps
manual edits and previous deletions. Select a saved entry to connect.

To connect a newly imported preset automatically, pass its ID with
`--default-server` along with `--install --with-server-presets`. Next verifies
the pairing and restores it from its Keychain on subsequent launches. If the
first verification fails, Next keeps the saved server and retries at the next
launch. A verified server already selected on the phone takes precedence.
Explicit Disconnect clears the automatic connection.

When the Xcode developer tunnel is unavailable, add `--usb` to install the
attested app and copy the one-use preset into its private cache via
`ios-deploy`. Open Next once after installation. The app consumes the file
and removes it from the cache. The address and key are supplied by the private
preset file at runtime.

## Server status

Open **Server status** from the archive to see confirmed paired access, audio
received by the server, Live transcription and Live diarization. The same
screen shows final transcription, diarization and summary readiness when the
server reports fresh stage data. The Local and Next clients share the wire
model for `GET /v1/local/status`.

Next refreshes diagnostics while the screen is visible in the foreground.
Older servers without the endpoint show an unavailable-diagnostics state.
Polling ends when the screen closes and resumes when foreground access returns.

## Summary templates

Open **Processing → Summary Template** to add or edit a named prompt. Enable
**Use for new recordings** to make it the default when the server snapshots the
applied summary provider for future jobs. If another client saved in the
meantime, refresh before editing the shared catalog again. The editor works
with Omi Local servers that implement the same summary settings route.

In an open recording use **Regenerate Recap** to select a prepared model,
template and an optional prompt edit. Next sends the saved transcript after
you confirm the destination. The current recap stays available until the
replacement is published. A concurrent transcript or recap edit requires a
refresh. Very large or preview-only transcripts are outside this request.

## Daily recaps

Open **Daily Recaps** from the archive and select a date. Next previews the
available recordings and shows the applied summary model and host before
you confirm. Generation uses saved recording recaps or transcript excerpts,
and the summary links highlights and decisions back to their recordings.
Next marks incomplete coverage. A new local generation replaces the same
day's local recap. Existing recaps stay in the same archive.

## Goals

Open **Goals** from the archive to create a goal or review progress. A target
and unit are optional. **Log progress** saves a note, with an optional new
value for goals with a metric. Open the same action from a recording to link
it as the source, including when you reached the recording from a daily
recap. Next loads the current goal before editing and asks you to reopen it
if a concurrent change invalidates that version.

## Archive search

Open **Search conversations** in the archive. Search covers saved transcripts,
titles and summaries on the paired server. Tap a transcript match to open the
line. When WAV playback is available, Play starts at that line's timestamp.
Use **Show more** to continue from the last scanned page.

`POST /v1/local/conversations/search` reads the current owner's Firestore records
in bounded pages and reuses Omi's transcript snippet format. It covers records
saved before this feature and reflects edits without a separate index. Search
uses the same checksummed transcript as detail for file-backed recordings. One request expands at most one such file. Bastion serves this route. Search duration for a rare term grows with the archive size.

## Chat about a recording

Open a recording with a transcript and tap **Ask Omi**. Next displays the
currently applied summary model and host and asks before sending anything.
Each request can send the question, excerpts from the selected recording and
up to three recent turns to that provider. A model or endpoint change requires
fresh confirmation. The response arrives as one answer.

The paired server stores encrypted turns under the recording in its local
Firestore. It verifies that each cited excerpt was supplied to the model.
Tap a citation to return to the transcript and seek to that excerpt when
audio is available. Next checks that the cited text still exists in the
current transcript before opening it. A long transcript may use selected
excerpts, which the answer labels. The active paired server needs the chat
endpoint and an applied summary provider.

## Chat across the archive

Open **Search conversations** and tap **Ask about the archive**. The server
scans saved transcripts belonging to this pairing, selects excerpts that
match the question's words, and checks source versions before and after
inference. The model can receive excerpts, recording titles and dates and
recent turns after confirmation. Tap a citation to open the matching
recording. Follow-up context lasts while the chat page is open.

The screen reports when the scan reaches its time limit. Search by meaning,
a persistent index and archive chat history are separate parity items.

## Edit a saved recording

In a finished recording, use the menu to rename it, add it to favorites or
correct a transcript line. The archive's **Starred** filter uses the server's
paged starred query. Transcript edits preserve segment IDs and timestamps
so archive search and playback can continue to reference the same line.

The server compares the prior value inside its write transaction and returns
the saved conversation. When another edit wins, Next keeps the draft on
screen. Re-importing the same local processing result preserves the edits.
A different processing result is a separate recording and retains its own
transcript. Edits require an updated paired server.

## Organize recordings into folders

The archive also has a **Categories** filter using the Omi conversation
model's category names and an emoji for each category. It combines with folders and favorites.
The filter walks normal archive pages, so use **Show more** to reach older
matches. Next shows the subject emoji if the conversation has one and uses
the category emoji in place of a generic tile for classified recordings.

On servers that advertise `local_recording_categories_version=1`, open a completed recording and
choose **Change category**. The saved category applies wherever the recording
appears in Next, and later server processing preserves the owner's choice.
New local summaries can assign a category and subject emoji using the selected
summary model. Existing older recordings can keep their original metadata.

Tap **Folders** in the archive to create or rename a folder or filter the
archive. A folder filter can be combined with **Starred**. In a finished
recording, use **Move to Folder** to select a folder or remove the assignment.
The paired server uses the existing owner-scoped folder collection and
preserves manual assignments on replay. Open a folder's menu to change its
order or delete it. Deleting a regular folder leaves its recordings unfiled
in the archive. Use **Select recordings** to move up to 100 recordings at a
time. A folder with more than 450 recordings needs to be partly emptied
before deletion so the server can commit the move and delete together.

## Name a speaker

Tap the speaker label in a finished transcript to choose a person, add a
name, mark yourself or clear the label. The picker can apply the same choice
to the matching speaker group within this recording. Names use the paired
server's existing people collection. Assignments preserve segment text and
timestamps. Automatic recognition and voice samples are tracked separately.

## Tasks

Open **Tasks** in the archive to create, edit, complete or reopen a task.
The recording menu can create an item linked to that conversation. **Add task
from transcript** pre-fills the selected line and asks for confirmation
before saving. A linked item can open its recording at that line.
**Suggest tasks** shows the applied summary model and its host before sending
excerpts from the selected recording. Review the cited line and choose **Add
Task** for each item you want to keep. Next marks incomplete transcript coverage.
If the cited text changed, generate suggestions again before adding the task.
Tasks use the paired server's canonical task store. The local edits keep
notification and external task-sync behavior outside this workflow.

## Recording from the phone microphone

Next waits for PCM before showing active audio. It shows an audio-session
interruption on the home and Live screens. If frames stop without an interruption,
it reopens the recorder once and keeps the same local recording and preview.
If frames still fail to arrive, it closes the recording and keeps the audio already
accepted by the journal. Stop cancels any pending recovery.

## Recording from CV1

Pair Next with your Local server, open **Connect Device**, and choose the
wearable. After the link is ready, start from the CV1 button or the recording
control in Next. A single press starts or stops. A double press during capture
publishes the saved prefix and keeps listening. Mute pauses audio until resumed.
The app shows link state separately from the first audio written to disk.

Switching between CV1 and the phone microphone seals the previous source first.
A link reconnect preserves current Start, Stop or Mute intent during this app
run. Next remembers the accessory across launches. Capture starts idle after a
cold launch. It can reconnect without prompting when Bluetooth permission was
previously granted. The new bridge uses CoreBluetooth read and notification
operations for the pinned CV1 services.
Recovery from the wearable's offline ring has separate custody requirements.
See [wearable audio recovery](../../docs/WEARABLE_RECOVERY.md).

Long-press the Next app icon for device settings and, on a task-capable paired server, **Add Task**. During CV1 capture the menu also exposes the current mute or unmute action. Shortcuts are scoped to their saved pairing.

In **Settings and diagnostics**, **Record on CV1 connection** enables automatic
capture for the active pairing on the next successful CV1 connection. It starts
off. An explicit Stop waits for a manual Start, and a muted session reopens
muted. Selecting the phone microphone also suspends automatic CV1 capture.
Android remembers a CV1 after a successful audio-service handshake; **Forget
device** clears this selection.

## Live transcript

While recording, the strip above the archive filters shows the current
recognition status and the latest line when available. Tap it to open the
same full Live transcript. The Live button keeps the last session accessible
after recording stops.

Open Live while recording with the phone or CV1. The screen uses the original
Omi transcript list and shows where live processing runs. Translation can use
one target or two languages selected for the paired server. The Live screen
shows the current input and elapsed time. For CV1 it also offers Mute, Unmute,
and Finish conversation and keep listening. Stop is available for either input.

Next sends a frame to the paired `/v4/listen` preview socket after the journal
flushes it to disk. The separate part upload owns retention and durable
delivery. A preview outage leaves the recording in the journal. Socket
reconnection keeps text already displayed for that recording and starts a new
live draft from the newly sent audio. The server's existing Live STT and
translation settings select the providers. See [live preview](../../docs/LIVE_PREVIEW.md)
and [provider setup](../../docs/PROVIDERS.md).

Use the tuning button on the Live screen to set a limit of one to four voices
when the paired server and Live provider support it. A save uses the current
server revision. Refresh before retrying a conflict or an uncertain write.
The saved limit applies when the server opens a new recognition stream. The
current stream shows its separately acknowledged limit. **Conversation
boundaries** is available in capture settings and Live settings. It selects
one recording per part, one conversation until Stop, or separation after a
chosen silent interval. The grouped options appear on a compatible paired
server. A saved change applies to the next recording. Conversation publication follows the server's durable sample clock.
Live drafts still represent the capture session.

## Processing profiles

Open the processing controls from the paired library. Next shows the server's
effective profile and the prepared choices for each supported stage. Live STT,
final transcription and diarization are selected separately. The summary
and translation cards show the configurations already published on the server.

Select a prepared profile and confirm while capture is idle. Confirmation
uses the registry revision read by the screen and waits for the effective
profile returned by the server. After a conflict or an uncertain result,
refresh before confirming again. Next can create, edit and test drafts for
external Live STT, OpenAI-compatible final STT and Mycelia diarization, and list
available models for final STT. The connection test reads provider metadata.
Saving a draft leaves the effective profile in place. A saved credential can
be replaced or removed without displaying its value. Editable inactive drafts
can be deleted after confirmation. Native model paths and summary and
translation drafts remain server-managed.

## Updating the original

Fetch the original repository, inspect changes under `app/` since the recorded
commit, and update `upstream.json` on a feature branch. Check the Flutter pin
against the original's mobile CI. Each revision materializes in a new directory.
Review new native targets, permissions, and APIs consumed by the enabled screens.
Run the Next checks, legacy transport checks, and iOS build and device checks
for the changed inputs. Each enabled feature needs a compatible server endpoint
or a detectable capability on the paired server. Record the results below.

From the Local worktree, set `omi_source` to the original Omi checkout. These
commands compare source revisions without changing the paired server or its data.

```sh
pin=$(jq -r .commit clients/next/upstream.json)
git -C "$omi_source" fetch origin main
git -C "$omi_source" log --first-parent --oneline "$pin"..FETCH_HEAD -- app/ backend/
git -C "$omi_source" diff --stat "$pin" FETCH_HEAD -- app/ backend/
```

After selecting a revision, update the pin and run
`bash clients/next/check.sh "$omi_source"` with the pinned Flutter SDK.
Keep pairing, audio delivery, Live, and archive reads on the user's own server.

For backend updates, compare the shared archive and processing contracts in
[Backend compatibility](../../docs/BACKEND_PARITY.md). The original and paired
deployments have separate authentication and audio processing boundaries.

## Migration ledger

The [feature inventory and port estimates](FEATURES.md) compare the original
app, the existing Local client and the new client by user-visible behavior.

On 2026-11-24, the Local offline suite passed and `make test-transport-app`
passed 473 Flutter tests and the analyzer ratchet. The Next analyzer and seven
Next Flutter tests passed on its own pinned SDK. Those tests exercise pairing,
authorized reads, key rejection and redirect handling, the capture queue across
restart, and the detail/search UI on fixtures. Flutter and Xcode produced a
Debug-dev simulator app for `org.omilocal.next`. Its signature, identity and
entitlements passed verification. This required reconciling the original watch
marker, dev scheme and Pod deployment settings with the Next target. An iPhone
build, installation and end-to-end microphone/CV1 acceptance remain open.
On the test simulator the launcher reused the attested artifact and installation
succeeded. The installed executable matched the original SHA-256. A subsequent
launch of that exact build rendered the pairing form and its Connect button.
Pairing and capture acceptance against a running local server remain open.
With the CV1 assembler, the Local transport gate passed 477 Flutter tests and
its analyzer. The Next analyzer and all nine tests passed. The detail fixtures
cover opening a cited line, prioritizing the saved edited overview in both
detail and search, copying summary text, and rendering Markdown without opening
image URLs or files. The presentation adaptation applied twice identically on
three donor revisions, including November 17 and the current pin. That check
did not build the other revisions.
The updated detail client at `f459b5b` also built successfully in Xcode for the
simulator. Its bundle identity and signature passed attestation. The installed
simulator app used for the pairing-form observation was the earlier build.

After CV1 integration, the Next analyzer and all 17 Flutter tests passed. These
include rejected device selection, button-driven handoff from a held phone
seal, retired subscription events, Opus custody and link recovery. The Local
offline suite and all 478 transport tests passed. The native Swift tests verify
button decoding, subscription fencing and Runner identity.

The physical `Profile-dev` build at `4092769` passed signature, entitlement
and provisioning checks. The launcher reused that exact package and
CoreDevice confirmed installation and launch of `org.omilocal.next`. A separate
inventory query found both clients on the iPhone and matched the running Next
process to the installed bundle. Physical server pairing, CV1 audio and playback
are still open.

An authenticated, read-only Bastion probe on November 24 confirmed the current
deployment advertises durable delivery v2 and declares the local preview route.
Its offline policy permits the listen WebSocket. Its profile did not advertise
the Next WAV playback contract. This check queried capability and status
metadata without opening a conversation, recording or live audio session.

The Live change passed all 24 Next Flutter tests and the analyzer. The
loopback integration test delivered the same PCM used by the journal over a
paired WebSocket and through the durable part upload. Transport tests cover
redirect refusal, revoked credentials and corrections across reconnect.
The widget test covers drafts, translations, saved language choices and Stop.

The original checkout and the Next pin advanced from `4ff5502` to `ba4d7ac`.
Native project materialization, the Next analyzer and all 29 Flutter tests
passed against that revision. The processing fixtures cover independent stage
activation, the capture interlock, revision conflicts and uncertain writes.
A read-only authenticated Bastion request confirmed all five stages in the
deployed registry. Its active selections were not changed.
The signed `Profile-dev` build from `0c32b8d` includes Live and the processing
screen. The launcher reused that exact package and CoreDevice confirmed its
installation and launch on the physical iPhone. The device inventory showed
both apps, and the running Next process matched its own installed bundle.

The processing draft editor passed the Next analyzer and all 34 Flutter tests.
The focused harness and paired-auth Python suite passed all 70 tests. These
cover separate save and activation, key handling, the STT model catalogue, and
deletion of an inactive draft with the current revision. Read-only Bastion
checks confirmed the registry and the deployed routes. The new editor's iOS
build was blocked by insufficient stable free space on the Mac, with less
than 1 GiB available during verification. Device acceptance and writes to a
test profile on a running server remain open.

The paired archive now uses the upstream `ConversationApi` for both reads and
shows Omi's day headers and state tiles. List and detail keep Local recording
metadata. Paging uses the count of consumed records and the server end marker
when available, with an offset fallback for older servers. The paired transport
allows only the archive's two GET routes, rejects redirects and clears the
session on credential rejection. All 38 Next Flutter tests and the analyzer
passed, including local-day ordering, interrupted pagination, opening details,
malformed rows and credential revocation. The source adapters applied
deterministically at both `4ff5502` and `ba4d7ac`. A live Bastion archive probe
was blocked at SSH authentication, before any HTTP request.

The focused archive, Local audio delivery, and route-policy Python suites
passed all 46 tests. The signed iPhone `Profile-dev` package for `09f15b2`
includes the archive and the processing draft editor. The executable SHA-256
begins with `e71fd8ee7d49e89c`. The bundle identity, strict signature and
entitlement checks passed. The preceding signed package and its attestation
are retained locally for rollback. Xcode found no connected iPhone after the
build. Installation of the new package and physical archive, recording and
playback acceptance remain open.

Saved servers passed the Next analyzer and all 46 Flutter tests. The scenarios
include single-pair migration, failed verification, switching after capture,
retaining an inactive owner's credentials while audio is pending, and resuming
delivery to the original server after recording on a second one. All 34 native
identity and installer handoff tests passed with synthetic presets. Receipt
delivery and preset ingestion on a physical iPhone remain open.

The signed iPhone `Profile-dev` package for `1921fd6` includes saved servers
and the native one-use preset handoff. Its executable SHA-256 begins with
`804ae52121419695`. The independent bundle identity, signature and entitlement
checks passed. The preceding `09f15b2` package and attestation remain available
for local rollback. Xcode found no connected iPhone after the build, so physical
installation and preset import remain open.

Live speaker tuning passed all 48 Next tests and the analyzer. The Local offline
suite, 478 legacy transport tests and the analyzer ratchet passed. The focused
backend rerun passed 170 tests. Loopback tests covered independent saved and
current-stream limits, continued audio delivery, and refresh after an uncertain
write. Provider acknowledgment was exercised with a simulated Live server.

The signed `Profile-dev` package from `266bb45` uses `org.omilocal.next` and
the pinned Omi revision `ba4d7ac`. Its executable SHA-256 begins with
`b65984945ced0f6e`. The previous package `1921fd6` was preserved and rechecked
for local rollback. The connected iPhone initially needed an unlock. After
unlock the host still saw the iPhone on USB, but CoreDevice did not have a
connected tunnel for installation. The signed package is ready for a retry.

The server status screen passed all 51 Next tests and the analyzer. The Local
offline suite, all 478 legacy transport tests and the analyzer ratchet passed.
Tests covered paired authorization, older servers, stale readiness and polling
when the app or screen is hidden.

The signed device package for `2a93827` passed independent signature and
entitlement verification. Its executable SHA-256 begins with `e71746706a3c154d`.
The prior `266bb45` package was verified and saved for rollback. The physical
USB device matched one paired iPhone, but its CoreDevice tunnel was unavailable
and the install preflight found no eligible phone.

Archive search passed the Next analyzer and all 53 tests, plus the offline
backend and existing mobile transport suites. An isolated Firestore run found
a compressed transcript on the third page after both cursor records were
deleted between requests. The UI test opened the original transcript at the
matching segment. Next distinguishes the older offline server's route
rejection from a temporary service failure.

The signed `Profile-dev` device package from `0c2eb38` passed independent
signature and entitlement verification. Its executable SHA-256 begins with
`cdb37b333e178502`. Package `2a93827` was verified and retained for rollback.
The Mac enumerated an iPhone over USB. CoreDevice had no eligible connected
phone at installation preflight, so installation and device playback remain
pending. Archive search on the active server also requires a server update.

Single-recording chat passed the Next analyzer and 54 tests, the offline
backend suite and all 478 existing mobile transport tests. An isolated
Firestore and harness run exercised model confirmation, transcript owner
scope, invalid citations, encrypted history, follow-up turns, retry and
recording deletion. The Flutter test confirmed that tapping a citation returns
to the matched line after refreshing the transcript.

The signed `Profile-dev` package from `7de7940` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`029125a367a5cda5`. The signed search package `0c2eb38` remains available for
rollback. Physical installation remains pending while Xcode cannot open the
iPhone connection. The active paired server needs the chat update before
physical chat acceptance.

Archive chat passed the Next analyzer and 55 tests, the offline backend suite,
and all 478 existing mobile transport tests. A three-page Firestore fixture
verified citations across recordings, follow-up context, no-match behavior,
partial scans and rejection of a changed source during inference. The widget
test opened the second recording's transcript and resumed the archive chat.

The signed `Profile-dev` package from `59dc5ce` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`fbfc5e802e5f1320`. Package `7de7940` remains available for rollback.
Installation and physical playback are pending because Xcode found no
eligible iPhone. The active paired server needs the archive chat update.

Recording edits and the Starred filter passed the Next analyzer and all 57
tests, the offline backend suite and all 478 existing transport tests. An
isolated Firestore run verified concurrent transcript edits, stale conflicts,
idempotent repeats, encrypted long transcripts, search at the original
timecode and preservation on re-import.

The signed `Profile-dev` package from `5bd406e` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`a8c79d37db57bd6d`. Package `59dc5ce` was verified and retained for rollback.
Xcode still found no eligible iPhone for installation. The paired server
needs the recording edit update before physical acceptance.

Folder management passed the Next analyzer and 58 tests, the offline backend
suite and the existing mobile transport suite. An isolated Firestore run
verified owner-scoped creation and renaming, move conflicts, the combined
folder and Starred query, clearing an assignment and re-import preservation.

The signed `Profile-dev` package from `76a5db7` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`1e25ef8a7cfebc3c`. Package `5bd406e` remains available for rollback. Xcode
found no eligible iPhone for installation. The paired server needs the folder
update before physical acceptance.

Folder ordering, deletion and bulk moves passed the Next analyzer and 59
tests, the offline backend suite and the older mobile transport suite.
The isolated Firestore check covered stale order, atomic bulk moves,
archive preservation on deletion and rejection above the transaction limit.

The signed `Profile-dev` package from `569bbce` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`e1d46c0420438a83`. Package `76a5db7` remains available for rollback. Xcode
found no eligible iPhone for installation; physical checks also need the
paired server's folder management update.

Manual speaker labels passed the Next analyzer and 60 tests, the offline
backend suite and legacy mobile transport tests. An isolated Firestore run
verified owner-scoped names, grouped assignments, self and clear, stale
conflicts and preservation of text and timestamps through repeat import.

The signed `Profile-dev` package from `c98ca92` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`302a0bee696ae0f0`. Package `569bbce` remains available for rollback. Xcode
found no eligible iPhone. Physical checks need the updated paired server
and installation of the new package.

Local tasks passed the Next analyzer and 61 tests, the offline backend suite
and all 478 legacy mobile transport tests. Isolated Firestore checks covered
paired listing, exact transcript provenance, source revisions, replay,
edits, completion and reopening.

The signed `Profile-dev` package from `0aff19a` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`6dfabf5a3ca8eec6`. Package `c98ca92` was verified and retained for rollback.
Xcode found no eligible iPhone. Physical checks require installation and the
paired server's tasks update.

Task suggestions passed the Next analyzer and 62 tests, the offline backend
suite, and the legacy mobile transport suite. An isolated Firestore run
through the harness and a fixture model covered owner scope, provider binding,
source validation, no writes during generation, replay and transcript edits.

The signed `Profile-dev` package from `902cfa3` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`b841474757284997`. Package `0aff19a` was verified and retained for rollback.
The Mac reported no iPhone on USB, and Xcode found no connected eligible
iPhone. Physical verification also requires the task suggestion routes on the
paired server and an applied summary model.

Shared summary templates passed the Next analyzer and 63 tests, the offline
backend suite, and the legacy mobile transport suite. The isolated paired
API and fixture model verified revision conflicts, save without inference,
and an actual summary request using the selected default.

The `Profile-dev` package from `200e141` passed independent signature and
entitlement verification. Its executable SHA-256 begins with
`d8256f02545ec364`. Package `902cfa3` was verified and retained for rollback.
Xcode found no eligible connected iPhone for installation.

Recap regeneration passed the Next analyzer and 64 tests, the offline
backend suite, and the legacy transport tests. An isolated Firestore and
fixture model verified generation from a transcript edited through the
normal write path, confirmed replay, title preservation, and conflict on
a concurrent transcript change.

The `Profile-dev` package from `cf70c54` passed independent signature and
entitlement verification. Its executable SHA-256 begins with
`8bca971dd55a115a`. Verified rollback package `200e141` is available. The
Mac saw no iPhone on USB and Xcode found no eligible phone for installation.

Daily recaps passed the Next analyzer and 65 tests, the offline backend
suite, and the legacy transport suite. Isolated Firestore and a fixture
model verified a 23-hour calendar day, archive ownership, source links,
replay, coexistence with legacy recaps and conflict on concurrent additions.
The signed `Profile-dev` package from `28f61eb` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`03157331363adb72`. Verified rollback package `cf70c54` is available.
Xcode found no eligible connected iPhone for installation.

Local goals passed the Next analyzer and 66 tests, the offline backend
suite, legacy transport tests, and focused canonical goal tests. Isolated
Firestore verified revision conflicts, replay, existing goals, metric
bounds and links to owned recordings.

The signed `Profile-dev` package from `5c2f56b` passed independent signature
and entitlement verification. Its executable SHA-256 begins with
`9fc7591a66d4aa46`. Verified rollback package `28f61eb` is available.
Xcode found no eligible iPhone for installation.

Grouped capture server verification covered late and repeated parts, exact
silence boundaries, no-split silence retention, and RF64 headers. An isolated
paired upload passed through the real voice detector, the transcription queue
with a fixture recognizer, Firestore import, and authenticated WAV playback.
The offline and legacy transport suites passed. This was a server-only change,
so the signed `5c2f56b` package was verified for reuse at that milestone.

Next now offers per-server conversation boundaries in the capture controls.
The default uses version 2. A compatible server enables version 3 with a single
conversation until Stop or splitting after 15, 30, 60 or 120 seconds of silence.
The phone recovers complete journal packets and the finish marker after restart.
CV1 can seal and resume the same group across a reconnect with the same codec.
The Next suite passed 70 tests. A wire smoke used bodies from the actual
Flutter journal against the paired API, including finish before audio,
reverse-order parts and replay. The real voice detector, transcription queue
with a fixture recognizer, Firestore import and range playback all passed.
The current Live transcript still covers the capture session. Resetting its
display at a saved conversation boundary and physical acceptance remain open.

The separate `Profile-dev` package from `7c64a8d` passed signature,
provisioning and entitlement verification. Its executable SHA-256 begins
with `cbf5a434c37ed460`. Signed rollback `5c2f56b` was verified separately.
The offline and legacy transport gates passed before the build. The
attested package was installed via USB with `ios-deploy` on November 25
and the separate bundle was confirmed present. Xcode's developer tunnel was
unavailable. Recording acceptance is pending. On the device, verify capture
through Stop and the saved archive in version 2, then repeat with silence
splitting on a paired server with grouping enabled.

The startup-default package `1cd5995` passed signature, entitlement and
provisioning verification. Its executable SHA-256 begins with
`d67d1cdeaae63d3f`. It was installed over USB with the Bastion preset.
The physical iPhone opened Bastion automatically and showed
`Connected · API Key Auth`. Next discovered and connected the CV1. After a
short test and a Bluetooth reconnect, Bastion reported a durable receipt and
a 2.06-second WAV from the wearable. The new card and playback were not
confirmed on the iPhone. The physical button and the phone microphone
remain unverified.

Next refreshes the archive after an exact durable receipt. While the first
page is visible, it also refreshes local recordings awaiting processing so
the final conversation can replace the temporary card. A background refresh
keeps existing rows after a transient failure. Loading older pages suspends
automatic refresh until the next manual refresh.

The previously delivered CV1 recording was verified on Bastion. The
transcription watcher completed, the imported conversation appeared on the
first archive page, and its detail endpoint returned HTTP 200. Bastion's
deployed profile did not advertise the paired WAV route. The WAV exists on
the server, and playback from Next still needs a compatible deployment.

The Next analyzer and all 72 Next tests passed, along with the offline and
legacy transport gates. On an isolated server, the grouped recording reached
the transcription queue, was imported into Firestore, and served its original
WAV over the authenticated range endpoint. The signed `Profile-dev` package
from `c6d0fb8` was independently verified with executable SHA-256 prefix
`36c5a08845872e0f`. No eligible iPhone was available to install it. The
previous signed package `1cd5995` is available for rollback.

The archive category milestone matches all 33 category keys in the pinned Omi
source. The analyzer and all 73 Next tests passed, as did the offline and
legacy transport gates. An isolated paired API and Firestore verified category
edits, stale edit conflicts, and preservation after a later processing write.
At the November 24 category milestone, Bastion's profile did not advertise category edits. The separately
signed `35bbf19` package passed independent verification, with executable
SHA-256 prefix `a96020e4202fcfc6`. No eligible iPhone was available to install it.

The paired server now emits Omi archive page metadata without changing the
response body. An isolated Firestore run paged across an imported conversation
and a pending local WAV, including the pending recording's detail. Contract
tests covered a full final page and a truncated query without a false
end-of-list signal. The 73 existing Next tests passed against the pinned client.
The pagination milestone was server-only. Its first verification used the isolated deployment.

On November 25 Next advanced to original Omi `6f771e1`. The Flutter analyzer
and 73 Next tests passed. The legacy transport app suite and offline backend
suite passed. Bastion now serves the optional transcript-free archive page,
pagination headers and owner-scoped audio playback. Its first ten cards used
54,991 bytes versus 118,001 for the full list. The detail transcript, second
page and authenticated WAV range passed through the live paired ingress.
See [backend compatibility](../../docs/BACKEND_PARITY.md) for the rollout.
The signed `Profile-dev` package at `b5cd86c` passed signature, entitlements
and hash verification (executable SHA-256 starts with `08ad47ff6fbc53e4`).
CoreDevice installed this exact package and confirmed launch on the physical
iPhone. The device inventory listed both Omi Local and Omi Local Next. On-phone
archive, category and capture interaction are separate from installation.
Bastion's configured summary model classified a synthetic compiler discussion
as `technology`. Its category and emoji survived import and regeneration.
The regeneration path respects an existing owner category and title.
Bastion now advertises recording edits and categories. A temporary conversation
verified category changes through the paired API, safe retries, conflicts,
validation and authentication. Its test document was removed after readback.
The updated Local backend also reads Bastion's large grouped recordings and
keeps their checked full transcript when a metadata edit returns the detail.
On November 25 the paired search endpoint on Bastion found a real segment in a
file-backed transcript and returned the same timestamp and ID as detail.
The shared summary pipeline now keys partial results on the selected provider
profile, settings, effective instruction and text, following the Bastion implementation.

The signed iPhone `Profile-dev` build from `d7b2848` passed the offline and
legacy transport gates, Next analysis and 77 Next tests. CoreDevice installed
it alongside Omi Local and confirmed launch. The physical iPhone displayed
the Bastion archive and CV1 battery, RSSI and firmware in Device Diagnostics.
The first CV1 attempt stayed at “Waiting for data”. On the second attempt a
spoken fixture appeared in Live. Bastion stored 22.6 seconds of nonzero audio
and published six transcript segments. The phone opened the new card, summary,
category and timestamped transcript, and its player entered playback.
Apple's iPhone Mirroring reported that the phone microphone was unavailable
from the Mac. That 16-second phone WAV was delivered with silent samples.
Phone-microphone speech and repeated-start reliability still need a separate check.

| Area | Status and next verification |
| --- | --- |
| Base and installation identity | Upstream Flutter is pinned to November 26 revision `782a793`. The Runner uses an independent identifier, name and Keychain service. Native target selection explicitly lists the plugins used by this client. |
| Pairing and library | Named servers, verified switching and opt-in launch presets. The iPhone used the default Bastion preset and showed authenticated diagnostics. The archive and detail use the upstream API, with original day headers and state tiles. The automatic refresh after delivery still needs device verification. |
| Detail and playback | The paired WAV endpoint checks ownership and integrity. Next uses the original transcript viewport, Markdown renderer, section sources and search control. Older servers continue to serve the archive without the playback endpoint. A note citation opens a unique original transcript segment and can seek when audio is available. |
| Phone capture | Shared Local journal and receipt protocol. Interruptions, airplane mode, background endurance, reinstall recovery and physical microphone acceptance require device evidence. |
| CV1 | Next now connects a selected wearable, accepts button/audio notifications and journals complete Opus packets. Dart fences events by connection and audio subscription; switching inputs waits for the previous source's seal. Mute preserves the recording identity, seals prior audio and clears Opus context. The wire has no end marker, so the pending unconfirmed packet is discarded on Stop or loss. Physical notification delivery and background/relaunch endurance require device evidence. |
| Processing | Live transcript and one-way/two-way translation use the paired server. Next selects prepared Live/final STT and diarization profiles, manages adapter drafts and edits the saved Live speaker limit on supported servers. Opt-in silence-based grouping runs on the paired server. Live boundary display and editing summary/translation profiles remain open. |
| Upstream product screens | Paired search, chat, folders, manual speaker labels, tasks, manually generated daily recaps, and manual goal progress are available in Next. Task suggestions cite a transcript line and require individual acceptance. These features need physical verification with an updated server. Scheduled recaps, goal suggestions and lifecycle, semantic retrieval, persistent archive chat history, automatic speaker recognition, memory and integrations remain open. Episodes, Review and Dream retain separate availability checks. |
| Local work since the October baseline | Local donor `8ce6f0a` includes the durable capture integration. The local `sky-dev` onboarding and processing commit `a3de2ab` was merged into Next. The existing offline permissions flow, CV1 reconnect guards, pending archive and opt-in summary settings cover its functional changes. Track the later recording and summary repair branches separately. Confirm the installed build separately. |
| Update conflicts | The standard upstream startup initializes account and cloud services. The native product includes additional extensions and shared groups. Extend the Next composition as individual dependencies become necessary. |

Paired Live sessions send the same optional platform and model headers as durable audio
uploads. The Live monitor labels the paired phone and its selected input independently.
Clients that omit the optional headers still stream normally.

The mobile archive and recording detail display the input and the phone model when the paired
server can match the original capture. Failed capture rows show the saved processing stage,
error class and attempt count. The active recording timer uses the start of the current
capture, including intervals when audio frames pause.

While CV1 is recording, **Finish conversation and keep listening** seals the current
conversation and clears its Live transcript. CV1 stays subscribed. The next complete
Opus packet starts a new recording, with its own timer and delivery receipts. **Stop**
ends listening as well.

iOS can restore its remembered CV1 when CoreBluetooth relaunches Next. The bridge
reacquires the selected peripheral once Bluetooth powers on, rediscovers services,
and waits for the current capture to request audio. A manual disconnect clears the
saved device. A fresh link or ordinary app launch does not prove a system relaunch.
