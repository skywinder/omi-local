import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:omi/utils/hard_secret_detector.dart';

bool _supported(String source, String codec) =>
    source == 'phone' && codec == 'pcm16' || source == 'omi' && (codec == 'opus' || codec == 'opus_fs320');

final _upgraded = Expando<Socket>();
typedef PreviewSilence = ({String recordingId, int seconds});

void abortPairedPreview(WebSocket socket) {
  _upgraded[socket]?.destroy();
  try {
    unawaited(socket.close().then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  } on StateError {
    // The raw socket was revoked while an outgoing stream owned its sink.
  }
}

/// Upgrade a dedicated, paired HTTP client. The SDK's WebSocket.connect does
/// not disable HttpClientRequest.followRedirects before sending its headers.
Future<WebSocket> upgradePairedPreview(
  HttpClient client,
  Uri origin,
  String key,
  String source,
  String codec, {
  Map<String, String> audioOrigin = const {},
  PreviewSilence? silence,
}) async {
  const timeout = Duration(seconds: 15);
  Socket? detached;
  try {
    if (!_supported(source, codec) ||
        !{'http', 'https'}.contains(origin.scheme) ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/')) {
      throw const WebSocketException('Invalid paired preview endpoint');
    }
    final uri = origin.replace(
      path: '/v4/listen',
      queryParameters: {
        'source': source,
        'codec': codec,
        'sample_rate': '16000',
        'channels': '1',
        'language': 'multi',
        'stt_service': 'offline_capture',
        'include_speech_profile': 'false',
        'create_speakers': 'false',
      },
    );
    client.findProxy = (target) {
      if (target.origin != origin.origin) throw const WebSocketException('Unexpected preview origin');
      return 'DIRECT';
    };
    final req = await client.getUrl(uri).timeout(timeout);
    req.followRedirects = false;
    final random = Random.secure();
    final nonce = base64Encode(List.generate(16, (_) => random.nextInt(256)));
    req.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $key')
      ..set('X-Omi-Local-Audio-Outbox', '1')
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Key', nonce)
      ..set('Sec-WebSocket-Version', '13');
    if (silence != null) {
      req.headers
        ..set('X-Omi-Local-Recording-Group', silence.recordingId)
        ..set('X-Omi-Local-Group-Silence', silence.seconds)
        ..set('X-Omi-Local-Group-Stop', '1');
    }
    for (final name in const ['X-App-Platform', 'X-Omi-Local-Recording-Origin']) {
      final value = audioOrigin[name];
      if (value != null) req.headers.set(name, value);
    }
    final response = await req.close().timeout(timeout);
    final headers = response.headers;
    final connection = (headers[HttpHeaders.connectionHeader] ?? const <String>[])
        .expand((v) => v.toLowerCase().split(','))
        .map((v) => v.trim());
    const guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
    final accept = base64Encode(sha1.convert(ascii.encode(nonce + guid)).bytes);
    if (response.statusCode != HttpStatus.switchingProtocols ||
        !connection.contains('upgrade') ||
        headers.value(HttpHeaders.upgradeHeader)?.toLowerCase() != 'websocket' ||
        headers.value('Sec-WebSocket-Accept') != accept ||
        headers['Sec-WebSocket-Protocol'] != null ||
        headers['Sec-WebSocket-Extensions'] != null) {
      throw WebSocketException('Local preview upgrade rejected', response.statusCode);
    }
    detached = await response.detachSocket().timeout(timeout);
    final ws = WebSocket.fromUpgradedSocket(
      detached,
      serverSide: false,
      compression: CompressionOptions.compressionOff,
    );
    _upgraded[ws] = detached;
    ws.pingInterval = const Duration(seconds: 30);
    return ws;
  } catch (_) {
    detached?.destroy();
    client.close(force: true);
    rethrow;
  }
}

enum NextPreviewPhase { idle, connecting, listening, unavailable }

class NextPreviewLine {
  const NextPreviewLine({
    required this.id,
    required this.text,
    required this.start,
    required this.end,
    required this.audioStart,
    required this.audioEnd,
    this.speaker,
    this.isDraft = false,
    this.translations = const {},
  });
  final String id;
  final String text;
  final double start;
  final double end;
  final double audioStart, audioEnd;
  final String? speaker;
  final bool isDraft;
  final Map<String, String> translations;

  NextPreviewLine withoutTranslation() => translations.isEmpty
      ? this
      : NextPreviewLine(
          id: id,
          text: text,
          start: start,
          end: end,
          audioStart: audioStart,
          audioEnd: audioEnd,
          speaker: speaker,
          isDraft: isDraft,
        );
}

typedef PreviewConnector =
    Future<WebSocket> Function(String owner, String source, String codec, {PreviewSilence? silence});

class NextLivePreview extends ChangeNotifier {
  NextLivePreview(this.owner, this._connect, {this.retryDelay = const Duration(seconds: 1), this.onReconnect});

  final String owner;
  final PreviewConnector _connect;
  final Duration retryDelay;
  final VoidCallback? onReconnect;
  NextPreviewPhase _phase = NextPreviewPhase.idle;
  NextPreviewPhase get phase => _phase;
  String? _reason;
  String? get reason => _reason;
  List<NextPreviewLine> _lines = const [];
  List<NextPreviewLine> get lines => _lines;
  int _contentVersion = 0;
  int get contentVersion => _contentVersion;
  ({String text, double end})? _withdrawn;
  String? get withdrawnText => _withdrawn?.text;

  void _replaceLines(Iterable<NextPreviewLine> lines) {
    _lines = List.unmodifiable(lines);
    _contentVersion++;
  }

  String _target = '', _other = '';
  String get targetLanguage => _target;
  String get otherLanguage => _other;
  String? _translationStatus;
  String? get translationStatus => _translationStatus;
  ({String state, int? revision, int? speakers})? _speakerStatus;
  ({String state, int? revision, int? speakers})? get speakerStatus => _speakerStatus;
  int _controlRevision = 0;
  bool _disposed = false;
  bool _awaitingRecovery = false;
  String? _recording, _shownRecording;
  String _source = '', _codec = '';
  int _epoch = 0, _retries = 0, _revision = 0, _priorCount = 0;
  int _boundarySample = 0;
  String? get savedGroupId => _boundarySample == 0 ? null : _shownRecording;
  double get boundarySeconds => _elapsedAt(_boundarySample / 16000, isEnd: true);
  final _captureGaps = <({double audio, double offset})>[];
  PreviewSilence? _silence;
  VoidCallback? _onSilence;
  String? _previewId;
  double? _offset;
  final _retiredIds = <String>{};
  Timer? _retry, _admission;
  WebSocket? _socket;
  StreamController<Object>? _outgoing;
  int _queuedBytes = 0;

  void begin(String recordingId, String source, String codec, {int? silenceSeconds, VoidCallback? onSilence}) {
    if (_disposed || !_supported(source, codec)) return;
    if (_recording == recordingId && source == _source && codec == _codec) return;
    _detach();
    if (recordingId != _shownRecording) {
      _replaceLines(const []);
      _priorCount = 0;
      _boundarySample = 0;
      _retiredIds.clear();
      _captureGaps.clear();
    }
    _onSilence = onSilence;
    _silence = onSilence != null && silenceSeconds != null && silenceSeconds > 0
        ? (recordingId: recordingId, seconds: silenceSeconds)
        : null;
    _recording = _shownRecording = recordingId;
    _source = source;
    _codec = codec;
    _retries = 0;
    _awaitingRecovery = false;
    _reason = null;
    unawaited(_open());
  }

  // WLK may extend one speaker turn across a silence cut. Its words have no
  // individual timestamps, so keep the whole turn while any of its audio is current.
  bool _withinConversation(double start, double end) =>
      _silence != null || _boundarySample == 0 || end * 16000 > _boundarySample || start * 16000 >= _boundarySample;

  /// Applies only the silence cut acknowledged by the paired audio journal.
  /// Snapshot offsets and the capture's lifetime stay on the original recording clock.
  void confirmConversationBoundary(String recordingId, int sample) {
    if (_disposed || recordingId != _shownRecording || sample <= _boundarySample) return;
    _boundarySample = sample;
    if ((_withdrawn?.end ?? 0) <= boundarySeconds) _withdrawn = null;
    _priorCount = _lines.take(_priorCount).where((line) => _withinConversation(line.audioStart, line.audioEnd)).length;
    _replaceLines(_lines.where((line) => _withinConversation(line.audioStart, line.audioEnd)));
    notifyListeners();
  }

  void end(String recordingId) {
    if (_recording != recordingId) return;
    _recording = null;
    _detach();
    _phase = NextPreviewPhase.idle;
    _reason = null;
    notifyListeners();
  }

  Future<void> _open() async {
    final epoch = _epoch;
    _phase = NextPreviewPhase.connecting;
    _translationStatus = null;
    notifyListeners();
    if (epoch != _epoch) return;
    try {
      final socket = await _connect(owner, _source, _codec, silence: _silence);
      if (epoch != _epoch) {
        abortPairedPreview(socket);
        return;
      }
      _socket = socket;
      final outgoing = _outgoing = StreamController<Object>(sync: true);
      // SDK addStream propagates TCP backpressure. Keep the bytes queued behind
      // a paused sink bounded, independently of durable journal writes.
      unawaited(
        socket
            .addStream(
              outgoing.stream.where((_) => epoch == _epoch).map((value) {
                _queuedBytes -= _size(value);
                return value;
              }),
            )
            .then<void>((_) {}, onError: (Object _, StackTrace __) => _lost(epoch)),
      );
      _admission = Timer(const Duration(seconds: 30), () => _lost(epoch));
      socket.listen(
        (message) {
          if (epoch == _epoch) _message(message, epoch);
        },
        onDone: () => _lost(epoch, terminal: {1003, 1008, 1009}.contains(socket.closeCode)),
        onError: (Object _) => _lost(epoch),
        cancelOnError: true,
      );
      if (_target.isNotEmpty) _sendTranslation();
    } catch (error) {
      final status = error is WebSocketException ? error.httpStatusCode : null;
      final terminal = status != null && status < 500 && status != 408 && status != 429;
      _lost(epoch, terminal: terminal);
    }
  }

  void _lost(int epoch, {bool terminal = false, String reason = 'unavailable'}) {
    if (epoch != _epoch) return;
    _detach();
    if (terminal) {
      _phase = NextPreviewPhase.unavailable;
      _reason = reason;
    } else {
      _phase = NextPreviewPhase.connecting;
      _reason = 'reconnecting';
      _awaitingRecovery = true;
      final backoff = retryDelay * (1 << _retries);
      const ceiling = Duration(seconds: 15);
      _retries = min(_retries + 1, 4);
      _retry = Timer(backoff > ceiling ? ceiling : backoff, _open);
    }
    notifyListeners();
  }

  void _detach() {
    _withdrawn = null;
    _epoch++;
    _speakerStatus = null;
    _retry?.cancel();
    _admission?.cancel();
    final priorId = _previewId;
    if (priorId != null) _retiredIds.add(priorId);
    _previewId = null;
    _priorCount = _lines.length;
    _revision = 0;
    _offset = null;
    _queuedBytes = 0;
    final outgoing = _outgoing;
    final socket = _socket;
    _outgoing = null;
    _socket = null;
    if (socket != null && outgoing != null) unawaited(_closeSocket(socket, outgoing));
  }

  Future<void> _closeSocket(WebSocket socket, StreamController<Object> outgoing) async {
    try {
      await outgoing.close().timeout(const Duration(seconds: 1));
      await socket.close(WebSocketStatus.normalClosure).timeout(const Duration(seconds: 1));
    } catch (_) {
      abortPairedPreview(socket);
    }
  }

  /// The capture owner calls this only inside LocalAudioRecording.afterPersisted.
  void addPersisted(
    String recordingId,
    String source,
    String codec,
    Uint8List bytes, {
    required double startSeconds,
    double? elapsedSeconds,
  }) {
    if (_recording != recordingId ||
        source != _source ||
        codec != _codec ||
        bytes.isEmpty ||
        bytes.length > 4096 ||
        !startSeconds.isFinite ||
        startSeconds < 0) {
      return;
    }
    final offset = (elapsedSeconds ?? startSeconds) - startSeconds;
    // Keep missing capture time without stretching timestamps for packet jitter.
    if (offset.isFinite && offset > (_captureGaps.lastOrNull?.offset ?? 0) + 0.75) {
      _captureGaps.add((audio: startSeconds, offset: offset));
    }
    if (_outgoing == null) return;
    _offset ??= startSeconds;
    _send(Uint8List.fromList(bytes));
  }

  double _elapsedAt(double audio, {bool isEnd = false}) {
    for (final gap in _captureGaps.reversed) {
      if (isEnd ? gap.audio < audio : gap.audio <= audio) return audio + gap.offset;
    }
    return audio;
  }

  int _size(Object value) => value is Uint8List ? value.length : (value as String).length;

  void _send(Object value) {
    final outgoing = _outgoing;
    if (outgoing == null) return;
    _queuedBytes += _size(value);
    if (_queuedBytes > 128 * 1024) {
      _lost(_epoch);
      return;
    }
    outgoing.add(value);
  }

  void setTranslation(String target, {String other = ''}) {
    final code = RegExp(r'^[a-z]{2,3}$');
    if ((target.isNotEmpty && !code.hasMatch(target)) ||
        (other.isNotEmpty && (target.isEmpty || other == target || !code.hasMatch(other)))) {
      throw ArgumentError('Expected distinct language codes');
    }
    if (_disposed || (target == _target && other == _other)) return;
    _target = target;
    _other = other;
    _controlRevision++;
    _translationStatus = null;
    _replaceLines(_lines.map((line) => line.withoutTranslation()));
    _sendTranslation();
    notifyListeners();
  }

  void _sendTranslation() => _send(
    jsonEncode({
      'type': 'translation',
      'language': _target,
      if (_other.isNotEmpty) 'other_language': _other,
      'revision': _controlRevision,
    }),
  );

  void _message(dynamic message, int epoch) {
    if (message is! String) return; // Local also sends non-transcript heartbeat events.
    if (message.length > 16 * 1024 * 1024) {
      _lost(epoch, terminal: true);
      return;
    }
    dynamic event;
    try {
      event = jsonDecode(message);
    } on FormatException {
      return;
    }
    if (event is! Map) return;
    if (event['type'] == 'service_status') {
      final status = event['status'];
      if (event['provider'] == 'local_audio_group' &&
          status == 'flush_part' &&
          _silence != null &&
          _recording == _silence!.recordingId &&
          event['reason'] == _recording) {
        _onSilence?.call();
        return;
      }
      if (event['provider'] == 'offline_capture' && status == 'ready') _confirmRecovery();
      if (event['provider'] == 'local_live_tuning') {
        final revision = event['revision'], speakers = event['max_speakers'];
        if (status == 'unsupported' && _speakerStatus == null) {
          _speakerStatus = (state: 'unsupported', revision: null, speakers: null);
          notifyListeners();
        } else if ((status == 'applied' || status == 'failed') &&
            revision is int &&
            revision >= (_speakerStatus?.revision ?? 0) &&
            speakers is int &&
            speakers >= 1 &&
            speakers <= 4) {
          _speakerStatus = (state: status as String, revision: revision, speakers: speakers);
          notifyListeners();
        }
      }
      if (event['provider'] == 'local_live_translation' &&
          _target.isNotEmpty &&
          (event['revision'] == null || event['revision'] == _controlRevision) &&
          const {'ready', 'unconfigured', 'failed'}.contains(status)) {
        _translationStatus = status as String;
        notifyListeners();
      }
      if (event['provider'] == 'local_live_preview') {
        if (status == 'stt_failed') {
          final why = event['reason'];
          if (_silence != null && event['retryable'] != true) {
            // The paired socket can still detect silence without Live STT.
            _admission?.cancel();
            _phase = NextPreviewPhase.unavailable;
            _reason = const {'busy', 'disabled', 'session_limit'}.contains(why) ? why as String : 'unavailable';
            notifyListeners();
            return;
          }
          _lost(
            epoch,
            terminal: event['retryable'] != true,
            reason: const {'busy', 'disabled', 'session_limit'}.contains(why) ? why as String : 'unavailable',
          );
        } else if (status == 'ready') {
          _ready();
          notifyListeners();
        }
      }
      return;
    }
    if (event['type'] != 'local_transcript_snapshot') return;
    final id = event['preview_id'], revision = event['revision'], segments = event['segments'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 256 ||
        revision is! int ||
        revision <= _revision ||
        segments is! List ||
        _retiredIds.contains(id) ||
        (_previewId != null && id != _previewId)) {
      return;
    }
    final acceptedTranslations =
        _target.isNotEmpty &&
        (event['translation_revision'] == null || event['translation_revision'] == _controlRevision);
    final previous = {for (final line in _lines.skip(_priorCount)) line.id: line};
    final next = <NextPreviewLine>[];
    final seen = <String>{};
    for (final row in segments) {
      if (row is! Map) return;
      final key = row['id'], text = row['text'], start = row['start'], end = row['end'];
      if (key is! String ||
          key.isEmpty ||
          !seen.add(key) ||
          text is! String ||
          start is! num ||
          end is! num ||
          !start.isFinite ||
          !end.isFinite ||
          start < 0 ||
          end < start) {
        return;
      }
      if (HardSecretDetector.contains(text)) continue;
      final audioStart = start.toDouble() + (_offset ?? 0);
      final audioEnd = end.toDouble() + (_offset ?? 0);
      if (!_withinConversation(audioStart, audioEnd)) continue;
      final rowId = jsonEncode([id, key]);
      final old = previous[rowId];
      final translations = <String, String>{};
      if (acceptedTranslations) {
        final values = row['translations'];
        if (values is List) {
          for (final value in values.whereType<Map>()) {
            final lang = value['lang'], translated = value['text'];
            if ((lang == _target || (_other.isNotEmpty && lang == _other)) &&
                translated is String &&
                translated.isNotEmpty &&
                !HardSecretDetector.contains(translated)) {
              translations[lang as String] = translated;
            }
          }
        }
      }
      // A current, versioned snapshot includes the relay's correction matching.
      // Its empty translation also matters when a line splits or changes direction.
      // Earlier controls and legacy relays can only reuse the same sample span.
      if (translations.isEmpty &&
          _target.isNotEmpty &&
          (!acceptedTranslations || event['translation_revision'] == null) &&
          old != null &&
          old.audioStart == audioStart &&
          old.audioEnd == audioEnd) {
        translations.addAll(old.translations);
      }
      next.add(
        NextPreviewLine(
          id: rowId,
          text: text,
          start: _elapsedAt(audioStart),
          end: audioEnd == audioStart ? _elapsedAt(audioEnd) : _elapsedAt(audioEnd, isEnd: true),
          audioStart: audioStart,
          audioEnd: audioEnd,
          isDraft: row['is_draft'] == true,
          speaker: row['speaker'] is String ? row['speaker'] as String : null,
          translations: Map.unmodifiable(translations),
        ),
      );
    }
    _withdrawn = null;
    final withdrawn = event['withdrawn'];
    if (withdrawn case {'text': final String text, 'end': final num end}) {
      final audioEnd = end.toDouble() + (_offset ?? 0);
      if (text.isNotEmpty &&
          text.length <= 4096 &&
          end.isFinite &&
          end >= 0 &&
          (_silence != null || _boundarySample == 0 || audioEnd * 16000 > _boundarySample) &&
          !HardSecretDetector.contains(text)) {
        _withdrawn = (text: text, end: _elapsedAt(audioEnd, isEnd: true));
      }
    }
    _previewId = id;
    _revision = revision;
    _replaceLines([..._lines.take(_priorCount), ...next]);
    _ready();
    notifyListeners();
  }

  void _ready() {
    _admission?.cancel();
    _retries = 0;
    _phase = NextPreviewPhase.listening;
    _reason = null;
    _confirmRecovery();
  }

  void _confirmRecovery() {
    if (!_awaitingRecovery) return;
    _awaitingRecovery = false;
    onReconnect?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    _recording = null;
    _detach();
    super.dispose();
  }
}
