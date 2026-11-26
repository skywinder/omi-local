import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'package:omi/pages/settings/device/device_control_sheets.dart' show micGainLevelLabel;

import 'cv1_gain_calibration_card.dart';
import 'cv1_transport.dart';
import 'gain_samples.dart';
import 'paired_library.dart';
import 'settings_labels.dart';

String cv1PhaseLabel(BuildContext context, Cv1LinkPhase phase) {
  final l = context.l10n;
  return switch (phase) {
    Cv1LinkPhase.idle => l.disconnected,
    Cv1LinkPhase.unavailable => l.bluetoothNeeded,
    Cv1LinkPhase.scanning => l.searchingForDevices,
    Cv1LinkPhase.connecting => l.deviceConnecting,
    Cv1LinkPhase.ready => l.connected,
    Cv1LinkPhase.reconnecting => l.reconnecting,
    Cv1LinkPhase.failed => l.connectionFailed,
  };
}

class NextDeviceDiagnosticsPage extends StatefulWidget {
  const NextDeviceDiagnosticsPage({
    super.key,
    required this.link,
    required this.capture,
    required this.captureBusy,
    this.library,
  });

  final Cv1Connection link;
  final Listenable capture;
  final bool Function() captureBusy;
  final PairedLibrary? library;

  @override
  State<NextDeviceDiagnosticsPage> createState() => _DeviceDiagnosticsState();
}

class _DeviceDiagnosticsState extends State<NextDeviceDiagnosticsPage> {
  Timer? _poll;
  bool _writing = false;
  bool _week = false;
  bool _issuesOnly = false;
  int _eventLimit = 12;
  DateTime? _fullRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  void _refresh({bool force = false}) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (mounted &&
        ModalRoute.isCurrentOf(context) == true &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      final now = widget.link.history.now();
      unawaited(widget.link.sampleSignal());
      if (widget.link.phase == Cv1LinkPhase.ready &&
          !widget.captureBusy() &&
          (force || _fullRefresh == null || now.difference(_fullRefresh!) >= const Duration(seconds: 15))) {
        _fullRefresh = now;
        unawaited(widget.link.sampleDiagnostics());
      }
      setState(() {});
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _edit(String field, String label, int current, int max) async {
    final link = widget.link;
    final connectedAt = link.connectedAt;
    final l = context.l10n;
    var draft = current.clamp(0, max).toDouble();
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDraft) => AlertDialog(
          title: Text(label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (field == 'gain')
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove),
                      tooltip: pairedSettingsLabel(context, 'gainDown'),
                      onPressed: draft > 0 ? () => setDraft(() => draft--) : null,
                    ),
                    Flexible(child: Text('${draft.round()} / 8 · ${micGainLevelLabel(context, draft.round())}')),
                    IconButton(
                      icon: const Icon(Icons.add),
                      tooltip: pairedSettingsLabel(context, 'gainUp'),
                      onPressed: draft < max ? () => setDraft(() => draft++) : null,
                    ),
                  ],
                )
              else
                Text('${draft.round()}'),
              Slider(
                min: 0,
                max: max.toDouble(),
                divisions: max,
                value: draft,
                label: '${draft.round()}',
                onChanged: (value) => setDraft(() => draft = value),
              ),
              if (field == 'gain')
                Wrap(
                  spacing: 6,
                  children: [
                    for (final (title, level) in [(l.quiet, 2), (l.normal, 4), (l.high, 6)])
                      ChoiceChip(
                        label: Text(title),
                        selected: draft.round() == level,
                        onSelected: (_) => setDraft(() => draft = level.toDouble()),
                      ),
                  ],
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, draft.round()), child: Text(l.save)),
          ],
        ),
      ),
    );
    if (!mounted ||
        selected == null ||
        selected == current ||
        connectedAt != link.connectedAt ||
        widget.captureBusy()) {
      return;
    }
    setState(() => _writing = true);
    final saved = await link.writeSetting(field, selected);
    if (!mounted) return;
    setState(() => _writing = false);
    if (!saved) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(pairedSettingsLabel(context, 'nextCv1SettingsFailed'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final link = widget.link;
    return ListenableBuilder(
      listenable: Listenable.merge([link, widget.capture]),
      builder: (context, _) {
        final data = link.diagnostics;
        final ready = link.phase == Cv1LinkPhase.ready;
        final now = link.history.now();
        final battery = data?.battery;
        final signalAt = link.signalMeasuredAt;
        final signal = signalAt != null && now.difference(signalAt) < const Duration(seconds: 12) ? data?.rssi : null;
        final oldest = now.subtract(Cv1History.retention);
        final events = link.transitions.reversed
            .where((event) => !event.at.isBefore(oldest) && (!_issuesOnly || _isIssue(event)))
            .toList();
        final drops = link.transitions
            .where(
              (event) =>
                  event.phase != Cv1LinkPhase.ready &&
                  event.uptime != null &&
                  _isIssue(event) &&
                  !event.at.isBefore(oldest),
            )
            .length;
        return Scaffold(
          appBar: AppBar(
            title: Text(l.deviceDiagnostics),
            actions: [
              IconButton(
                onPressed: ready ? () => _refresh(force: true) : null,
                tooltip: l.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(OmiSpacing.md),
            children: [
              _Card(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: cv1DeviceIcon(link),
                    title: Text(data?.name ?? 'Omi CV1'),
                    subtitle: Text(cv1DeviceStatus(context, link)),
                  ),
                  if (!ready)
                    Text(pairedSettingsLabel(context, 'nextDeviceUnavailable'))
                  else ...[
                    Wrap(
                      spacing: 24,
                      runSpacing: 8,
                      children: [
                        _Reading(
                          title: l.battery,
                          value: battery == null ? '—' : '$battery%',
                          detail: [
                            if (data?.charging == true) l.charging,
                            if (link.batteryMeasuredAt case final at?) _time(context, at),
                          ].join(' · '),
                          color: battery == null ? null : _batteryColor(battery),
                        ),
                        _Reading(
                          title: l.signal,
                          value: signal == null ? '—' : '$signal dBm',
                          detail: signal == null
                              ? ''
                              : [
                                  _quality(context, signal),
                                  if (link.signalMeasuredAt case final at?) _time(context, at),
                                ].join(' · '),
                          color: signal == null ? null : _signalColor(signal),
                        ),
                        if (link.connectedAt case final at?)
                          _Reading(title: l.connectionUptime, value: _duration(now.difference(at)), detail: ''),
                      ],
                    ),
                  ],
                ],
              ),
              if (data?.gain case final int gain when ready && data?.gainWritable == true && gain >= 0 && gain <= 8)
                _Card(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.mic_outlined),
                      title: Text(l.micGain),
                      subtitle: Text('$gain / 8 · ${micGainLevelLabel(context, gain)}'),
                      trailing: const Icon(Icons.tune),
                      onTap: widget.captureBusy() || _writing ? null : () => _edit('gain', l.micGain, gain, 8),
                    ),
                    if (widget.captureBusy() && !link.calibrating)
                      Text(pairedSettingsLabel(context, 'nextCv1SettingsBusy')),
                    Cv1GainCalibrationCard(link: link, gain: gain, busy: () => _writing || widget.captureBusy()),
                    if (widget.library case final library? when library.audioPlayback)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(pairedSettingsLabel(context, 'gainArchive')),
                        children: [GainSamples(key: ObjectKey(library), library: library)],
                      ),
                  ],
                ),
              _History(
                title: l.signalStrength,
                samples: link.rssiHistory,
                now: now,
                window: const Duration(minutes: 10),
                battery: false,
              ),
              _History(
                title: pairedSettingsLabel(context, 'nextBatteryHistory'),
                samples: link.batteryHistory,
                now: now,
                window: Duration(days: _week ? 7 : 1),
                battery: true,
                action: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: false, label: Text(l.day)),
                    ButtonSegment(value: true, label: Text(l.week)),
                  ],
                  selected: {_week},
                  onSelectionChanged: (value) => setState(() => _week = value.single),
                ),
              ),
              _Card(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          pairedSettingsLabel(context, 'nextLinkHistory'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: pairedSettingsLabel(context, 'nextCopyDeviceLog'),
                        onPressed: link.transitions.isEmpty ? null : () => _copyLog(link),
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: OmiSpacing.sm,
                    children: [
                      Text(pairedSettingsLabel(context, 'nextDropsInWeek')),
                      Text('$drops', style: Theme.of(context).textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: OmiSpacing.sm),
                  FilterChip(
                    label: Text(pairedSettingsLabel(context, 'nextLinkIssuesOnly')),
                    selected: _issuesOnly,
                    onSelected: (value) => setState(() {
                      _issuesOnly = value;
                      _eventLimit = 12;
                    }),
                  ),
                  if (events.isEmpty) ...[
                    const SizedBox(height: OmiSpacing.sm),
                    Text(pairedSettingsLabel(context, 'nextDeviceNoEvents')),
                  ],
                  for (final event in events.take(_eventLimit)) _EventRow(event: event),
                  if (events.length > _eventLimit)
                    TextButton(
                      onPressed: () => setState(() => _eventLimit += 12),
                      child: Text(pairedSettingsLabel(context, 'nextMoreDeviceEvents')),
                    ),
                ],
              ),
              if (ready) _deviceDetails(data, link),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copyLog(Cv1Connection link) async {
    await Clipboard.setData(ClipboardData(text: link.history.exportLog()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(pairedSettingsLabel(context, 'nextDeviceLogCopied'))));
    }
  }

  Widget _deviceDetails(Cv1Diagnostics? data, Cv1Connection link) {
    final l = context.l10n;
    final canEdit = !widget.captureBusy() && !_writing;
    return _Card(
      children: [
        ExpansionTile(
          key: const PageStorageKey('cv1-device-info'),
          tilePadding: EdgeInsets.zero,
          title: Text(l.deviceInfoSection),
          children: [
            if (link.codec case final codec?)
              ListTile(title: Text(l.audioFormatLabel), trailing: Text(codec == 20 ? 'Opus' : 'Opus · $codec')),
            for (final (label, value) in [
              (l.firmware, data?.firmware),
              (l.modelNumber, data?.model),
              (l.hardwareRevision, data?.hardware),
              (l.manufacturer, data?.manufacturer),
            ])
              if (value != null) ListTile(title: Text(label), subtitle: Text(value)),
            if (data?.ledWritable == true && data?.led != null)
              ListTile(
                title: Text(l.ledBrightness),
                trailing: Text('${data!.led}%'),
                onTap: canEdit ? () => _edit('led', l.ledBrightness, data.led!, 100) : null,
              ),
            if (widget.captureBusy() && (data?.ledWritable == true || data?.gainWritable == true))
              ListTile(title: Text(pairedSettingsLabel(context, 'nextCv1SettingsBusy'))),
          ],
        ),
      ],
    );
  }
}

String _duration(Duration value) => OmiDuration.offset(value.inSeconds.toDouble());

String _time(BuildContext context, DateTime value) =>
    DateFormat.Hms(Localizations.localeOf(context).toLanguageTag()).format(value.toLocal());

String _quality(BuildContext context, int value) => switch (value) {
  >= -60 => context.l10n.excellent,
  >= -75 => context.l10n.good,
  >= -85 => context.l10n.fair,
  _ => context.l10n.weak,
};

Color _signalColor(int value) => value >= -75
    ? OmiColors.success
    : value >= -85
    ? OmiColors.warning
    : OmiColors.danger;
Color _batteryColor(int value) => value > 20
    ? OmiColors.success
    : value > 10
    ? OmiColors.warning
    : OmiColors.danger;

bool _isIssue(Cv1Transition event) =>
    (event.reason != null && event.reason != Cv1LinkReason.manual) || event.phase == Cv1LinkPhase.failed;

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: OmiSpacing.md),
    color: OmiColors.surface1,
    child: Padding(
      padding: const EdgeInsets.all(OmiSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    ),
  );
}

class _Reading extends StatelessWidget {
  const _Reading({required this.title, required this.value, required this.detail, this.color});

  final String title, value, detail;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.labelMedium),
        Text(value, style: theme.titleLarge?.copyWith(color: color)),
        if (detail.isNotEmpty) Text(detail, style: theme.bodySmall),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final Cv1Transition event;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final reason = _reasonLabel(context, event.phase, event.reason);
    final details = [
      DateFormat.MMMd(Localizations.localeOf(context).toLanguageTag()).format(event.at),
      _time(context, event.at),
      if (event.rssi case final signal?) '$signal dBm',
      if (event.battery case final battery?) '$battery%',
      if (event.uptime case final duration?) '${l.connectionUptime} ${_duration(duration)}',
      if (event.downtime case final duration?)
        '${pairedSettingsLabel(context, 'nextReconnectedIn')} ${_duration(duration)}',
      if (event.code case final code? when code != 0) 'BLE $code',
    ];
    final Color? color = _isIssue(event)
        ? OmiColors.warning
        : event.phase == Cv1LinkPhase.ready
        ? OmiColors.success
        : null;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.circle, color: color, size: 9),
      title: Text(reason),
      subtitle: Text(details.join(' · ')),
    );
  }
}

class _History extends StatelessWidget {
  const _History({
    required this.title,
    required this.samples,
    required this.now,
    required this.window,
    required this.battery,
    this.action,
  });

  final String title;
  final List<Cv1Sample> samples;
  final DateTime now;
  final Duration window;
  final bool battery;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cutoff = now.subtract(window);
    final points = samples.where((sample) => !sample.at.isBefore(cutoff)).toList();
    return _Card(
      children: [
        Wrap(
          spacing: 12,
          runSpacing: OmiSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            if (action != null) action!,
          ],
        ),
        const SizedBox(height: OmiSpacing.sm),
        if (points.isEmpty)
          Text(pairedSettingsLabel(context, 'nextSamplesMissing'))
        else ...[
          _Reading(
            title: pairedSettingsLabel(context, 'nextLastMeasurement'),
            value: '${points.last.value}${battery ? '%' : ' dBm'}',
            detail: _time(context, points.last.at),
            color: battery ? _batteryColor(points.last.value) : _signalColor(points.last.value),
          ),
          const SizedBox(height: OmiSpacing.sm),
          SizedBox(height: 156, child: _chart(context, points, cutoff)),
        ],
      ],
    );
  }

  Widget _chart(BuildContext context, List<Cv1Sample> points, DateTime cutoff) {
    final theme = Theme.of(context);
    final start = battery ? cutoff : points.first.at;
    final end = battery ? now : points.last.at;
    final extent = (end.difference(start).inMilliseconds / 1000).clamp(1.0, window.inSeconds.toDouble());
    final maximumGap = battery ? const Duration(minutes: 25) : const Duration(seconds: 15);
    final color = battery ? _batteryColor(points.last.value) : _signalColor(points.last.value);
    final spots = <FlSpot>[];
    final individual = <FlSpot>{};
    Cv1Sample? previous;
    var runStart = 0;
    for (final sample in points) {
      if (previous != null && (sample.series != previous.series || sample.at.difference(previous.at) > maximumGap)) {
        if (spots.length == runStart + 1) individual.add(spots.last);
        spots.add(FlSpot.nullSpot);
        runStart = spots.length;
      }
      spots.add(FlSpot(sample.at.difference(start).inMilliseconds / 1000, sample.value.toDouble()));
      previous = sample;
    }
    if (spots.length == runStart + 1) individual.add(spots.last);
    final tick = extent <= 20
        ? 5.0
        : extent <= 60
        ? 15.0
        : extent <= 180
        ? 30.0
        : 120.0;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: extent,
        minY: battery ? 0 : -128,
        maxY: battery ? 100 : 0,
        borderData: FlBorderData(show: false),
        gridData: FlGridData(horizontalInterval: battery ? 25 : 30, drawVerticalLine: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: battery ? 25 : 30,
              getTitlesWidget: (value, _) => !battery && value < -120
                  ? const SizedBox.shrink()
                  : Text('${value.round()}', style: theme.textTheme.labelSmall),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: battery ? window.inSeconds / 3 : tick,
              getTitlesWidget: (value, _) {
                final at = start.add(Duration(seconds: value.round()));
                return Text(
                  battery
                      ? (window.inDays == 1 ? DateFormat.Hm(locale) : DateFormat.Md(locale)).format(at)
                      : OmiDuration.offset(value),
                  style: theme.textTheme.labelSmall,
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipColor: (_) => theme.colorScheme.surface,
            getTooltipItems: (touched) => touched.map((spot) {
              final at = start.add(Duration(milliseconds: (spot.x * 1000).round()));
              final label = '${spot.y.round()}${battery ? '%' : ' dBm'} · ${_time(context, at)}';
              return LineTooltipItem(label, TextStyle(color: theme.colorScheme.onSurface));
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            color: color,
            barWidth: 2.5,
            dotData: FlDotData(
              show: true,
              checkToShowDot: (spot, _) => points.length < 15 || individual.contains(spot),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color.withValues(alpha: .20), color.withValues(alpha: 0)],
              ),
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    );
  }
}

String _reasonLabel(BuildContext context, Cv1LinkPhase phase, Cv1LinkReason? reason) {
  final l = context.l10n;
  return switch (reason) {
    Cv1LinkReason.manual => l.manualDisconnect,
    Cv1LinkReason.radio => l.bluetoothNeeded,
    Cv1LinkReason.permission => pairedSettingsLabel(context, 'nextCv1ScanPermission'),
    Cv1LinkReason.timeout => l.connectionTimeout,
    Cv1LinkReason.incompatible => pairedSettingsLabel(context, 'nextLinkIncompatible'),
    Cv1LinkReason.dropped => pairedSettingsLabel(context, 'nextLinkLost'),
    Cv1LinkReason.remote => l.remoteDeviceTerminated,
    Cv1LinkReason.connect => l.connectionFailed,
    Cv1LinkReason.audio => pairedSettingsLabel(context, 'nextLinkAudioFailure'),
    null => cv1PhaseLabel(context, phase),
  };
}

class Cv1HeaderTitle extends StatelessWidget {
  const Cv1HeaderTitle({super.key, required this.title, required this.link});
  final String title;
  final Cv1Connection? link;

  @override
  Widget build(BuildContext context) {
    final heading = Text(title, maxLines: 1, overflow: TextOverflow.ellipsis);
    final connection = link;
    if (connection == null) return heading;
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) {
        if (connection.phase != Cv1LinkPhase.ready) return heading;
        final value = connection.diagnostics?.battery;
        final label = value == null ? '—' : '$value%';
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: heading),
            const SizedBox(width: 8),
            Tooltip(
              message: 'CV1 · ${context.l10n.battery} · $label',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  value == null ? const Icon(Icons.battery_unknown, size: 18) : cv1DeviceIcon(connection),
                  const SizedBox(width: 2),
                  Text(label, style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

String cv1DeviceStatus(BuildContext context, Cv1Connection link) {
  final state = link.linkState;
  if (state != null && state.phase == Cv1LinkPhase.failed) {
    final label = _reasonLabel(context, state.phase, state.reason);
    final code = state.code;
    return code == null || code == 0 ? label : '$label · BLE $code';
  }
  final battery = link.diagnostics?.battery;
  return link.phase == Cv1LinkPhase.ready && battery != null ? '$battery%' : cv1PhaseLabel(context, link.phase);
}

Widget cv1DeviceIcon(Cv1Connection link) {
  final battery = link.diagnostics?.battery;
  if (link.phase != Cv1LinkPhase.ready || battery == null) {
    return Icon(link.phase == Cv1LinkPhase.ready ? Icons.bluetooth_connected : Icons.bluetooth, size: 18);
  }
  return Icon(
    switch (battery) {
      <= 15 => Icons.battery_alert,
      <= 35 => Icons.battery_2_bar,
      <= 65 => Icons.battery_4_bar,
      <= 85 => Icons.battery_5_bar,
      _ => Icons.battery_full,
    },
    color: _batteryColor(battery),
    size: 19,
  );
}
