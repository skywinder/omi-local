# Processing providers

For containers on Mac CPU or Linux/WSL2 NVIDIA, see [Docker](DOCKER.md).
To replace the Docker stack's built-in STT with a server you already run, see
[External STT server](DOCKER.md#external-stt-server-instead-of-the-built-in-container).

On iPhone open **Settings → Local Mac → Transcription · Diarization** after
pairing with your Omi server. In the web library open **Settings**. Both edit the
same server registry: each stage has saved profiles and one selected provider.
The Local Mac address selects the Omi server that stores recordings; processing
profiles select the engines that server calls. Switching an Omi server also
changes the processing profiles shown on the phone.

Open **Settings → Summary templates** and select a row to reveal its prompt.
The template marked **Default** applies to new recordings. The **Summarization** category also links to the
template editor. Its **Automatic summaries** control applies to new processing
jobs. To resume with the only saved provider, choose **Enable automatic
summaries**. When several providers are saved, choose **Enable** on the row you
want to use. To regenerate one recording, open it and select
**Regenerate summary**.

In the web library under **Settings → Summarization**, choose **Backfill missing
summaries** to process older saved transcripts with the active model and default
template. **Turn on automatic backfill** keeps checking for missing summaries
and starts jobs when the active model is ready. Both use the server's summary
queue, keep existing summaries, and survive a server restart. Recordings need a
saved transcript. If automatic transcription succeeds while the summary model is
unavailable, the transcript is still published and can be backfilled later.

## Choose local or remote processing

| Where | What to do |
|---|---|
| iPhone | Select a profile under Live, finished transcription, or finished diarization, then **Confirm**. **Add** creates a server profile; **Edit** changes its URL, model and optional API key. |
| Next on an updated server | **Processing** also supports summary and translation. **Save** stores a draft and **Apply** switches the active profile. |
| Web library | Open **Settings → Providers**, scroll to a processing category and choose **Use provider** in its list. The active row shows the latest reported availability when the server has a matching check. **Edit** opens the form below that provider, and **Test connection** checks reachability from Omi. |
| Config / terminal | Export, edit and save profile JSON, then run `providers use`; commands below. |

Local means **on the Omi server**, not on the iPhone. An API endpoint can be on
that same machine or a remote server. URLs are resolved from the Omi server:
`127.0.0.1` means its own runtime, and inside Docker it means the shared container
network namespace. To call a service on the Docker host, follow the address rules
in [Docker](DOCKER.md#external-stt-server-instead-of-the-built-in-container).

Prepare local models first ([native setup](START.md), [final STT and Pyannote](LOCAL_STT.md),
[Live](LIVE_PREVIEW.md)). The phone selects prepared profiles; executable and model
paths are edited on the host/web library. Old imported profiles may also be
selection-only: add a new server profile to edit its connection from the phone.
An older Omi backend shows an update message instead of these controls. Updating
the backend/harness and installing an updated iPhone build is required once;
subsequent provider switches need no app rebuild.

Next's recording chat can use the applied summary provider. Before sending
the first question, Next shows the model and endpoint host and asks for
confirmation. A request can include the question, excerpts from the recording
and recent chat turns. The harness sends that request to the confirmed provider,
including a remote provider if one is selected. The paired server stores chat
history with the recording in local Firestore.

| Stage | Supported protocol or engine |
|---|---|
| Live STT | Prepared local Parakeet or WhisperLiveKit; external WLK-compatible `/asr` servers |
| Transcription | Prepared WhisperKit, WhisperX, Parakeet MLX; OpenAI-compatible `/v1/audio/transcriptions` with timestamps |
| Finished-recording diarization | Prepared Pyannote; Mycelia `POST /diarize` |
| Summarization | OpenAI-compatible `/chat/completions` relative to the configured base URL, usually ending in `/v1` |
| Translation | Active summarization model by default, or a separate OpenAI-compatible text model |

**Add → fill in the card → Check connection → Save → Use.**
**Save** updates the card; **Use** applies it to new jobs.
Saved and active settings are shown separately. **Load models** requests the
server's model catalog; you can also enter a model manually.
The readiness check does not recognize speech or send recordings.
Prepare Mac models and environments beforehand; opening or saving settings does
not download anything.

Live STT, diarization, and summarization can be disabled independently.
Live speaker labels belong to the **Live server/profile**. Turning finished-recording
diarization on or off does not change Live speaker labels. An external Live
server must have its own diarization enabled; the phone cannot install its models.
Completed WAVs pass through transcription, then enabled diarization and
summarization. Summaries and titles use the conversation's language; long
transcripts are processed in parts. The library shows each stage, its provider,
and the intermediate transcript while a later stage is still pending.
A retry reuses partial summaries for the same provider profile, settings, model instruction and transcript text.
Changing the selected profile or model starts a separate set of checkpoints, including with the default template.
The result is imported into the app after all enabled stages succeed.

New settings do not reprocess the archive. Jobs retain their profile, including
the key version, for retries after errors. Successful stages are not repeated;
audio and earlier results are preserved. The existing
`bash scripts/local-mac.sh transcribe "/path/to/recording.wav"` command remains
available. Errors do not automatically switch to another provider.

## Connections and keys

Public addresses use HTTPS/WSS. For HTTP/WS, specify `localhost` or an explicit
server IP on loopback, LAN, or VPN; domain names require TLS.
Redirects and system proxy variables are not used. Audio or text goes only to the
provider selected for its stage. The browser calls omiloc; the Mac server adds
the API key.

When reopened, the key field is empty and indicates whether a key is configured.
An empty field preserves the old key; a separate checkbox removes it from the
card. Changing to a different host clears the old key; enter the new server's key.
A saved replacement becomes active only after **Use**. Keys for older jobs remain
in private storage for their pinned profiles.

The first save imports settings from `stt-engine.json` and `live-stt.json` into
private `providers.json` in the harness state directory. The editor and workers
then use the registry; the older JSON files remain as source copies.
On a native paired Mac, an enabled default managed Parakeet is also imported as
the active Live profile. An explicitly disabled Live stage stays disabled. Existing
registries without that profile require an explicit selection of a new Parakeet card.
A previous STT engine's built-in diarization is retained as a separate card.
Editing or importing that card preserves its embedded execution mode. To move
to independent diarization, add a new Pyannote/Mycelia card and select it.
Before switching that engine to an STT server, select independent Pyannote/Mycelia
or disable diarization; an incompatible switch is rejected.
Secrets are stored separately in `provider-secrets.json` with mode `0600`.
Do not commit these files, recordings, or results.

## Profile JSON and terminal switching

Run these commands from the checkout that owns your native instance. Preserve any
custom `OMI_LOCAL_INSTANCE`, `OMI_LOCAL_STATE_ROOT` and `OMI_HARNESS_PORT_OFFSET` you
used to start it. Native and Docker registries are independent.

```bash
./omiloc providers list
./omiloc providers export --file /tmp/omi-providers.json
# Edit that file, then save drafts. Existing IDs update cards; new IDs add cards.
./omiloc providers save --file /tmp/omi-providers.json
./omiloc providers use stt "Local WhisperKit"
./omiloc providers use diarization "Local Pyannote"
./omiloc providers use live "Remote Live"
./omiloc providers disable diarization
```

Names above are examples: use the names printed by `list`, or the IDs in `export`.
`export "Profile name"` exports one card. `check "Profile name"` checks metadata
without sending audio. Exported files omit keys and are created with mode `0600`;
they may still contain private URLs and paths. Existing files are not overwritten.

Copy and edit the [remote template](examples/processing.remote.json) or the
[native final-processing template](examples/processing.local.json). These are
drafts; their example servers and models are not a running setup. For local Live,
export the profile created by native setup so its prepared paths remain intact.
`save` accepts a single card or a version-1 document with `profiles`. The optional
`active` map in an export is informational: **save never switches providers**.
All cards are validated first, then saved individually. If another editor changes
the registry mid-import, completed saves remain and the command stops; inspect
`list` before retrying. Each `use` runs the same checks/idle guard as the UI.

For an already running Docker stack, use the same subcommands inside its app:

```bash
./omiloc --runtime docker providers list
./omiloc --runtime docker providers export > /tmp/omi-docker-providers.json
# A host file reaches the container through stdin.
./omiloc --runtime docker providers save --file - < /tmp/omi-docker-providers.json
./omiloc --runtime docker providers use stt "Remote transcription"
./omiloc --runtime docker providers use diarization "Remote diarization"
```

For a single card, `save --file ... --api-key-env OMI_PROVIDER_KEY` reads a key
already supplied in that environment variable. Docker forwards only the variable
name in command arguments. Do not put the key in JSON or command-line arguments.
Omitting the option preserves an existing key when the endpoint identity is
unchanged; `--clear-key` removes it from the draft. Finish with `use` to activate.

The phone calls authenticated `/v1/local/processing` routes. The backend forwards
only to the fixed loopback library URL generated as `OMI_LOCAL_PROCESSING_URL` by
the harness; remote destinations and keys remain in the harness. Do not expose
the library's internal `/api/processing` endpoint or emulators to the network.

## Summarization

The summary card takes an OpenAI-compatible base URL ending in `/v1` and a model.
The request asks for JSON `title`/`overview` with `max_tokens` 1600. Reasoning
models such as Qwen3 on llama.cpp or vLLM can spend that whole budget thinking
and return an empty answer; set **Model reasoning → Off** on the card, which adds
`chat_template_kwargs: {"enable_thinking": false}` to the request. Leave the
default for servers that reject unknown fields.

Next can read the configured endpoint's model catalogue or accept a model name
entered manually. Saving and applying a summary profile in Next records an
explicit model selection for that profile. In the web library, leave **Model**
empty to follow the provider. A JSON profile can set `model_source` to `provider`
for the same behavior. The harness checks that provider's own `/models`
catalogue with the saved key, prefers a loaded text model, and uses the same
provider for inference. The translation fallback inherits the summary mode.
Archive chat and manually regenerated recaps use a recent model observation
for the applied revision so the model shown before confirmation is the one
used for the request.

The default for an unmarked profile with a saved model is `profile`.
Set `OMI_SUMMARY_MODEL_DEFAULT=provider` to retain automatic behavior on an
existing host. Use `.env.docker` with the Docker launcher.
This setting preserves the registry on disk. A profile created with an explicit
mode keeps that mode when the host default changes.

In Next, open **Processing → Summary Template** to add or edit a named prompt
and select the default. The paired server uses the same revisioned catalog as
the newer Omi Local client. The default is saved with each new processing job
when its provider profile is selected. Changing the catalog does not rerun
existing recordings or change the prompt of a job that already has a profile.
The catalog can be edited before applying a summary provider.

In Next, **Regenerate Recap** in a saved recording lets you choose a prepared
model, select a template and adjust its prompt for that request. The dialog
shows the selected model and server before sending the saved transcript.
Regeneration replaces the recap after successful publication and preserves
the user title. If the transcript or recap changes during inference, refresh
before generating again. This request covers at most 120,000 transcript
characters. Preview-only transcripts need the full-recording path.

## Live translation

Translation uses the connected server's active **Summarization** model by default,
with the same endpoint, key and reasoning setting. Saved drafts and STT models
are never selected automatically. To choose another model, open **Processing →
Translation** in Next, add or select a profile and apply it. The web library has
the same controls under **Settings → Translation**. Choose **Use the summary
model** and apply to restore inheritance.
The app's translation toggle turns requests on or off. If neither stage has an
active text model, configure either one with an OpenAI-compatible base URL ending
in `/v1`, model and optional API key. New selections apply to new recording sessions.

Translation is not part of the finished-recording pipeline: it translates the
live preview only. The relay on the connected server sends each batch of committed WLK lines (up to 8 lines / 4000 characters)
as one `chat/completions` request asking for a JSON array in the same order, and
attaches the result to the lines as `translations: [{"lang": "<code>", "text": ...}]`.
Translations are cached per line text and selected language pair for the session, so corrections that keep
a line's text cost nothing. A timed correction keeps its previous translation
visible until the replacement arrives when it still maps to the same line. Next uses the translations in the current versioned snapshot as the complete set for each line. Splitting a line clears its previous translation; a language change within a two-way conversation replaces the previous direction.
The last, still-growing line is translated once it ends a sentence or stays unchanged for
two seconds. A failed batch is not retried within the session.
Turning translation on or changing its language also translates the current
visible transcript, without waiting for more speech. Each Next language change
has its own revision. A response from an earlier revision cannot replace the
translation or status for the current language, even when switching back to
the same pair. Older clients can still send unversioned controls. Repeated
unchanged snapshots do not postpone the two-second settling timer.

The language settings and the on/off switch live in the app (Settings → Local Mac →
Live translation, and the language chip on the live transcript screen). Enable
**Two-way translation** in the language sheet and select two different languages,
for example Russian and Spanish. The chip then shows `RU ↔ ES`. The text model
detects each phrase's dominant language and translates into the other selected
language; the original stays above its translation. For mixed speech the dominant
language determines direction. Speech outside the pair is translated into language 2.
The relay validates the returned source and destination codes before displaying a result.
Existing settings keep one-way translation. Two-way translation requires both the
updated app and backend/relay. Saved language changes travel over the already open
listen socket, so switching modes never restarts a recording.
The relay can wait through quiet periods with no CV1 audio. The listen socket's
session limits and explicit end-of-input still govern when the stream ends.
Without either active text model, the app shows that the provider is missing; without
the switch the card is never contacted. Transcript text is untrusted input to the
model: the prompt tells it to translate, not to follow instructions in the lines.

## Live STT

The web library’s **Live** tab shows the phone and audio input for each stream.
Its timer measures audio received by the server. Five seconds without new frames
flags that input even if another device keeps sending audio. Speaker turns show
the time of their first segment. Drafts have a dashed marker. During capture,
the archive sidebar links back to these inputs. The service badges distinguish a
fresh readiness report from an expired or missing observation.

Open **Live transcription settings** to change the audio buffer, speaker limit
or draft visibility. Changes save when the control is committed. The status
shows whether active streams have acknowledged the change. If another client
saved first, reload the values before editing again.

The live server must accept little-endian PCM16, mono, 16 kHz, and the complete
WhisperLiveKit protocol: initial `config/useAudioWorklet`,
`lines/buffer_transcription` snapshots, an empty binary end-of-stream frame,
and `ready_to_stop`. An arbitrary cloud streaming API needs its own adapter.
Configure an external server's model and language on that server.

When WhisperLiveKit rejects a stream because every session slot is in use, the
relay preserves close code `4409`. The paired backend reports `session_limit`
in its Live status. Omi Local Next explains the missing live text while the
phone keeps recording audio for later processing.

Before selecting **Use**, finish recording and wait for the live stream to drain.
If changing a managed local engine, also wait for final STT.
The new configuration is checked before switching. On failure, the previous
active profile is preserved; an unconfirmed result is shown separately.

The harness relay listens only on loopback, at backend port + 4. It pins one
profile for the whole session, including stream completion. The backend continues
using loopback and does not receive external server keys. The first Live
activation attaches the relay by restarting only the stack-owned backend while
idle. Later switches and disabling Live require neither a backend restart nor a
new iPhone build. Existing local live diarization is preserved through the same relay.

## Published summary provenance

The web recording card provides model and template choices for its next summary,
with an expandable instruction editor. Generate submits to the same durable
summary queue as Next. The saved result keeps its own model and template labels
while a replacement is queued or fails. Missing historical labels are shown as
not recorded; current defaults are never used to infer them. When the provider
selects its loaded model automatically, new results record that resolved model.
The paired summary-options API exposes the same optional `published` metadata.
