import 'dart:async';

import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:omi/services/capture/local_audio_journal.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'cv1_gain_calibration.dart';

/// One decoder and one recurrent Silero state per uninterrupted source.
abstract interface class NextSpeechScorer {
  Future<double> score(Uint8List packet);
  Future<double> finish();
  Future<void> close();
}

typedef OpenSpeechScorer = Future<NextSpeechScorer> Function(String codec);

class SileroSpeechScorer implements NextSpeechScorer {
  SileroSpeechScorer._(this._session, this._options, this._decoder);
  final OrtSession _session;
  final OrtSessionOptions _options;
  final Cv1GainDecoder? _decoder;
  final _window = Float32List(576);
  int _filled = 0;
  Float32List _state = Float32List(256);

  static Future<NextSpeechScorer> open(String codec) async {
    final model = await rootBundle.load('assets/models/silero_vad.onnx');
    final decoder = codec == 'pcm16' ? null : await openCv1GainDecoder();
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(1)
      ..setInterOpNumThreads(1);
    try {
      return SileroSpeechScorer._(OrtSession.fromBuffer(Uint8List.sublistView(model), options), options, decoder);
    } catch (_) {
      options.release();
      decoder?.close();
      rethrow;
    }
  }

  @override
  Future<double> score(Uint8List packet) async {
    final pcm = _decoder?.decode(packet);
    final bytes = ByteData.sublistView(packet);
    final length = pcm?.length ?? packet.length ~/ 2;
    if (length == 0 || (_decoder == null && packet.length.isOdd)) throw const FormatException('Invalid audio');
    var peak = 0.0;
    for (var i = 0; i < length; i++) {
      _window[64 + _filled++] = (pcm == null ? bytes.getInt16(i * 2, Endian.little) : pcm[i]) / 32768.0;
      if (_filled == 512) {
        final p = await _infer();
        if (p > peak) peak = p;
      }
    }
    return peak;
  }

  @override
  Future<double> finish() async {
    if (_filled == 0) return 0;
    _window.fillRange(64 + _filled, 576, 0);
    return _infer();
  }

  Future<double> _infer() async {
    final input = OrtValueTensor.createTensorWithDataList(_window, [1, 576]);
    final state = OrtValueTensor.createTensorWithDataList(_state, [2, 1, 128]);
    final rate = OrtValueTensor.createTensorWithDataList(Int64List.fromList([16000]), []);
    final run = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = await _session.runAsync(run, {'input': input, 'state': state, 'sr': rate});
      if (outputs == null || outputs.length != 2) throw StateError('Speech detector unavailable');
      final p = (outputs[0]!.value as List)[0][0] as double;
      if (!p.isFinite || p < 0 || p > 1) throw StateError('Invalid speech probability');
      final recurrent = outputs[1]!.value as List;
      _state = Float32List.fromList([for (final plane in recurrent) ...List<double>.from(plane[0] as List)]);
      _window.setRange(0, 64, _window, 512);
      _filled = 0;
      return p;
    } finally {
      for (final value in outputs ?? <OrtValue?>[]) {
        value?.release();
      }
      run.release();
      rate.release();
      state.release();
      input.release();
    }
  }

  @override
  Future<void> close() async {
    _decoder?.close();
    await _session.release();
    _options.release();
  }
}

/// Time is measured in captured samples, independent of BLE bursts and wall time.
class SpeechActivity {
  static const onset = .35;
  static const uncertain = .15;
  static const leadMicros = 320000;
  static const tailMicros = 480000;

  static Future<List<LocalSpeechRange>> intervals(
    String codec,
    List<Uint8List> packets,
    int preroll,
    int pause, {
    OpenSpeechScorer open = SileroSpeechScorer.open,
  }) async {
    final scorer = await open(codec);
    final ranges = <LocalSpeechRange>[];
    final lead = Queue<({int index, int end})>();
    var time = 0, lastSpeech = 0, tail = 0;
    int? first;
    final ambiguous = <int>[];
    try {
      for (var i = 0; i < packets.length; i++) {
        var score = await scorer.score(packets[i]);
        if (i == packets.length - 1) {
          final finalScore = await scorer.finish();
          if (finalScore > score) score = finalScore;
        }
        if (i < preroll) continue;
        final duration = LocalAudioRecording.packetMicroseconds(codec, packets[i]);
        while (lead.isNotEmpty && lead.first.end < time - leadMicros) {
          lead.removeFirst();
        }
        if (first != null && pause > 0 && time - lastSpeech >= pause * 1000000) {
          ranges.add((first: first, end: tail));
          first = null;
        }
        time += duration;
        lead.add((index: i, end: time));
        if (score >= onset) {
          first ??= lead.first.index;
          lastSpeech = time;
        } else if (score >= uncertain) {
          ambiguous.add(i);
        }
        if (first != null && time - lastSpeech <= tailMicros) tail = i + 1;
      }
      if (first != null) ranges.add((first: first, end: tail));
      var interval = 0;
      for (final index in ambiguous) {
        while (interval < ranges.length && ranges[interval].end <= index) {
          interval++;
        }
        if (interval == ranges.length || ranges[interval].first > index) throw const LocalSpeechUncertain();
      }
      return ranges;
    } finally {
      await scorer.close();
    }
  }
}

typedef SpeechPreviewFrame = ({Uint8List bytes, double start, double elapsed});

/// Preview is disposable. The journal owns every packet before it enters this queue.
class SpeechPreviewGate {
  SpeechPreviewGate(this.codec, this.pause, this.emit, this.onQuiet, this.onBoundary, this.open);
  final String codec;
  final int pause;
  final void Function(SpeechPreviewFrame) emit;
  final void Function() onQuiet, onBoundary;
  final OpenSpeechScorer open;
  final _lead = Queue<SpeechPreviewFrame>();
  Future<void> _work = Future.value();
  NextSpeechScorer? _scorer;
  bool _closed = false, _streaming = false;
  double? _lastVoice;
  int _queued = 0, _generation = 0;
  DateTime? _retryAfter;

  void _reset() {
    _generation++;
    _retryAfter = DateTime.now().add(const Duration(seconds: 2));
    _streaming = false;
    _lastVoice = null;
    _lead.clear();
    onQuiet();
    _work = _work
        .then((_) async {
          final previous = _scorer;
          _scorer = null;
          await previous?.close();
        })
        .catchError((Object _) {});
  }

  void add(SpeechPreviewFrame frame) {
    if (_closed || (_retryAfter?.isAfter(DateTime.now()) ?? false)) return;
    if (_queued >= 128) {
      _reset();
      return;
    }
    final gen = _generation;
    _queued++;
    _work = _work
        .then((_) async {
          if (_closed || gen != _generation) return;
          final scorer = _scorer ??= await open(codec);
          if (_closed || gen != _generation) return;
          final p = await scorer.score(frame.bytes);
          if (_closed || gen != _generation) return;
          final last = _lastVoice;
          if (last != null && frame.start - last >= SpeechActivity.tailMicros / 1000000 && _streaming) {
            _streaming = false;
            onQuiet();
          }
          if (last != null && pause > 0 && frame.start - last >= pause) {
            _lastVoice = null;
            onBoundary();
            if (_closed) return;
          }
          _lead.add(frame);
          while (_lead.isNotEmpty && _lead.first.start < frame.start - SpeechActivity.leadMicros / 1000000) {
            _lead.removeFirst();
          }
          if (p >= SpeechActivity.onset) {
            _lastVoice = frame.start + LocalAudioRecording.packetMicroseconds(codec, frame.bytes) / 1000000;
            _streaming = true;
          }
          if (_streaming) {
            while (_lead.isNotEmpty) {
              emit(_lead.removeFirst());
            }
          }
        })
        .catchError((Object _) {
          if (!_closed && gen == _generation) _reset();
        })
        .whenComplete(() => _queued--);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _lead.clear();
    unawaited(_work.then((_) => _scorer?.close()).catchError((Object _) {}));
  }
}
