# Recovering audio from Omi after Bluetooth loss

Next on Android and iOS can import audio from a legacy CV1. Open Settings and
diagnostics → Import oldest CV1 audio after stopping capture. Choose one
fragment (up to 32 records), a series of up to 32 fragments, or **Sync entire
CV1**. Full sync reads up to the archive's end at the start of the run and
publishes each series to the phone queue while reading the next one. The app
keeps the screen awake while in the foreground. Once enough data arrives to
measure throughput, the import row shows the CV1-to-phone speed and estimated
time remaining for the selected transfer. The estimate resets after reconnect
and excludes delivery from the phone to the server. The saved audio range uses
the earliest and latest timestamps reported by received records, shown in the
phone's time zone. The range can contain gaps, and the firmware provides no
dates for unread records before transfer.

A Bluetooth interruption saves the complete records already received and
pauses full sync. Next resumes when the same CV1 reconnects and reports its
archive. It compares repeated records with the saved checkpoint and
reports any missing range if the firmware advanced past the last saved record.
Stop saves the current request and ends the run or cancels the wait. Firmware
3.0.21 can release records before the phone writes them. After app termination,
open Next and start sync again to continue.

## Verified boundaries

The published `Omi_CV1_v3.0.21` tag resolves to
`f12031d15ea177bf8f6ac0781d7f28f3dc433eae`. The findings below refer to that
source, not a readback of a particular device's installed binary or storage.

| Interval | Current path | Recovery limitation |
| --- | --- | --- |
| Bluetooth disconnected | Firmware writes packed Opus records to SD when storage is available and its clock is valid. | Next can import the oldest legacy records. Actual stored coverage must be measured. |
| Connected, audio notifications not ready | Firmware removes frames from its transmission queue but neither sends nor stores them. | Downloading the existing ring cannot recover frames that were never stored. |
| Phone receives audio, live ASR not ready | The app journals received frames before attempting live preview. | Final processing can recover journaled audio; a replacement live preview currently starts with new audio. |

Firmware evidence:

- [Transport](https://github.com/BasedHardware/omi/blob/f12031d15ea177bf8f6ac0781d7f28f3dc433eae/omi/firmware/omi/src/lib/core/transport.c):
  `pusher`, `push_to_gatt`, `write_to_storage`. The connected/unsubscribed branch
  discards frames; failed live sends also have no storage fallback. The partial
  440-byte packing buffer has no explicit flush at the return to live mode.
- [Storage transfer](https://github.com/BasedHardware/omi/blob/f12031d15ea177bf8f6ac0781d7f28f3dc433eae/omi/firmware/omi/src/lib/core/storage.c):
  `storage_data_tx_done` increments a byte counter; `sync_checkpoint_advance`
  advances the persistent read cursor during transfer, completion and disconnect.
  This occurs without an application-level durable receipt. The
  [Zephyr notification callback](https://docs.zephyrproject.org/latest/doxygen/html/group__bt__gatt__server.html)
  reports notification transmission, not an iPhone filesystem or server commit.
- [SD storage](https://github.com/BasedHardware/omi/blob/f12031d15ea177bf8f6ac0781d7f28f3dc433eae/omi/firmware/omi/src/sd_card.c):
  `process_write_data_req` requires valid RTC; records carry second-resolution
  write timestamps. `advance_read_seq_internal` persists the new cursor, and
  `read_packets_internal` rejects ranges older than that cursor.

`CMD_RING_READ` is therefore **not a non-destructive inspection operation** on
this version. Merely omitting the app's `CMD_RING_ADVANCE` does not preserve the
device buffer. Reading a newer range can also advance past older unread history.
Use status/INFO only for initial device diagnostics; neither requests audio nor
advances the ring. Do not use READ, CLEAR or ADVANCE as a diagnostic probe.

Next reads status and INFO from the same connected CV1 while audio is idle.
Settings shows unread and free bytes, the device clock, the overwritten packet
count and the advertised transfer contract. An incomplete INFO reply cannot
establish receiver acknowledgement. A field test of interruption and recovery
still requires a compatible test pendant with disposable audio.

The existing `RingProtocol` handles 444-byte records and bounded sequence reads.
`RingStorageSyncImpl` targets the cloud WAL pipeline; its app-side advance guard
does not override firmware auto-advance. `SyncProvider` deliberately skips that
coordinator in offline runtime. Enabling it is not a local-server implementation.

## App-only feasibility

The existing READ can support best-effort extraction without updating firmware,
but cannot provide durable, non-consuming recovery. Reading one record at a time
limits the exposure; it does not remove it, because DONE forces cursor advance
even before the two-second periodic checkpoint. Omitting ADVANCE or CLEAR has
no effect on this firmware-side action. STOP is timing-dependent and cannot
undo an already persisted cursor. Starting at a recent gap also risks consuming
older unread history. Starting at the current read cursor instead requires
handling that older history and still has the receipt-to-disk failure window.

A host probe compiled the exact tagged `sync_confirmed_seq` and
`sync_checkpoint_advance` functions with simulated SD, time and atomic inputs.
It confirmed advance for one-record completion, a newer start that skips older
history, and periodic advance without an application receipt. This is a software
boundary check, not a physical transfer test.

The manual transfer checks the current connection, legacy INFO, acknowledged
read window, complete record boundaries and closing cursor. On interruption it
keeps whole records received after a matching READ_BEGIN. The phone flushes the
raw fragment to the selected pairing's directory on the phone, validates the stored
clock, splits across timestamp gaps and queues immutable Opus audio with the
stored UTC time. A restart replays the raw fragment with stable part IDs. Invalid
raw data stays on the phone for inspection. The retry action reprocesses the
same fragment without starting another Bluetooth read. A matching server receipt
releases each phone part. Live capture and ring import run separately.

A series always requests the current oldest cursor. Consecutive reads may
overlap on legacy firmware. Next compares the SHA-256 of each repeated record at its original sequence before appending fresh records. The last 32 record hashes and
their ending sequence are checkpointed per paired server, codec and pendant
after publication to the phone outbox. These verify the boundary when another
manual import starts. An interrupted reply can contain only part of the already
saved range. Next verifies the records it received and skips a matching prefix.
Recovery also skips staged fragments from previous versions when every complete
record matches the saved checkpoint. A forward jump on an active link stops
the series. After reconnect, full sync continues with available records and
reports the gap. A changed device, incompatible codec or backwards reset ends
the run.
After a restart the phone publishes the complete staged records with their
original times; starting another Bluetooth read requires the user's action.
Continuous audio is combined across windows; a clock jump or a part limit
starts a new archive entry.

## Deferred implementation order

1. Observe status/INFO across one controlled disconnect: unread counts, sequence
   range, dropped count, clock validity and advertised capabilities. Keep device
   identifiers and audio out of diagnostic output. This establishes actual
   storage availability without consuming existing recordings.
2. Verify the capability-negotiated transfer provided by firmware tags 3.0.23 and 3.0.24 on a test device. Advance
   only a contiguous acknowledged prefix after durable delivery, with a storage
   generation identity so card reset or sequence reuse cannot alias old data.
   Preserve older unread history when recovering only new gaps. Separately store
   frames until live notifications are ready, handle failed sends, and flush the
   partial packing buffer at mode changes with accurate capture timestamps.
3. Add one local recovery owner in the app. Persist the exact device generation,
   sequence window and original pairing before transfer. Validate READ_BEGIN,
   complete records and DONE. Store recovered Opus through the existing durable
   outbox with stable part identity; retries must reuse identical bytes. Retain a
   durable receipt ledger before allowing device release. Live capture has
   priority and must continue during buffer download.
4. Process recovered parts on the paired server and display them at their
   capture time, with an explicit recovered-audio origin. Do not append historical
   text as if spoken now. Preserve timestamp uncertainty and explicit gaps;
   second-resolution storage timestamps alone cannot prove seamless alignment.
   Audio already in the phone journal needs final processing, not another device
   download. Joining separate recordings is an independent presentation change.
5. Test interrupted transfer, phone restart before/after receipt, lost ACK,
   duplicate delivery, storage reset/overflow, RTC failure, pairing change and
   simultaneous live audio. Then physically verify speech before, during and
   immediately after Bluetooth loss. Software tests alone cannot establish that
   every phrase is recovered.

Android has physical CV1-to-server evidence for the legacy manual transfer, including
an offline phone. On Pixel with firmware 3.0.21, stopping a series saved 5.18 s.
The next series began at the first unsaved record and delivered 35.28 s.
The paired server confirmed both parts (259 and 1,764 Opus frames, zero decoding errors). With Wi-Fi and mobile data disabled, the Pixel retained a separate 34.24 s series while the paired server had no copy. After reconnect, its server receipt matched the phone file SHA-256, the phone released the part, and the WAV decoded all 1,712 frames with the original capture date. On iOS, device acceptance still needs a disposable legacy window.
In a subsequent Pixel test, disabling Bluetooth mid-series preserved 3.14 s.
After reconnect, a new manual import started at the first unsaved record and
delivered 38.10 s. The paired server decoded both without errors. This test establishes
continuity across that interruption. Firmware 3.0.21 can release records before
the phone saves them, so other interruption timings can still leave a gap.
Both platforms implement receiver-acknowledged bulk recovery for compatible firmware.
Physical verification with that firmware remains open.
