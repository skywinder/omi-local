# Omi Local Next

Omi Local Next is the side-by-side iPhone client for a paired Omi Local server.
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
Next. Match saved server selection and status with Local. Then ship archive
search and a source-linked conversation assistant as separate features. Connect
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

## Saved servers

Use **Servers** to save a name, address and app key for each Local server.
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

## Live transcript

Open Live while recording with the phone or CV1. The screen uses the original
Omi transcript list and shows where live processing runs. Translation can use
one target or two languages selected for the paired server. Stop remains
available on the Live screen.

Next sends a frame to the paired `/v4/listen` preview socket after the journal
flushes it to disk. The separate part upload owns retention and durable
delivery. A preview outage leaves the recording in the journal. Socket
reconnection keeps text already displayed for that recording and starts a new
live draft from the newly sent audio. The server's existing Live STT and
translation settings select the providers. See [live preview](../../docs/LIVE_PREVIEW.md)
and [provider setup](../../docs/PROVIDERS.md).

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

| Area | Status and next verification |
| --- | --- |
| Base and installation identity | Upstream Flutter is pinned to November 24 revision `ba4d7ac`. The Runner uses an independent identifier, name and Keychain service. Native target selection explicitly lists the plugins used by this client. |
| Pairing and library | Named servers, verified switching and opt-in launch presets. Upstream API for paginated archive and detail, with original day headers and state tiles over Local status. Remaining Local parity includes server health and transcription readiness. |
| Detail and playback | The paired WAV endpoint checks ownership and integrity. Next uses the original transcript viewport, Markdown renderer, section sources and search control. Older servers continue to serve the archive without the playback endpoint. A note citation opens a unique original transcript segment and can seek when audio is available. |
| Phone capture | Shared Local journal and receipt protocol. Interruptions, airplane mode, background endurance, reinstall recovery and physical microphone acceptance require device evidence. |
| CV1 | Next now connects a selected wearable, accepts button/audio notifications and journals complete Opus packets. Dart fences events by connection and audio subscription; switching inputs waits for the previous source's seal. Mute preserves the recording identity, seals prior audio and clears Opus context. The wire has no end marker, so the pending unconfirmed packet is discarded on Stop or loss. Physical notification delivery and background/relaunch endurance require device evidence. |
| Processing | Live transcript and one-way/two-way translation use the paired server. Next selects prepared Live/final STT and diarization profiles, manages network-adapter drafts and displays the effective summary/translation configuration. Silence tuning and the live speaker limit remain separate work. |
| Upstream product screens | Enable conversation search and source-linked chat first, then editing/folders, named speakers, tasks, daily recaps, memory and integrations with corresponding server modules. Episodes, Review and Dream retain separate availability checks. |
| Local work since the October baseline | Local donor `8ce6f0a` includes the durable capture integration. Reconcile `sky-dev` at `a3de2ab` (onboarding and processing), `origin/main` at `329796d`, and the November live-recording and summary repair line through `f1563e2`. Confirm the installed build separately. |
| Update conflicts | The standard upstream startup initializes account and cloud services. The native product includes additional extensions and shared groups. Extend the Next composition as individual dependencies become necessary. |
