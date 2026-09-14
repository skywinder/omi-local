import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/sockets/pure_socket.dart';
import 'package:omi/services/sockets/transcription_service.dart';

class _FakeSocket implements IPureSocket {
  dynamic sentMessage;
  IPureSocketListener? listener;

  @override
  PureSocketStatus get status => PureSocketStatus.connected;

  @override
  Future<bool> connect() async => true;

  @override
  Future<void> disconnect() async {}

  @override
  void onClosed() {}

  @override
  void onConnected() {}

  @override
  void onError(Object err, StackTrace trace) {}

  @override
  void onMessage(dynamic message) {}

  @override
  void send(dynamic message) => sentMessage = message;

  @override
  void setListener(IPureSocketListener listener) => this.listener = listener;

  @override
  Future<void> stop() async {}
}

class _SnapshotListener implements ITransctiptSegmentSocketServiceListener {
  final List<MessageEvent> events = [];
  final List<List<TranscriptSegment>> upserts = [];

  @override
  void onMessageEventReceived(MessageEvent event) => events.add(event);
  @override
  void onSegmentReceived(List<TranscriptSegment> segments) => upserts.add(segments);
  @override
  void onClosed([int? closeCode]) {}
  @override
  void onConnected() {}
  @override
  void onError(Object err) {}
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('serializes the explicit onboarding start request', () async {
    final socket = _FakeSocket();
    final service = TranscriptSegmentSocketService.withSocket(16000, BleAudioCodec.pcm16, 'en', socket);

    await service.requestFirstOnboardingQuestion();

    expect(socket.sentMessage, '{"type":"start_onboarding"}');
  });

  test('filters snapshot secrets while forwarding an authoritative empty replacement', () async {
    final socket = _FakeSocket();
    final service = TranscriptSegmentSocketService.withSocket(16000, BleAudioCodec.pcm16, 'en', socket);
    final listener = _SnapshotListener();
    service.subscribe(listener, listener);
    Map<String, dynamic> row(String id, String text) => {
          'id': id,
          'text': text,
          'speaker': null,
          'is_user': false,
          'start': 0,
          'end': 1,
        };
    void sendSnapshot(int revision, List<Map<String, dynamic>> rows) => socket.listener!.onMessage(jsonEncode({
          'type': 'local_transcript_snapshot',
          'preview_id': 'local-preview-synthetic',
          'revision': revision,
          'segments': rows,
        }));

    sendSnapshot(1, [row('safe', 'Spoken words'), row('secret', 'key sk_DEMO_KEY_FAKE_VALUE1234')]);
    sendSnapshot(2, [row('secret', 'key sk_DEMO_KEY_FAKE_VALUE1234')]);
    sendSnapshot(3, []);
    final snapshots = listener.events.cast<LocalTranscriptSnapshotEvent>();
    expect(snapshots.map((event) => event.revision), [1, 2, 3]);
    expect(snapshots.first.segments.single.text, 'Spoken words');
    expect(snapshots[1].segments, isEmpty);
    expect(snapshots[2].segments, isEmpty);
    expect(listener.upserts, isEmpty, reason: 'snapshots must never enter the append/upsert path');

    socket.listener!.onMessage(jsonEncode([row('ordinary', 'Regular segment')]));
    expect(listener.upserts.single.single.id, 'ordinary');
    await service.stop();
  });
}
