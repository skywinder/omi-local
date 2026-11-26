import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:uuid/uuid.dart';

import 'daily_recap.dart';
import 'daily_recap_schedule_page.dart';
import 'paired_library.dart';
import 'recording_page.dart';
import 'settings_labels.dart';

class DailyRecapsPage extends StatefulWidget {
  const DailyRecapsPage({super.key, required this.library});

  final PairedLibrary library;

  @override
  State<DailyRecapsPage> createState() => _DailyRecapsState();
}

class _DailyRecapsState extends State<DailyRecapsPage> {
  List<LocalDailyRecap> _rows = [];
  bool _busy = false;
  bool _more = false;
  int _offset = 0;
  Object? _error;
  DateTime _date = DateTime.now();
  ({String id, DateTime date, DailyRecapPreview preview})? _attempt;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load({bool more = false}) => _run(() => _read(more ? _offset : 0));

  Future<void> _read(int offset) async {
    final rows = await widget.library.listDailyRecaps(offset);
    if (!mounted) return;
    setState(() {
      final previous = {
        if (offset != 0)
          for (final row in _rows) row.summary.id: row,
      };
      for (final row in rows) {
        previous[row.summary.id] = row;
      }
      _rows = previous.values.toList();
      _offset = offset + rows.length;
      _more = rows.length == 20;
    });
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: today,
    );
    if (!mounted || selected == null) return;
    setState(() => _date = selected);
  }

  Future<void> _generate() async {
    final date = _date;
    final attempt = _attempt?.date == date ? _attempt : null;
    DailyRecapPreview? preview = attempt?.preview;
    if (preview == null) {
      await _run(() async {
        preview = await widget.library.previewDailyRecap(date);
      });
    }
    if (!mounted || preview == null) return;
    final plan = preview!;
    final provider = plan.provider;
    final l = context.l10n;
    final label = MaterialLocalizations.of(context).formatFullDate(date);
    final message = plan.sourceCount == 0
        ? pairedSettingsLabel(context, 'dailyRecapEmpty')
        : provider == null
        ? pairedSettingsLabel(context, 'summaryRegenerateNoModel')
        : '${pairedSettingsLabel(context, 'dailyRecapConsent')}\n\n'
              '$label · ${plan.sourceCount}/${plan.count}\n${provider.model}\n${provider.host}'
              '${plan.limited ? '\n\n${pairedSettingsLabel(context, 'dailyRecapLimited')}' : ''}';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.dailySummary),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          if (provider != null && plan.sourceCount > 0)
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.create)),
        ],
      ),
    );
    if (accepted != true || provider == null || !mounted) return;
    LocalDailyRecap? saved;
    await _run(() async {
      final id = attempt?.id ?? const Uuid().v4();
      _attempt = (id: id, date: date, preview: plan);
      try {
        saved = await widget.library.generateDailyRecap(date, plan, id);
      } on DailyRecapFailure catch (failure) {
        if (failure == DailyRecapFailure.changed) _attempt = null;
        rethrow;
      }
      _attempt = null;
      await _read(0);
    });
    if (mounted && saved != null) _open(saved!);
  }

  void _open(LocalDailyRecap recap) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RecapDetail(library: widget.library, recap: recap),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final calendar = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.dailyRecaps),
        actions: [
          if (widget.library.dailyRecapScheduleAvailable)
            IconButton(
              tooltip: pairedSettingsLabel(context, 'recapScheduleTitle'),
              icon: const Icon(Icons.schedule),
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => DailyRecapSchedulePage(library: widget.library))),
            ),
          IconButton(tooltip: l.refresh, onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(OmiSpacing.md),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error == DailyRecapFailure.changed
                  ? pairedSettingsLabel(context, 'dailyRecapChanged')
                  : l.couldNotLoadPage,
            ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickDate,
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text(calendar.formatFullDate(_date)),
          ),
          FilledButton(
            onPressed: _busy ? null : _generate,
            child: Text(pairedSettingsLabel(context, 'dailyRecapCreate')),
          ),
          for (final row in _rows)
            ListTile(
              title: Text(row.summary.headline),
              subtitle: Text(calendar.formatFullDate(DateTime.parse(row.summary.date))),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(row),
            ),
          if (_more) TextButton(onPressed: _busy ? null : () => _load(more: true), child: Text(l.showMore)),
        ],
      ),
    );
  }
}

class _RecapDetail extends StatelessWidget {
  const _RecapDetail({required this.library, required this.recap});

  final PairedLibrary library;
  final LocalDailyRecap recap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final summary = recap.summary;
    final sources = <String>{...recap.sourceIds};
    Widget citation(String id) {
      sources.add(id);
      return TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RecordingPage(library: library, id: id),
          ),
        ),
        child: Text('${pairedSettingsLabel(context, 'localTaskSource')} · ${sources.toList().indexOf(id) + 1}'),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.dailySummary)),
      body: ListView(
        padding: const EdgeInsets.all(OmiSpacing.md),
        children: [
          Text(summary.headline, style: Theme.of(context).textTheme.headlineSmall),
          Text(MaterialLocalizations.of(context).formatFullDate(DateTime.parse(summary.date))),
          if (summary.stats.totalConversations > 0)
            Text('${l.conversations} · ${summary.stats.totalConversations} · ${summary.stats.formattedDuration}'),
          if (recap.limited) Text(pairedSettingsLabel(context, 'dailyRecapLimited')),
          const SizedBox(height: OmiSpacing.md),
          SelectableText(summary.overview),
          for (final highlight in summary.highlights) ...[
            const SizedBox(height: OmiSpacing.md),
            Text(highlight.topic, style: Theme.of(context).textTheme.titleMedium),
            SelectableText(highlight.summary),
            Wrap(children: highlight.conversationIds.map(citation).toList()),
          ],
          for (final item in summary.decisionsMade) ...[
            SelectableText(item.decision),
            if (item.conversationId case final id?)
              Align(alignment: AlignmentDirectional.centerStart, child: citation(id)),
          ],
          if (recap.sourceIds.isNotEmpty)
            ExpansionTile(
              title: Text(pairedSettingsLabel(context, 'dailyRecapSources')),
              children: recap.sourceIds.map(citation).toList(),
            ),
        ],
      ),
    );
  }
}
