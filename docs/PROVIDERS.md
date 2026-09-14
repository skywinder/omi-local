# Processing providers

For containers on Mac CPU or Linux/WSL2 NVIDIA, see [Docker](DOCKER.md).

Open **Settings** in the omiloc web library on this Mac. Each stage can have
several saved provider cards; one selected provider performs the work.

| Stage | Supported protocol or engine |
|---|---|
| Live STT | Prepared WhisperLiveKit; external WLK-compatible `/asr` servers, including an existing Parakeet server |
| Transcription | Prepared WhisperKit, WhisperX, Parakeet MLX; OpenAI-compatible `/v1/audio/transcriptions` with timestamps |
| Diarization | Prepared Pyannote; Mycelia `POST /diarize` |
| Summarization | OpenAI-compatible `/chat/completions` relative to the configured base URL, usually ending in `/v1` |

**Add → fill in the card → Check connection → Save → Use.**
**Save** updates the card; **Use** applies it to new jobs.
Saved and active settings are shown separately. **Load models** requests the
server's model catalog; you can also enter a model manually.
The readiness check does not recognize speech or send recordings.
Prepare Mac models and environments beforehand; opening or saving settings does
not download anything.

Live STT, diarization, and summarization can be disabled independently.
Completed WAVs pass through transcription, then enabled diarization and
summarization. Summaries and titles use the conversation's language; long
transcripts are processed in parts. The library shows each stage, its provider,
and the intermediate transcript while a later stage is still pending.
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
A previous STT engine's built-in diarization is retained as a separate card.
Before switching that engine to an STT server, select independent Pyannote/Mycelia
or disable diarization; an incompatible switch is rejected.
Secrets are stored separately in `provider-secrets.json` with mode `0600`.
Do not commit these files, recordings, or results.

## Live STT

The live server must accept little-endian PCM16, mono, 16 kHz, and the complete
WhisperLiveKit protocol: initial `config/useAudioWorklet`,
`lines/buffer_transcription` snapshots, an empty binary end-of-stream frame,
and `ready_to_stop`. An arbitrary cloud streaming API needs its own adapter.
Configure an external server's model and language on that server.

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
