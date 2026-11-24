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
transition. Selective backports still suit a small standalone fix such as an
atomic index write. Between the October 28 and November 24 original revisions,
1,250 files changed under `app/`. Copying each new screen and its providers into
the September snapshot would also give Local ownership of their future fixes.

The Next bootstrap currently owns navigation and the archive/detail screens.
It already uses the upstream conversation model, theme, localization and detail
search widget. The next UI milestone is to run an upstream conversation screen
with its own provider against paired data. Upstream's
`ConversationDetailProvider` accepts a read function. Its production screen
also consumes capture state, preferences and actions. Enable actions when the
paired server implements their contracts. Home v3 separately reads
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

Evaluate each upstream update with a clean materialization, the server
contracts for enabled features, and the same screen on an older paired server.
Changes to Flutter, native startup, or BLE need their own verification.
Repeated edits inside upstream widgets or new Next-only versions of whole
product pages signal that the integration boundary needs to move into their
provider or API. Exercise that boundary on a second upstream revision before
claiming the update procedure is proven.

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

| Area | Status and next verification |
| --- | --- |
| Base and installation identity | Pinned November 24 Flutter app, independent Runner identifier, name and Keychain service. Native target selection explicitly lists the plugins used by this client. |
| Pairing and library | Dedicated paired startup, conversation list, detail, transcript and pending rows. Remaining Local parity includes multiple saved profiles, launch presets, and server status. |
| Playback | Versioned paired WAV endpoint with ownership and integrity checks. The Next detail view uses the advertised capability and supports segment seeking. The original search control finds text in the open transcript and summary and can play a matching segment. Older servers continue to serve the archive without the new playback endpoint. |
| Phone capture | Shared Local journal and receipt protocol. Interruptions, airplane mode, background endurance, reinstall recovery and physical microphone acceptance require device evidence. |
| CV1 | Pending native Bluetooth registration and connection, button/Stop/mute intent, reconnect, and arbitration with phone input. Upstream firmware can split an Opus frame across notifications. Validate reassembly, loss, wrap and Stop against its MTU fixture, then exercise the actual device. The phone outbox and wearable's offline ring have different recovery rules. |
| Processing | Existing server owns Live/final STT, diarization, summaries and translation. Port the client status, provider selection and live transcript/translation controls. |
| Upstream product screens | Enable conversation search and source-linked chat first, then editing/folders, named speakers, tasks, daily recaps, memory and integrations with corresponding server modules. Episodes, Review and Dream retain separate availability checks. |
| Local work since the October baseline | Local donor `8ce6f0a` includes the durable capture integration. Reconcile `sky-dev` at `a3de2ab` (onboarding and processing), `origin/main` at `329796d`, and the November live-recording and summary repair line through `f1563e2`. Confirm the installed build separately. |
| Update conflicts | The standard upstream startup initializes account and cloud services. The native product includes additional extensions and shared groups. Extend the Next composition as individual dependencies become necessary. |
