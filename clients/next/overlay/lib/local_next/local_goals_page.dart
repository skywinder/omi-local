import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/gen/goals_wire.g.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:uuid/uuid.dart';

import 'local_goal.dart';
import 'paired_library.dart';
import 'recording_page.dart';
import 'settings_labels.dart';

class LocalGoalsPage extends StatefulWidget {
  const LocalGoalsPage({super.key, required this.library, this.conversationId});

  final PairedLibrary library;
  final String? conversationId;

  @override
  State<LocalGoalsPage> createState() => _LocalGoalsState();
}

class _LocalGoalsState extends State<LocalGoalsPage> {
  late Future<List<GeneratedGoalResponse>> _rows = widget.library.listGoals();

  void _refresh() {
    setState(() {
      _rows = widget.library.listGoals();
    });
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final attached = widget.conversationId != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(attached ? pairedSettingsLabel(context, 'localGoalLog') : l.goals),
        actions: [IconButton(tooltip: l.refresh, onPressed: _refresh, icon: const Icon(Icons.refresh))],
      ),
      body: FutureBuilder(
        future: _rows,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          final rows = snapshot.data;
          if (rows == null) return Center(child: Text(l.couldNotLoadPage));
          final visible = attached ? rows.where((row) => row.status == 'background' || row.status == 'focused') : rows;
          return ListView(
            padding: const EdgeInsets.all(OmiSpacing.md),
            children: [
              if (attached) Text(pairedSettingsLabel(context, 'localGoalAttached')),
              for (final row in visible)
                ListTile(
                  title: Text(row.title),
                  subtitle: Text(
                    [
                      pairedSettingsLabel(context, localGoalStatusLabel(row.status)),
                      if (row.metric case final metric?) _metricText(metric),
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(
                    _GoalDetailPage(library: widget.library, id: row.id, conversationId: widget.conversationId),
                  ),
                ),
              if (visible.isEmpty) Text(pairedSettingsLabel(context, 'localGoalEmpty')),
              FilledButton(
                onPressed: () => _open(_GoalEntryPage(library: widget.library)),
                child: Text(l.addGoal),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _number(double value) => value == value.roundToDouble() ? value.toInt().toString() : value.toString();
String _metricText(GeneratedGoalMetric metric) =>
    '${_number(metric.current)} / ${_number(metric.target)}${metric.unit == null ? '' : ' ${metric.unit}'}';

class _GoalDetailPage extends StatefulWidget {
  const _GoalDetailPage({required this.library, required this.id, this.conversationId});

  final PairedLibrary library;
  final String id;
  final String? conversationId;

  @override
  State<_GoalDetailPage> createState() => _GoalDetailState();
}

class _GoalDetailState extends State<_GoalDetailPage> {
  late Future<LocalGoalDetail> _detail = widget.library.readGoal(widget.id);

  bool _savingStatus = false;
  String? _statusError;
  ({String revision, LocalGoalTransition transition, String requestId})? _statusRequest;

  Future<void> _changeStatus(LocalGoalDetail detail, LocalGoalTransition action) async {
    if (_savingStatus) return;
    final l = context.l10n;
    final actionLabel = pairedSettingsLabel(context, action.label);
    if (action == LocalGoalTransition.achieve || action == LocalGoalTransition.abandon) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(actionLabel),
          content: Text(pairedSettingsLabel(context, 'localGoalEndHint')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.confirm)),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    var request = _statusRequest;
    if (request == null || request.revision != detail.revision || request.transition != action) {
      request = (revision: detail.revision, transition: action, requestId: const Uuid().v4());
    }
    _statusRequest = request;
    setState(() {
      _savingStatus = true;
      _statusError = null;
    });
    try {
      await widget.library.changeGoalStatus(
        detail.goal.id,
        action,
        revision: request.revision,
        requestId: request.requestId,
      );
      if (mounted) _refresh();
    } catch (error) {
      if (!mounted) return;
      if (error == LocalGoalFailure.conflict) {
        _statusRequest = null;
        _refresh();
        _statusError = pairedSettingsLabel(context, 'localGoalStatusConflict');
      } else {
        _statusError = pairedSettingsLabel(context, 'localGoalStatusUnavailable');
      }
    } finally {
      if (mounted) setState(() => _savingStatus = false);
    }
  }

  void _refresh() {
    setState(() {
      _detail = widget.library.readGoal(widget.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final calendar = MaterialLocalizations.of(context);
    return FutureBuilder(
      future: _detail,
      builder: (context, snapshot) {
        final detail = snapshot.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(detail?.goal.title ?? l.goals),
            actions: [
              IconButton(
                tooltip: l.refresh,
                onPressed: _savingStatus ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
              if (widget.library.goalLifecycleAvailable &&
                  widget.conversationId == null &&
                  detail != null &&
                  (detail.acceptsProgress || detail.goal.status == 'paused'))
                PopupMenuButton<LocalGoalTransition>(
                  tooltip: pairedSettingsLabel(context, 'localGoalActions'),
                  enabled: !_savingStatus && snapshot.connectionState == ConnectionState.done,
                  onSelected: (action) => _changeStatus(detail, action),
                  itemBuilder: (_) => [
                    for (final action in [
                      if (detail.goal.status == 'paused') LocalGoalTransition.resume else LocalGoalTransition.pause,
                      LocalGoalTransition.achieve,
                      LocalGoalTransition.abandon,
                    ])
                      PopupMenuItem(value: action, child: Text(pairedSettingsLabel(context, action.label))),
                  ],
                ),
            ],
          ),
          body: snapshot.connectionState != ConnectionState.done
              ? const Center(child: CircularProgressIndicator())
              : detail == null
              ? Center(child: Text(l.couldNotLoadPage))
              : ListView(
                  padding: const EdgeInsets.all(OmiSpacing.md),
                  children: [
                    if (_savingStatus) const LinearProgressIndicator(),
                    if (_statusError case final error?) Text(error),
                    Text(pairedSettingsLabel(context, localGoalStatusLabel(detail.goal.status))),
                    if (detail.goal.metric case final metric?) Text(_metricText(metric)),
                    if (detail.acceptsProgress)
                      FilledButton(
                        onPressed: _savingStatus
                            ? null
                            : () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => _GoalEntryPage(
                                      library: widget.library,
                                      detail: detail,
                                      conversationId: widget.conversationId,
                                    ),
                                  ),
                                );
                                if (mounted) _refresh();
                              },
                        child: Text(pairedSettingsLabel(context, 'localGoalLog')),
                      ),
                    for (final event in detail.events) ...[
                      ListTile(
                        title: Text(event.summary),
                        subtitle: Text(calendar.formatFullDate(event.createdAt.toLocal())),
                        trailing: event.metric == null ? null : Text(_number(event.metric!.current)),
                      ),
                      for (final ref in event.evidenceRefs ?? [])
                        if (ref.kind == 'conversation' && ref.scope == 'canonical')
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => RecordingPage(library: widget.library, id: ref.id),
                              ),
                            ),
                            child: Text(pairedSettingsLabel(context, 'localTaskSource')),
                          ),
                    ],
                    for (final entry in detail.legacyHistory)
                      ListTile(title: Text(_number(entry.value)), subtitle: Text(entry.date)),
                  ],
                ),
        );
      },
    );
  }
}

class _GoalEntryPage extends StatefulWidget {
  const _GoalEntryPage({required this.library, this.detail, this.conversationId});

  final PairedLibrary library;
  final LocalGoalDetail? detail;
  final String? conversationId;

  @override
  State<_GoalEntryPage> createState() => _GoalEntryState();
}

class _GoalEntryState extends State<_GoalEntryPage> {
  final _note = TextEditingController();
  final _numberEntry = TextEditingController();
  final _unit = TextEditingController();
  ({String id, String encoded})? _attempt;
  Object? _error;
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    _numberEntry.dispose();
    _unit.dispose();
    super.dispose();
  }

  double? get _enteredNumber => double.tryParse(_numberEntry.text.trim().replaceAll(',', '.'));

  Future<void> _save() async {
    if (_busy) return;
    final detail = widget.detail;
    final value = _enteredNumber;
    final body = detail == null
        ? <String, Object?>{
            'title': _note.text.trim(),
            if (value != null) 'target': value,
            if (value != null && _unit.text.trim().isNotEmpty) 'unit': _unit.text.trim(),
          }
        : <String, Object?>{
            'expected_revision': detail.revision,
            'note': _note.text.trim(),
            if (value != null) 'metric': {...detail.goal.metric!.toJson(), 'current': value},
            if (widget.conversationId != null) 'conversation_id': widget.conversationId,
          };
    final encoded = jsonEncode(body);
    final attempt = _attempt?.encoded == encoded ? _attempt! : (id: const Uuid().v4(), encoded: encoded);
    _attempt = attempt;
    body['request_id'] = attempt.id;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (detail == null) {
        await widget.library.createGoal(body);
      } else {
        await widget.library.logGoalProgress(detail.goal.id, body);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final creating = widget.detail == null;
    final metric = widget.detail?.goal.metric;
    final value = _enteredNumber;
    final validNumber =
        _numberEntry.text.trim().isEmpty ||
        (value != null &&
            value.isFinite &&
            (creating
                ? value > 0
                : (metric?.min == null || value >= metric!.min!) &&
                      (metric?.max == null || value <= metric!.max!) &&
                      (metric?.type != 'boolean' || value == 0 || value == 1)));
    final enabled = !_busy && _error != LocalGoalFailure.conflict;
    return Scaffold(
      appBar: AppBar(title: Text(creating ? l.addGoal : pairedSettingsLabel(context, 'localGoalLog'))),
      body: ListView(
        padding: const EdgeInsets.all(OmiSpacing.md),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error == LocalGoalFailure.conflict
                  ? pairedSettingsLabel(context, 'localGoalConflict')
                  : l.couldNotLoadPage,
            ),
          if (widget.conversationId != null) Text(pairedSettingsLabel(context, 'localGoalAttached')),
          TextField(
            controller: _note,
            maxLength: creating ? 500 : 1000,
            maxLines: creating ? 1 : 4,
            enabled: enabled,
            decoration: InputDecoration(
              labelText: creating ? l.goalTitle : pairedSettingsLabel(context, 'localGoalNote'),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (creating || metric != null)
            TextField(
              controller: _numberEntry,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: InputDecoration(
                labelText: pairedSettingsLabel(context, creating ? 'localGoalTarget' : 'localGoalValue'),
                helperText: metric == null ? null : _metricText(metric),
              ),
              onChanged: (_) => setState(() {}),
            ),
          if (creating && value != null)
            TextField(
              controller: _unit,
              maxLength: 64,
              enabled: enabled,
              decoration: InputDecoration(labelText: pairedSettingsLabel(context, 'localGoalUnit')),
            ),
          FilledButton(
            onPressed: enabled && _note.text.trim().isNotEmpty && validNumber ? _save : null,
            child: Text(l.save),
          ),
        ],
      ),
    );
  }
}
