import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'cv1_gain_calibration.dart';
import 'cv1_transport.dart';
import 'settings_labels.dart';
import 'wav_level.dart';

enum _Phase { waiting, settling, room, ready, countdown, speech }

class Cv1GainCalibrationCard extends StatefulWidget {
  const Cv1GainCalibrationCard({
    super.key,
    required this.link,
    required this.gain,
    required this.busy,
    this.changeGain,
    this.openDecoder = openCv1GainDecoder,
  });

  final Cv1Connection link;
  final int gain;
  final bool Function() busy;
  final ValueChanged<int>? changeGain;
  final Future<Cv1GainDecoder> Function() openDecoder;

  @override
  State<Cv1GainCalibrationCard> createState() => _Cv1GainCalibrationCardState();
}

class _Cv1GainCalibrationCardState extends State<Cv1GainCalibrationCard> with WidgetsBindingObserver {
  late final ValueChanged<Uint8List> _acceptAudio = _accept;
  bool _opening = false;
  bool _foreground = true;
  Timer? _tick;
  int _quarterSeconds = 0;
  Cv1GainCalibration? _meter;
  bool _checkWake = false;
  bool _countdownAudio = false;
  int? _firstWakeAudio;
  WavLevel? _recent;
  String? _notice;
  final _results = <({int gain, WavLevel room, WavLevel speech, Cv1GainAdvice advice})>[];
  ({int gain, bool alreadyStreaming, int? firstAudio, double seconds})? _wakeResult;
  _Phase _phase = _Phase.waiting;

  @override
  void initState() {
    super.initState();
    widget.link.addListener(_linkChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _linkChanged() {
    if (_meter != null && !widget.link.calibrating) _finish(notice: 'gainTestDisconnected');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground && _meter != null) _finish(notice: 'gainTestCancelled');
  }

  Future<void> _start({bool checkWake = false}) async {
    if (_opening || widget.busy()) return;
    final link = widget.link;
    final connected = link.linkState?.generation;
    final gain = widget.gain;
    setState(() {
      _opening = true;
      _notice = null;
    });
    try {
      final decoder = await widget.openDecoder();
      if (!mounted ||
          !_foreground ||
          ModalRoute.isCurrentOf(context) == false ||
          widget.busy() ||
          link.linkState?.generation != connected ||
          widget.gain != gain ||
          !link.beginCalibration(_acceptAudio)) {
        decoder.close();
        return;
      }
      _meter = Cv1GainCalibration(decoder);
      _checkWake = checkWake;
      _countdownAudio = false;
      _firstWakeAudio = null;
      _enter(checkWake ? _Phase.countdown : _Phase.waiting);
      _tick = Timer.periodic(const Duration(milliseconds: 250), _advance);
    } catch (_) {
      _notice = 'gainTestDecoderUnavailable';
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _accept(Uint8List raw) {
    final meter = _meter;
    if (meter == null) return;
    try {
      if (!meter.accept(raw)) return;
      if (_phase == _Phase.waiting) {
        setState(() => _enter(_Phase.settling));
      } else if (_checkWake) {
        if (_phase == _Phase.countdown) _countdownAudio = true;
        if (_phase == _Phase.speech) _firstWakeAudio ??= _quarterSeconds;
      }
    } catch (_) {
      _finish(notice: 'gainTestDecodeFailed');
    }
  }

  void _enter(_Phase phase) {
    _phase = phase;
    _quarterSeconds = 0;
    _meter!.takeRecent();
    _recent = null;
    _meter!.settling = phase != _Phase.room && phase != _Phase.speech;
    _meter!.speaking = phase == _Phase.speech;
  }

  void _advance(Timer timer) {
    _quarterSeconds++;
    _recent = _meter?.takeRecent();
    if (widget.link.audioFailed) {
      _finish(notice: 'nextLinkAudioFailure');
      return;
    }
    switch (_phase) {
      case _Phase.waiting when _quarterSeconds >= 32:
      case _Phase.speech when _quarterSeconds >= 20:
        _finish(report: true);
      case _Phase.settling when _quarterSeconds >= 4:
        setState(() => _enter(_Phase.room));
      case _Phase.room when _quarterSeconds >= 8:
        setState(() => _enter(_Phase.ready));
      case _Phase.ready when _quarterSeconds >= 120:
        _finish(notice: 'gainTestReadyExpired');
      case _Phase.countdown when _quarterSeconds >= 12:
        setState(() => _enter(_Phase.speech));
      case _:
        setState(() {});
    }
  }

  void _finish({bool report = false, String? notice}) {
    final meter = _meter;
    if (meter == null) return;
    _tick?.cancel();
    _meter = null;
    if (report && _checkWake) {
      _wakeResult = (
        gain: widget.gain,
        alreadyStreaming: _countdownAudio,
        firstAudio: _firstWakeAudio,
        seconds: meter.speech.seconds,
      );
    } else if (report) {
      _results.removeWhere((result) => result.gain == widget.gain);
      _results.insert(0, (gain: widget.gain, room: meter.room, speech: meter.speech, advice: meter.advice));
      if (_results.length > 2) _results.removeLast();
    }
    meter.close();
    widget.link.endCalibration(_acceptAudio);
    setState(() => _notice = notice);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final link = widget.link;
    link.removeListener(_linkChanged);
    _tick?.cancel();
    if (_meter case final meter?) {
      _meter = null;
      meter.close();
      final accept = _acceptAudio;
      scheduleMicrotask(() => link.endCalibration(accept));
    }
    super.dispose();
  }

  String _db(double value) => '${value.isFinite ? value.toStringAsFixed(1) : '−∞'} dBFS';

  String _coverage(BuildContext context, String key, double seconds, int expected) =>
      '${pairedSettingsLabel(context, key)} · ${seconds.toStringAsFixed(1)} / $expected s';

  @override
  Widget build(BuildContext context) {
    String label(String key) => pairedSettingsLabel(context, key);
    final meter = _meter;
    final prompt = switch (_phase) {
      _Phase.waiting => label('gainTestWaiting'),
      _Phase.settling || _Phase.room => label('gainTestQuiet'),
      _Phase.ready => label('gainTestReady'),
      _Phase.countdown =>
        '${label(_checkWake ? 'gainWakeCountdown' : 'gainTestCountdown')} · ${3 - _quarterSeconds ~/ 4}',
      _Phase.speech => label(_checkWake ? 'gainWakePlayNow' : 'gainTestSpeak'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label('gainTestHelp')),
        if (meter == null) ...[
          TextButton.icon(
            onPressed: _opening || widget.busy() ? null : _start,
            icon: const Icon(Icons.graphic_eq),
            label: Text(label('gainTestStart')),
          ),
          TextButton.icon(
            onPressed: _opening || widget.busy() ? null : () => _start(checkWake: true),
            icon: const Icon(Icons.volume_down_outlined),
            label: Text(label('gainWakeStart')),
          ),
        ] else ...[
          Semantics(liveRegion: true, child: Text(prompt)),
          if (_phase == _Phase.ready)
            FilledButton(onPressed: () => setState(() => _enter(_Phase.countdown)), child: Text(label('gainTestGo'))),
          if (_phase == _Phase.speech) ...[
            ExcludeSemantics(
              child: LinearProgressIndicator(
                value: (((_recent?.rms ?? double.negativeInfinity) + 70) / 70).clamp(0.0, 1.0),
              ),
            ),
            Text(_coverage(context, 'gainAudioReceived', meter.speech.seconds, 5)),
          ],
          TextButton(
            onPressed: () => _finish(notice: 'gainTestCancelled'),
            child: Text(context.l10n.cancel),
          ),
        ],
        if (_notice case final key?) Text(label(key)),
        if (_wakeResult case final result? when meter == null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${label('gainWakeStart')} · ${result.gain} / 8'),
            subtitle: Text(
              [
                _coverage(context, 'gainAudioReceived', result.seconds, 5),
                if (result.alreadyStreaming) label('gainWakeAlreadyStreaming'),
                if (result.firstAudio case final time? when !result.alreadyStreaming)
                  '${label('gainWakeFirstAudio')} · ~${(time / 4).toStringAsFixed(1)} s'
                else if (result.firstAudio == null)
                  label('gainWakeNoAudio'),
              ].join('\n'),
            ),
          ),
        if (meter == null && _results.isNotEmpty) ...[
          if (widget.changeGain case final changeGain?)
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _opening || widget.busy() || widget.gain <= 1 ? null : () => changeGain(widget.gain - 1),
                  child: Text('${label('gainDown')} · ${(widget.gain - 1).clamp(0, 8)}/8'),
                ),
                OutlinedButton(
                  onPressed: _opening || widget.busy() || widget.gain >= 8 ? null : () => changeGain(widget.gain + 1),
                  child: Text('${label('gainUp')} · ${(widget.gain + 1).clamp(0, 8)}/8'),
                ),
              ],
            ),
          for (final result in _results)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${result.gain} / 8'),
              subtitle: Text(
                [
                  _coverage(context, 'gainRoomReceived', result.room.seconds, 2),
                  _coverage(context, 'gainAudioReceived', result.speech.seconds, 5),
                  if (result.speech.seconds > 0 && result.room.seconds > 0) ...[
                    '${label('gainTestRoom')} · ${_db(result.room.rms)}',
                    '${label('gainTestSpeechLevel')} · ${_db(result.speech.rms)}',
                    '${label('gainTestPeak')} · ${_db(result.speech.peak)}',
                    if (result.room.rms.isFinite && result.speech.rms.isFinite)
                      '${label('gainAboveRoom')} · ${(result.speech.rms - result.room.rms).toStringAsFixed(1)} dB',
                  ],
                  label('gainTestAdvice_${result.advice.name}'),
                ].join('\n'),
              ),
            ),
        ],
      ],
    );
  }
}
