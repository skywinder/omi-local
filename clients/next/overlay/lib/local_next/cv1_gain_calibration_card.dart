import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omi/pages/settings/device/device_control_sheets.dart' show micGainLevelLabel;
import 'package:omi/utils/l10n_extensions.dart';

import 'cv1_gain_calibration.dart';
import 'cv1_transport.dart';
import 'settings_labels.dart';
import 'wav_level.dart';

class Cv1GainCalibrationCard extends StatefulWidget {
  const Cv1GainCalibrationCard({
    super.key,
    required this.link,
    required this.gain,
    required this.busy,
    this.openDecoder = openCv1GainDecoder,
  });

  final Cv1Connection link;
  final int gain;
  final bool Function() busy;
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
  bool _gotData = false;

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
    if (_opening || widget.busy() || widget.gain == 0) return;
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
      _gotData = false;
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
      if (meter.accept(raw) && !_gotData) {
        _gotData = true;
        _quarterSeconds = 0;
      }
    } catch (_) {
      _finish(notice: 'gainTestDecodeFailed');
    }
  }

  void _advance(Timer timer) {
    final meter = _meter!;
    _quarterSeconds++;
    if (widget.link.audioFailed) {
      _finish(notice: 'nextLinkAudioFailure');
    } else if (_quarterSeconds >= 32) {
      _finish(report: true);
    } else {
      setState(() {
        meter.settling = !_gotData || _quarterSeconds < 4;
        meter.speaking = _gotData && _quarterSeconds >= 12;
      });
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
    final reading = meter == null || !_gotData ? null : (meter.speaking ? meter.speech : meter.room);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label(widget.gain == 0 ? 'gainTestMuted' : 'gainTestHelp')),
        if (meter == null)
          TextButton.icon(
            onPressed: _opening || widget.busy() || widget.gain == 0 ? null : _start,
            icon: const Icon(Icons.graphic_eq),
            label: Text(label('gainTestStart')),
          )
        else ...[
          Semantics(
            liveRegion: true,
            child: Text(label(!_gotData ? 'gainTestWaiting' : (meter.speaking ? 'gainTestSpeak' : 'gainTestQuiet'))),
          ),
          if (reading != null && reading.seconds > 0) ...[
            ExcludeSemantics(child: LinearProgressIndicator(value: ((reading.peak + 60) / 60).clamp(0.0, 1.0))),
            Text('${label('gainTestPeak')} · ${_db(reading.peak)}'),
          ],
          TextButton(
            onPressed: () => _finish(notice: 'gainTestCancelled'),
            child: Text(context.l10n.cancel),
          ),
        ],
        if (_notice case final key?) Text(label(key)),
        if (meter == null)
          for (final result in _results)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${result.gain} / 8 · ${micGainLevelLabel(context, result.gain)}'),
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
    );
  }
}
