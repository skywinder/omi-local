import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omi/pages/settings/device/device_control_sheets.dart' show micGainLevelLabel;
import 'package:omi/utils/l10n_extensions.dart';

import 'cv1_gain_calibration.dart';
import 'cv1_transport.dart';
import 'settings_labels.dart';
import 'wav_level.dart';

enum _Phase { waiting, settling, room, ready, countdown, speech }

enum _Test { microphone, coldPlayback, awakePlayback }

typedef _PlaybackReading = ({int gain, bool streamingBeforeCue, int? firstAudio, WavLevel level});

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
  _Test _test = _Test.microphone;
  int? _lastCountdownAudio;
  bool _streamingBeforeCue = false;
  int? _firstPlaybackAudio;
  WavLevel? _recent;
  String? _notice;
  final _results = <({int gain, WavLevel room, WavLevel speech, Cv1GainAdvice advice})>[];
  _PlaybackReading? _coldResult;
  _PlaybackReading? _awakeResult;
  _Phase _phase = _Phase.waiting;

  static const _speechSeconds = 5;

  int get _countdownSeconds => switch (_test) {
    _Test.microphone => 3,
    _Test.coldPlayback => 12,
    _Test.awakePlayback => 4,
  };

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

  Future<void> _start([_Test test = _Test.microphone]) async {
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
      _test = test;
      _lastCountdownAudio = null;
      _streamingBeforeCue = false;
      _firstPlaybackAudio = null;
      _enter(test == _Test.microphone ? _Phase.waiting : _Phase.countdown);
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
      } else if (_test != _Test.microphone) {
        if (_phase == _Phase.countdown) _lastCountdownAudio = _quarterSeconds;
        if (_phase == _Phase.speech) _firstPlaybackAudio ??= _quarterSeconds;
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
      case _Phase.speech when _quarterSeconds >= _speechSeconds * 4:
        _finish(report: true);
      case _Phase.settling when _quarterSeconds >= 4:
        setState(() => _enter(_Phase.room));
      case _Phase.room when _quarterSeconds >= 8:
        setState(() => _enter(_Phase.ready));
      case _Phase.ready when _quarterSeconds >= 120:
        _finish(notice: 'gainTestReadyExpired');
      case _Phase.countdown when _quarterSeconds >= _countdownSeconds * 4:
        setState(() {
          // The cold run can begin with an awake mic that falls silent. Only
          // packets near the cue establish that audio was already streaming.
          final last = _lastCountdownAudio;
          _streamingBeforeCue = last != null && _quarterSeconds - last <= 8;
          _enter(_Phase.speech);
        });
      case _:
        setState(() {});
    }
  }

  void _finish({bool report = false, String? notice}) {
    final meter = _meter;
    if (meter == null) return;
    _tick?.cancel();
    _meter = null;
    if (report && _test != _Test.microphone) {
      final reading = (
        gain: widget.gain,
        streamingBeforeCue: _streamingBeforeCue,
        firstAudio: _firstPlaybackAudio,
        level: meter.speech,
      );
      if (_test == _Test.coldPlayback) {
        _coldResult = reading;
        _awakeResult = null;
      } else {
        _awakeResult = reading;
      }
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

  Widget _playbackResult(_PlaybackReading result, {required bool warmed}) {
    String label(String key) => pairedSettingsLabel(context, key);
    final first = result.firstAudio;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${label(warmed ? 'gainWakeAfter' : 'gainWakeBefore')} · ${result.gain} / 8'),
      subtitle: Text(
        [
          _coverage(context, 'gainAudioReceived', result.level.seconds, _speechSeconds),
          if (result.streamingBeforeCue && !warmed) label('gainWakeAlreadyStreaming'),
          if (!result.streamingBeforeCue && warmed) label('gainWakeUnconfirmed'),
          if (first == null)
            label('gainWakeNoAudio')
          else if (!result.streamingBeforeCue)
            '${label('gainWakeFirstAudio')} · ~${(first / 4).toStringAsFixed(1)} s',
          if (result.level.seconds > 0) ...[
            '${label('gainWakeSignal')} · ${_db(result.level.rms)}',
            '${label('gainTestPeak')} · ${_db(result.level.peak)}',
          ],
        ].join('\n'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String label(String key) => pairedSettingsLabel(context, key);
    final meter = _meter;
    final canStart = !_opening && !widget.busy() && widget.gain > 0;
    final latest = _results.firstOrNull;
    final suggestedGain = latest?.gain == widget.gain
        ? switch (latest?.advice) {
            Cv1GainAdvice.low when widget.gain < 8 => widget.gain + 1,
            Cv1GainAdvice.overload when widget.gain > 1 => widget.gain - 1,
            _ => null,
          }
        : null;
    final prompt = switch (_phase) {
      _Phase.waiting => label('gainTestWaiting'),
      _Phase.settling || _Phase.room => label('gainTestQuiet'),
      _Phase.ready => label('gainTestReady'),
      _Phase.countdown =>
        '${label(switch (_test) {
          _Test.microphone => 'gainTestCountdown',
          _Test.coldPlayback => 'gainWakeCountdown',
          _Test.awakePlayback => 'gainWakeWarmCountdown',
        })} · ${_countdownSeconds - _quarterSeconds ~/ 4}',
      _Phase.speech => label(_test == _Test.microphone ? 'gainTestSpeak' : 'gainWakePlayNow'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label('gainTestHelp')),
        if (widget.gain == 0) Text(label('gainTestMuted')),
        if (meter == null) ...[
          TextButton.icon(
            onPressed: canStart ? _start : null,
            icon: const Icon(Icons.graphic_eq),
            label: Text(
              latest != null && latest.gain != widget.gain
                  ? '${label('gainTestRetest')} · ${widget.gain}/8'
                  : label('gainTestStart'),
            ),
          ),
          TextButton.icon(
            onPressed: canStart ? () => _start(_Test.coldPlayback) : null,
            icon: const Icon(Icons.volume_down_outlined),
            label: Text(label('gainWakeStart')),
          ),
        ] else ...[
          Semantics(liveRegion: true, child: Text(prompt)),
          if (_phase == _Phase.ready)
            FilledButton(onPressed: () => setState(() => _enter(_Phase.countdown)), child: Text(label('gainTestGo'))),
          if (_phase == _Phase.speech || _phase == _Phase.room)
            ExcludeSemantics(
              child: LinearProgressIndicator(
                value: (((_recent?.rms ?? double.negativeInfinity) + 70) / 70).clamp(0.0, 1.0),
              ),
            ),
          if (_phase == _Phase.speech)
            Text(_coverage(context, 'gainAudioReceived', meter.speech.seconds, _speechSeconds)),
          TextButton(
            onPressed: () => _finish(notice: 'gainTestCancelled'),
            child: Text(context.l10n.cancel),
          ),
        ],
        if (_notice case final key?) Text(label(key)),
        if (_coldResult case final cold? when meter == null) ...[
          _playbackResult(cold, warmed: false),
          if (_awakeResult case final awake? when awake.gain == cold.gain) ...[
            _playbackResult(awake, warmed: true),
            if (!cold.streamingBeforeCue &&
                cold.level.seconds < 4 &&
                awake.streamingBeforeCue &&
                awake.level.seconds >= 4)
              Text(label('gainWakeDifference')),
          ],
          TextButton.icon(
            onPressed: canStart && cold.gain == widget.gain ? () => _start(_Test.awakePlayback) : null,
            icon: const Icon(Icons.hearing),
            label: Text(label('gainWakeRepeatAwake')),
          ),
          if (cold.gain != widget.gain) Text(label('gainWakeGainChanged')),
        ],
        if (meter == null && (_results.isNotEmpty || _coldResult != null)) ...[
          if ((suggestedGain, widget.changeGain) case (final value?, final changeGain?))
            FilledButton.tonalIcon(
              onPressed: canStart ? () => changeGain(value) : null,
              icon: const Icon(Icons.tune),
              label: Text('${label('gainTestApplySuggestion')} · $value/8 (${micGainLevelLabel(context, value)})'),
            ),
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
                  if (result.room.seconds > 0) '${label('gainTestRoom')} · ${_db(result.room.rms)}',
                  if (result.speech.seconds > 0) ...[
                    '${label('gainTestSpeechLevel')} · ${_db(result.speech.rms)}',
                    '${label('gainTestPeak')} · ${_db(result.speech.peak)}',
                    if (result.room.seconds >= 1.5 &&
                        result.speech.seconds >= 4 &&
                        result.room.rms.isFinite &&
                        result.speech.rms.isFinite)
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
