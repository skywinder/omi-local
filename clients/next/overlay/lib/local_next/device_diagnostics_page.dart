import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'cv1_transport.dart';
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
  const NextDeviceDiagnosticsPage({super.key, required this.link, required this.capture, required this.captureBusy});

  final Cv1Connection link;
  final Listenable capture;
  final bool Function() captureBusy;

  @override
  State<NextDeviceDiagnosticsPage> createState() => _DeviceDiagnosticsState();
}

class _DeviceDiagnosticsState extends State<NextDeviceDiagnosticsPage> {
  Timer? _poll;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  void _refresh() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (mounted &&
        ModalRoute.isCurrentOf(context) == true &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      if (!widget.captureBusy()) unawaited(widget.link.sampleDiagnostics());
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
              Text('${draft.round()}'),
              Slider(
                min: 0,
                max: max.toDouble(),
                divisions: max,
                value: draft,
                label: '${draft.round()}',
                onChanged: (value) => setDraft(() => draft = value),
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
        final canEdit = ready && !widget.captureBusy() && !_writing;
        final clock = MaterialLocalizations.of(context);
        return Scaffold(
          appBar: AppBar(
            title: Text(l.deviceDiagnostics),
            actions: [
              IconButton(onPressed: ready ? _refresh : null, tooltip: l.refresh, icon: const Icon(Icons.refresh)),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(OmiSpacing.md),
            children: [
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(data?.name ?? 'Omi CV1'),
                subtitle: Text(cv1PhaseLabel(context, link.phase)),
              ),
              if (!ready)
                ListTile(title: Text(pairedSettingsLabel(context, 'nextDeviceUnavailable')))
              else ...[
                if (data?.battery case final battery?)
                  ListTile(
                    leading: const Icon(Icons.battery_std),
                    title: Text(l.battery),
                    trailing: Text('$battery%'),
                    subtitle: data?.charging == true ? Text(l.charging) : null,
                  ),
                if (data?.rssi case final signal?)
                  ListTile(
                    leading: const Icon(Icons.signal_cellular_alt),
                    title: const Text('RSSI'),
                    trailing: Text('$signal dBm'),
                  ),
                if (link.connectedAt case final connectedAt?)
                  ListTile(
                    title: Text(l.connectionUptime),
                    trailing: Text(l.secondsCount(DateTime.now().difference(connectedAt).inSeconds)),
                  ),
                ListTile(title: Text(l.reconnections), trailing: Text('${link.reconnections}')),
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
                if (data?.gainWritable == true && data?.gain != null)
                  ListTile(
                    title: Text(l.micGain),
                    trailing: Text('${data!.gain}'),
                    onTap: canEdit ? () => _edit('gain', l.micGain, data.gain!, 8) : null,
                  ),
                if (!canEdit && (data?.ledWritable == true || data?.gainWritable == true) && widget.captureBusy())
                  ListTile(title: Text(pairedSettingsLabel(context, 'nextCv1SettingsBusy'))),
              ],
              _History(
                title: pairedSettingsLabel(context, 'nextBatteryHistory'),
                samples: link.batteryHistory,
                min: 0,
                max: 100,
                unit: '%',
              ),
              _History(
                title: pairedSettingsLabel(context, 'nextSignalHistory'),
                samples: link.rssiHistory,
                min: -128,
                max: 0,
                unit: ' dBm',
              ),
              if (link.transitions.isNotEmpty) ...[
                ListTile(title: Text(pairedSettingsLabel(context, 'nextLinkHistory'))),
                for (final event in link.transitions.reversed)
                  ListTile(
                    dense: true,
                    title: Text(cv1PhaseLabel(context, event.phase)),
                    trailing: Text(clock.formatTimeOfDay(TimeOfDay.fromDateTime(event.at))),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _History extends StatelessWidget {
  const _History({
    required this.title,
    required this.samples,
    required this.min,
    required this.max,
    required this.unit,
  });

  final String title, unit;
  final List<Cv1Sample> samples;
  final double min, max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: OmiSpacing.md),
      color: OmiColors.surface1,
      child: Padding(
        padding: const EdgeInsets.all(OmiSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: OmiSpacing.sm),
            if (samples.isEmpty)
              Text(pairedSettingsLabel(context, 'nextSamplesMissing'))
            else ...[
              Text('${samples.last.value}$unit', style: theme.textTheme.titleLarge),
              if (samples.length > 1) ...[
                const SizedBox(height: OmiSpacing.sm),
                SizedBox(
                  height: 112,
                  child: LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: samples.last.at.difference(samples.first.at).inMilliseconds.clamp(1, 1 << 30).toDouble(),
                      minY: min,
                      maxY: max,
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(),
                        rightTitles: const AxisTitles(),
                        bottomTitles: const AxisTitles(),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 36,
                            interval: (max - min) / 2,
                            getTitlesWidget: (value, _) =>
                                Text(value.round().toString(), style: theme.textTheme.labelSmall),
                          ),
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      gridData: const FlGridData(drawVerticalLine: false),
                      lineTouchData: const LineTouchData(enabled: false),
                      lineBarsData: [
                        LineChartBarData(
                          color: OmiColors.accent,
                          barWidth: 2,
                          dotData: const FlDotData(show: false),
                          spots: [
                            for (final sample in samples)
                              FlSpot(
                                sample.at.difference(samples.first.at).inMilliseconds.toDouble(),
                                sample.value.toDouble(),
                              ),
                          ],
                        ),
                      ],
                    ),
                    duration: Duration.zero,
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(OmiDuration.offset(0)),
                    Text(OmiDuration.offset(samples.last.at.difference(samples.first.at).inMilliseconds / 1000)),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
