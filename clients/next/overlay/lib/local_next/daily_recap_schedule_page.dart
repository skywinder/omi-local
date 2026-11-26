import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:uuid/uuid.dart';

import 'daily_recap.dart';
import 'paired_library.dart';
import 'settings_labels.dart';
import 'task_reminder_sync.dart';

class DailyRecapSchedulePage extends StatefulWidget {
  const DailyRecapSchedulePage({super.key, required this.library});
  final PairedLibrary library;

  @override
  State<DailyRecapSchedulePage> createState() => _ScheduleState();
}

class _ScheduleState extends State<DailyRecapSchedulePage> {
  final _zone = TextEditingController();
  DailyRecapSchedule? _saved;
  bool _enabled = false;
  bool _busy = false;
  bool _failed = false;
  bool _changed = false;
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  Map<String, dynamic>? _attempt;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _zone.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
      _changed = false;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _changed = error == DailyRecapFailure.changed;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _accept(DailyRecapSchedule value) {
    _saved = value;
    _enabled = value.enabled;
    _zone.text = value.timezone;
    _time = TimeOfDay(hour: value.hour, minute: value.minute);
    _attempt = null;
  }

  Future<void> _load() => _run(() async {
    final value = await widget.library.dailyRecapSchedule();
    String? zone;
    if (value.revision.isEmpty) {
      try {
        zone = await TaskReminderSync.timezone();
      } catch (_) {
        /* UTC stays visible. */
      }
    }
    if (!mounted) return;
    setState(() {
      _accept(value);
      if (zone != null) _zone.text = zone;
    });
  });

  Future<void> _save() => _run(() async {
    final saved = _saved!;
    final body = <String, dynamic>{
      'revision': saved.revision,
      'enabled': _enabled,
      'timezone': _zone.text.trim(),
      'hour': _time.hour,
      'minute': _time.minute,
      'provider_binding': _enabled ? saved.provider!.binding : '',
    };
    final old = _attempt;
    final same = old != null && body.entries.every((item) => old[item.key] == item.value);
    _attempt = {...body, 'request_id': same ? old['request_id'] : const Uuid().v4()};
    final value = await widget.library.saveDailyRecapSchedule(_attempt!);
    if (mounted) setState(() => _accept(value));
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    String label(String key) => pairedSettingsLabel(context, key);
    final saved = _saved;
    final provider = saved?.provider;
    return Scaffold(
      appBar: AppBar(
        title: Text(label('recapScheduleTitle')),
        actions: [IconButton(tooltip: l.refresh, onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(OmiSpacing.md),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_failed) Text(_changed ? label('recapScheduleChanged') : l.couldNotLoadPage),
          if (saved != null) ...[
            Text(label('recapScheduleConsent')),
            if (provider != null)
              Text('${provider.model}\n${provider.host}')
            else
              Text(label('summaryRegenerateNoModel')),
            SwitchListTile(
              title: Text(label('recapScheduleEnabled')),
              value: _enabled,
              onChanged: _busy ? null : (value) => setState(() => _enabled = value),
            ),
            TextField(
              controller: _zone,
              enabled: !_busy,
              decoration: InputDecoration(labelText: label('recapScheduleTimezone')),
            ),
            ListTile(
              title: Text(label('recapScheduleTime')),
              subtitle: Text(_time.format(context)),
              onTap: _busy
                  ? null
                  : () async {
                      final value = await showTimePicker(context: context, initialTime: _time);
                      if (mounted && value != null) setState(() => _time = value);
                    },
            ),
            Text(label('recapScheduleStatus_${saved.status}')),
            if (saved.lastDay != null) Text('${label('recapScheduleLastDay')}: ${saved.lastDay}'),
            if (saved.enabled && saved.nextDay != null) Text('${label('recapScheduleNextDay')}: ${saved.nextDay}'),
            if (saved.enabled && saved.wire['model'] != null)
              Text('${label('recapScheduleSavedModel')}: ${saved.wire['model']} · ${saved.wire['host']}'),
            FilledButton(onPressed: _busy || (_enabled && provider == null) ? null : _save, child: Text(l.save)),
          ],
        ],
      ),
    );
  }
}
