import 'package:flutter/material.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'processing.dart';
import 'settings_labels.dart';

class LocalNextProcessingPage extends StatefulWidget {
  const LocalNextProcessingPage({
    super.key,
    required this.client,
    required this.serverLabel,
    required this.isRecording,
    this.capture,
  });

  final NextProcessingClient client;
  final String serverLabel;
  final bool Function() isRecording;
  final Listenable? capture;

  @override
  State<LocalNextProcessingPage> createState() => _ProcessingPageState();
}

class _ProcessingPageState extends State<LocalNextProcessingPage> {
  NextProcessingSettings? _settings;
  final _selected = <NextProcessingStage, String>{};
  NextProcessingFailure? _failure;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.capture?.addListener(_captureChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(LocalNextProcessingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.capture != widget.capture) {
      oldWidget.capture?.removeListener(_captureChanged);
      widget.capture?.addListener(_captureChanged);
    }
    if (oldWidget.client != widget.client) {
      _busy = false;
      _settings = null;
      _selected.clear();
      _refresh();
    }
  }

  @override
  void dispose() {
    widget.capture?.removeListener(_captureChanged);
    super.dispose();
  }

  void _captureChanged() => setState(() {});

  Future<void> _refresh() => _request(widget.client.fetch);

  Future<void> _request(Future<NextProcessingSettings> Function() operation) async {
    if (_busy) return;
    final client = widget.client;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final settings = await operation();
      if (!mounted || widget.client != client) return;
      setState(() {
        _settings = settings;
        _selected.clear();
        for (final stage in NextProcessingStage.values) {
          final active = settings.active(stage);
          if (active != null) _selected[stage] = active.id;
        }
      });
    } catch (error) {
      if (!mounted || widget.client != client) return;
      setState(() {
        _failure = error is NextProcessingFailure ? error : NextProcessingFailure.unavailable;
        // A lost write response can follow publication. Read before offering another write.
        _settings = null;
        _selected.clear();
      });
    } finally {
      if (mounted && widget.client == client) setState(() => _busy = false);
    }
  }

  Future<void> _activate(NextProcessingStage stage) async {
    final settings = _settings;
    final id = _selected[stage];
    if (_busy || settings == null || widget.isRecording() || !settings.canActivate(stage, id)) return;
    await _request(() => widget.client.activate(settings, stage, id));
  }

  String _problem(BuildContext context, NextProcessingFailure failure) => switch (failure) {
    NextProcessingFailure.unsupported => pairedSettingsLabel(context, 'localProcessingUnsupported'),
    NextProcessingFailure.unauthorized => context.l10n.invalidKey,
    NextProcessingFailure.conflict => pairedSettingsLabel(context, 'processingConflict'),
    NextProcessingFailure.indeterminate => pairedSettingsLabel(context, 'processingIndeterminate'),
    NextProcessingFailure.invalid => pairedSettingsLabel(context, 'providerMisconfigured'),
    NextProcessingFailure.unavailable => pairedSettingsLabel(context, 'providerUnavailable'),
  };

  String _stageName(BuildContext context, NextProcessingStage stage) {
    final l = context.l10n;
    return switch (stage) {
      NextProcessingStage.live => l.liveTranscript,
      NextProcessingStage.stt => '${l.transcription} · ${pairedSettingsLabel(context, 'localProcessingFinished')}',
      NextProcessingStage.diarization =>
        '${pairedSettingsLabel(context, 'diarization')} · ${pairedSettingsLabel(context, 'localProcessingFinished')}',
      NextProcessingStage.summary => l.summary,
      NextProcessingStage.translation => pairedSettingsLabel(context, 'liveTranslation'),
    };
  }

  Widget _stage(BuildContext context, NextProcessingSettings state, NextProcessingStage stage) {
    final l = context.l10n;
    final effective = state.active(stage);
    final options = state.choices(stage);
    final selected = options.where((p) => p.id == _selected[stage]).firstOrNull;
    final pending =
        effective != null &&
        selected != null &&
        effective.id == selected.id &&
        effective.configurationRevision != null &&
        selected.configurationRevision != null &&
        effective.configurationRevision != selected.configurationRevision;
    final enabled = !_busy && !widget.isRecording() && state.canActivate(stage, _selected[stage]);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_stageName(context, stage), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('${l.active} · ${effective?.name ?? l.off}', key: ValueKey('next-${stage.name}-active')),
            if (effective != null) Text(effective.kind, style: Theme.of(context).textTheme.bodySmall),
            if (effective?.inheritedFrom == NextProcessingStage.summary) Text('${l.defaultLabel} · ${l.summary}'),
            if (stage.canActivate) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: ValueKey('next-${stage.name}-${state.revision}'),
                initialValue: selected?.id ?? (stage.canDisable && _selected[stage] == null ? '' : null),
                isExpanded: true,
                decoration: InputDecoration(labelText: l.provider),
                items: [
                  if (stage.canDisable) DropdownMenuItem(value: '', child: Text(l.off)),
                  for (final option in options)
                    DropdownMenuItem(
                      value: option.id,
                      child: Text(option.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        if (value == null || value.isEmpty) {
                          _selected.remove(stage);
                        } else {
                          _selected[stage] = value;
                        }
                      }),
              ),
              if (pending) Text(pairedSettingsLabel(context, 'localProcessingPending')),
              const SizedBox(height: 8),
              FilledButton(
                key: ValueKey('next-${stage.name}-confirm'),
                onPressed: enabled ? () => _activate(stage) : null,
                child: Text(l.confirm),
              ),
            ] else
              Text(pairedSettingsLabel(context, 'processingServerManaged')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = _settings;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.processing),
        actions: [IconButton(tooltip: l.refresh, onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.serverLabel, style: Theme.of(context).textTheme.titleMedium),
          if (_busy) const LinearProgressIndicator(),
          if (_failure case final failure?) ...[
            Text(_problem(context, failure)),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(onPressed: _busy ? null : _refresh, child: Text(l.refresh)),
            ),
          ],
          if (state != null) ...[
            Text(pairedSettingsLabel(context, 'processingPublished')),
            Text(pairedSettingsLabel(context, 'localProcessingHelp')),
            Text(pairedSettingsLabel(context, 'localProcessingApplyHelp')),
            const SizedBox(height: 8),
            for (final stage in NextProcessingStage.values)
              if (state.supports(stage)) _stage(context, state, stage),
          ],
        ],
      ),
    );
  }
}
