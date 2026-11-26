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
  String? _notice;
  final _results = <({int gain, WavLevel room, WavLevel speech, Cv1GainAdvice advice})>[];
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

  Future<void> _start() async {
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
      _phase = _Phase.waiting;
      _quarterSeconds = 0;
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
      if (meter.accept(raw) && _phase == _Phase.waiting) {
        setState(() => _enter(_Phase.settling));
      }
    } catch (_) {
      _finish(notice: 'gainTestDecodeFailed');
    }
  }

  void _enter(_Phase phase) {
    _phase = phase;
    _quarterSeconds = 0;
    _meter!.settling = phase != _Phase.room && phase != _Phase.speech;
    _meter!.speaking = phase == _Phase.speech;
  }

  void _advance(Timer timer) {
    _quarterSeconds++;
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
    if (report) {
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

  @override
  Widget build(BuildContext context) {
    String label(String key) => pairedSettingsLabel(context, key);
    final meter = _meter;
    final reading = meter == null ? null : (_phase == _Phase.speech ? meter.speech : meter.room);
    final prompt = switch (_phase) {
      _Phase.waiting => label('gainTestWaiting'),
      _Phase.settling || _Phase.room => label('gainTestQuiet'),
      _Phase.ready => label('gainTestReady'),
      _Phase.countdown => '${label('gainTestCountdown')} · ${3 - _quarterSeconds ~/ 4}',
      _Phase.speech => label('gainTestSpeak'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label('gainTestHelp')),
        if (meter == null)
          TextButton.icon(
            onPressed: _opening || widget.busy() ? null : _start,
            icon: const Icon(Icons.graphic_eq),
            label: Text(label('gainTestStart')),
          )
        else ...[
          Semantics(liveRegion: true, child: Text(prompt)),
          if (_phase == _Phase.ready)
            FilledButton(onPressed: () => setState(() => _enter(_Phase.countdown)), child: Text(label('gainTestGo'))),
          if (_phase == _Phase.speech && reading != null && reading.seconds > 0) ...[
            ExcludeSemantics(child: LinearProgressIndicator(value: ((reading.peak + 60) / 60).clamp(0.0, 1.0))),
            Text('${label('gainTestPeak')} · ${_db(reading.peak)}'),
          ],
          TextButton(
            onPressed: () => _finish(notice: 'gainTestCancelled'),
            child: Text(context.l10n.cancel),
          ),
        ],
        if (_notice case final key?) Text(label(key)),
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
                  if (result.speech.seconds > 0 && result.room.seconds > 0) ...[
                    '${label('gainTestRoom')} · ${_db(result.room.rms)}',
                    '${label('gainTestSpeechLevel')} · ${_db(result.speech.rms)}',
                    '${label('gainTestPeak')} · ${_db(result.speech.peak)}',
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
