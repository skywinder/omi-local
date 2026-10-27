# Recording delivery and recovery

The updated local iPhone application keeps a private audio outbox on the phone.
For CV1 Opus and phone-microphone PCM16, each packet delivered to Flutter is
appended and flushed to a local journal before it is sent to live transcription.
A disconnected live socket does not discard this journal.
During startup, a bounded raw BLE buffer receives packets while codec and server
capability checks complete. Those packets enter the journal after validation,
before opening live preview. Termination during this initial validation can lose
the RAM-only startup buffer; it is not a durable recording yet.

The phone seals an immutable part after at most five minutes of audio or when
you stop recording. Parts preserve their recording identity, source, start time
and order. PCM duration comes from sample count; Opus duration comes from its
packet TOC and frame count ([RFC 6716](https://www.rfc-editor.org/info/rfc6716/)).
Network bursts and changes to the phone clock do not extend the audio limit.
The server library receives one recording per part, as in the existing
five-minute capture workflow. Live preview remains available while recording;
archiving a part is a separate operation.

Opus parts carry a bounded suffix of at least 80 ms of preceding packets, as
recommended for independent decoding in [RFC 7845 section 4.6](https://www.rfc-editor.org/rfc/rfc7845.html#section-4.6).
The server decodes this context first and discards its samples before writing
the new WAV. Context does not extend the five-minute audio limit, duplicate
playback samples, or inflate recording duration. It counts toward storage and
request limits; the phone retains at most 32 context packets. PCM has no context.

## What the status means

The Local Mac card includes the number and size of parts retained on the phone.
**Pending** means phone storage, including the current recording part.
**Syncing** means delivery is in progress. **Sync failed** leaves the original
phone audio available for another attempt. Refresh retries delivery.
Parts disappear from the phone outbox only after the server acknowledges the
same part identity and SHA-256 after saving its WAV and metadata.

Delivery retries every fifteen seconds while the application can execute, and
on pairing changes and application startup. Stopping recording seals the part
without waiting for the network. Quota or filesystem failure stops acquisition
and shows a storage error; pending audio is retained. The default phone outbox
limit is 512 MiB, with at most 4 MiB of packets awaiting local writes.

## Server and app updates

The app verifies the server's authenticated delivery capability before using
this path. Existing pairings refresh this evidence on their first recording
after an app restart. An old server produces an update-required message and
does not enter the preview-only protocol. Pairing and pending audio remain.
If that first capability check cannot reach the server, starting a new recording
is blocked with a connection error. Once verified in this app session, subsequent
live connection loss does not block phone journaling or discard accepted audio.
Older apps continue to use the original server-side WAV capture path.

New protected recordings use journal protocol version 2 and require authenticated
server capability 2. Version 1 servers cannot receive these parts: the phone checks
capability before sending audio. The updated server still accepts version 1 parts
without pre-roll; recovery and retry preserve their original identity and checksum.

Each retained part is bound to a hash of its original paired origin and app key. It is never
sent to a newly selected server. Returning to that server permits retry; a part
for another server does not block parts belonging to the selected server.
The journal contains no access key. Credentials remain in Keychain.
Changing the app key also changes this binding: old pending parts stay on the
phone and require deliberate recovery using their original pairing. They are
never silently transferred to a replacement server using new credentials.

The paired-only `POST /v1/local/audio/parts` route authenticates before reading
audio, limits requests to 16 MiB, admits at most two simultaneous bodies, and
rejects unsupported source/codec combinations. It stages WAV and metadata
outside the library watch tree, then atomically publishes and syncs the complete
directory before acknowledging. A repeated identical part returns the same
receipt. Reusing its identity with different bytes returns conflict and cannot
overwrite the original. Interrupted staging never appears as a completed WAV.

## Recovery boundaries

On application startup, a valid unfinished journal is sealed for retry. An
incomplete final packet is trimmed; all complete packet records remain. An
invalid header or packet length leaves the original journal untouched for
investigation. Never delete pending files to resolve a connection error.

The guarantee starts with packets delivered to Flutter and successfully flushed
to phone storage. It does not prove uninterrupted BLE capture while iOS suspends
or terminates the app, physical device endurance, or a working background upload
budget. A process or power failure during a local write can leave a partial last
packet. Hardware testing must measure these boundaries separately.

The delivery tests cover persisted-before-send ordering, lost acknowledgements,
restart replay, incomplete journals, quota bounds, checksum conflicts, request
authentication/limits, and the legacy client capture path. Physical iPhone/CV1
recording and sustained interruption recovery still require fresh evidence.
