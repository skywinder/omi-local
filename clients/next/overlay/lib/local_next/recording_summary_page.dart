import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:uuid/uuid.dart';

import 'paired_library.dart';
import 'recording_summary.dart';
import 'settings_labels.dart';

class RecordingSummaryPage extends StatefulWidget {
  const RecordingSummaryPage({super.key, required this.id, required this.library});

  final String id;
  final PairedLibrary library;

  @override
  State<RecordingSummaryPage> createState() => _RecordingSummaryPageState();
}

class _RecordingSummaryPageState extends State<RecordingSummaryPage> {
  final _prompt = TextEditingController();
  RecordingSummaryOptions? _options;
  SummaryProvider? _provider;
  SummaryTemplate? _template;
  SummaryRegeneration? _attempt;
  SummaryJob? _job;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    setState(() => _options = null);
    final options = await widget.library.readSummaryOptions(widget.id);
    if (!mounted) return;
    setState(() {
      _options = options;
      _provider = options.providers.where((row) => row.endpoint.binding == options.defaultBinding).firstOrNull;
      _select(options.templates.where((row) => row.id == options.defaultTemplate).firstOrNull);
    });
    if (options.job case final job?) {
      if (job.state == 'queued') await _waitForSummary(job);
      if (job.state == 'failed' && mounted) setState(() => _job = job);
    }
  });

  void _select(SummaryTemplate? template) {
    _template = template;
    _prompt.text = template?.prompt ?? '';
  }

  Future<void> _regenerate(RecordingSummaryOptions options, SummaryProvider provider, SummaryTemplate template) async {
    final prompt = _prompt.text.trim();
    final endpoint = provider.endpoint;
    final l = context.l10n;
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.regenerateRecap),
        content: Text(
          '${pairedSettingsLabel(context, 'summaryRegenerateConsent')}\n\n${endpoint.model}\n${endpoint.host}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.regenerateRecap)),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    await _run(() async {
      final previous = _attempt;
      if (previous == null ||
          previous.sourceRevision != options.sourceRevision ||
          previous.binding != endpoint.binding ||
          previous.templateId != template.id ||
          previous.templateDigest != template.digest ||
          previous.prompt != prompt) {
        _attempt = (
          requestId: const Uuid().v4(),
          sourceRevision: options.sourceRevision,
          binding: endpoint.binding,
          templateId: template.id,
          templateDigest: template.digest,
          prompt: prompt,
        );
      }
      if (widget.library.summaryJobsAvailable) {
        await _waitForSummary(await widget.library.enqueueSummary(widget.id, _attempt!));
      } else {
        await widget.library.regenerateSummary(widget.id, _attempt!);
        if (mounted) Navigator.pop(context, true);
      }
    });
  }

  Future<void> _waitForSummary(SummaryJob job) async {
    final requestId = job.requestId;
    while (mounted) {
      if (job.requestId != requestId) throw RecordingSummaryFailure.unavailable;
      if (job.state == 'ready') {
        if (mounted) Navigator.pop(context, true);
        return;
      }
      setState(() => _job = job);
      if (job.state == 'failed') {
        // A retry is a new admission, while an interrupted submission reuses its ID.
        _attempt = null;
        return;
      }
      if (job.state != 'queued') throw RecordingSummaryFailure.unavailable;
      await Future<void>.delayed(const Duration(seconds: 4));
      if (mounted) job = await widget.library.readSummaryJob(widget.id, requestId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final options = _options;
    final provider = _provider;
    final template = _template;
    final blocked = _busy || _error == RecordingSummaryFailure.conflict;
    final progress = _job?.progress;
    final sectionCount = switch (progress) {
      (phase: 'sections', completed: final completed?, total: final total?)
          when total > 0 && completed >= 0 && completed <= total =>
        (completed: completed, total: total),
      _ => null,
    };
    final phaseLabel = switch (progress?.phase) {
      'waiting' => 'summaryPhaseWaiting',
      'reading' => 'summaryPhaseReading',
      'sections' => 'summaryPhaseSections',
      'combining' => 'summaryPhaseCombining',
      'saving' => 'summaryPhaseSaving',
      _ => null,
    };
    final error = switch (_error) {
      LibraryFailure.key => l.invalidKey,
      RecordingSummaryFailure.conflict => pairedSettingsLabel(context, 'summaryRegenerateChanged'),
      RecordingSummaryFailure.tooLarge => pairedSettingsLabel(context, 'summaryRegenerateTooLong'),
      RecordingSummaryFailure.noTranscript => l.noTranscriptAvailable,
      null => null,
      _ => pairedSettingsLabel(context, 'summaryRegenerateFailed'),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(l.regenerateRecap),
        actions: [IconButton(tooltip: l.refresh, onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(OmiSpacing.md),
        children: [
          if (_busy)
            LinearProgressIndicator(value: sectionCount == null ? null : sectionCount.completed / sectionCount.total),
          if (_job?.state == 'queued' && error == null) Text(pairedSettingsLabel(context, 'summaryRegenerateQueued')),
          if (_job?.state == 'queued' && error == null && phaseLabel != null)
            Semantics(
              liveRegion: true,
              child: Text(
                sectionCount != null
                    ? '${pairedSettingsLabel(context, phaseLabel)} · ${sectionCount.completed}/${sectionCount.total}'
                    : pairedSettingsLabel(context, phaseLabel),
              ),
            ),
          if (_job?.state == 'failed' && error == null)
            Text(
              pairedSettingsLabel(context, switch (_job?.error) {
                'recording_changed' => 'summaryRegenerateChanged',
                'recording_too_large' => 'summaryRegenerateTooLong',
                'connection' || 'timeout' => 'summaryFailureConnection',
                'http_401' || 'http_403' || 'credential_missing' => 'summaryFailureCredential',
                'http_429' || 'http_503' => 'summaryFailureBusy',
                'http_404' || 'configuration' => 'summaryFailureModel',
                'invalid_json' ||
                'invalid_summary' ||
                'invalid_provider_response' ||
                'output_limit' => 'summaryFailureFormat',
                _ => 'summaryRegenerateFailed',
              }),
            ),
          if (error != null) Text(error),
          if (options != null) ...[
            if (options.providers.isEmpty) Text(pairedSettingsLabel(context, 'summaryRegenerateNoModel')),
            if (options.providers.isNotEmpty)
              DropdownButton<SummaryProvider>(
                value: provider,
                isExpanded: true,
                hint: Text(pairedSettingsLabel(context, 'summaryRegenerateModel')),
                items: [
                  for (final choice in options.providers)
                    DropdownMenuItem(
                      value: choice,
                      child: Text('${choice.name} · ${choice.endpoint.model}', overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: blocked ? null : (value) => setState(() => _provider = value),
              ),
            DropdownButton<SummaryTemplate>(
              value: template,
              isExpanded: true,
              hint: Text(l.summaryTemplate),
              items: [
                for (final choice in options.templates)
                  DropdownMenuItem(
                    value: choice,
                    child: Text(choice.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: blocked ? null : (value) => setState(() => _select(value)),
            ),
            TextField(
              controller: _prompt,
              enabled: !blocked && template != null,
              minLines: 4,
              maxLines: 8,
              maxLength: 8000,
              decoration: InputDecoration(labelText: l.prompt),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton(
              onPressed: blocked || provider == null || template == null || _prompt.text.trim().isEmpty
                  ? null
                  : () => _regenerate(options, provider, template),
              child: Text(l.regenerateRecap),
            ),
          ],
        ],
      ),
    );
  }
}
