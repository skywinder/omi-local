import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:uuid/uuid.dart';

import 'local_memory.dart';
import 'paired_library.dart';
import 'recording_page.dart';
import 'settings_labels.dart';

class LocalMemoriesPage extends StatefulWidget {
  const LocalMemoriesPage({super.key, required this.library, this.sourceId});
  final PairedLibrary library;
  final String? sourceId;

  @override
  State<LocalMemoriesPage> createState() => _MemoriesState();
}

class _MemoriesState extends State<LocalMemoriesPage> {
  List<LocalMemory> _rows = [];
  String _state = 'accepted';
  String _query = '';
  String? _next;
  bool _busy = false;
  bool _limited = false;
  Object? _error;
  String? _notice;
  final _attempts = <String, String>{};
  ({String binding, String requestId})? _extraction;

  String label(String key) => pairedSettingsLabel(context, key);

  @override
  void initState() {
    super.initState();
    if (widget.sourceId != null) _state = 'proposed';
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

  Future<void> _read({bool more = false}) async {
    final page = await widget.library.listMemories(
      state: _state,
      sourceId: widget.sourceId,
      query: _query,
      after: more ? _next : null,
    );
    if (!mounted) return;
    setState(() {
      final rows = {
        if (more)
          for (final row in _rows) row.id: row,
      };
      for (final row in page.items) {
        rows[row.id] = row;
      }
      _rows = rows.values.toList();
      _next = page.next;
    });
  }

  Future<void> _load({bool more = false}) => _run(() => _read(more: more));

  Future<void> _extract() async {
    LocalMemoryProvider? provider;
    await _run(() async {
      provider = await widget.library.memoryProvider(widget.sourceId!);
    });
    if (!mounted || provider == null) {
      if (mounted && _error == null) setState(() => _notice = label('summaryRegenerateNoModel'));
      return;
    }
    final chosen = provider!;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label('memoryExtract')),
        content: Text('${label('memoryConsent')}\n\n${chosen.model}\n${chosen.host}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(label('memoryExtract'))),
        ],
      ),
    );
    if (!mounted || agreed != true) return;
    await _run(() async {
      if (_extraction?.binding != chosen.binding) {
        _extraction = (binding: chosen.binding, requestId: const Uuid().v4());
      }
      final result = await widget.library.extractMemories(widget.sourceId!, chosen.binding, _extraction!.requestId);
      _extraction = null;
      if (!mounted) return;
      setState(() {
        _state = 'proposed';
        _query = '';
        _limited = result['context_limited'] == true;
        _notice = '${label('memoryCreated')}: ${result['created']}';
      });
      await _read();
    });
  }

  Future<void> _review(LocalMemory fact, String action, {String? content}) => _run(() async {
    final key = '${fact.id}:${fact.revision}:$action:$content';
    final id = _attempts.putIfAbsent(key, () => const Uuid().v4());
    try {
      await widget.library.reviewMemory(fact, action, id, content: content);
    } on LocalMemoryFailure catch (error) {
      if (error == LocalMemoryFailure.changed) {
        _attempts.remove(key);
        await _read();
      }
      rethrow;
    }
    _attempts.remove(key);
    await _read();
  });

  Future<void> _edit(LocalMemory fact) async {
    var draft = fact.content;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(label('memoryEdit')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (fact.quote != null) Text(fact.quote!),
                TextFormField(
                  initialValue: draft,
                  maxLength: 600,
                  minLines: 2,
                  maxLines: 6,
                  onChanged: (value) => update(() => draft = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.cancel)),
            FilledButton(
              onPressed: draft.trim().isEmpty ? null : () => Navigator.pop(context, draft.trim()),
              child: Text(label('memoryConfirm')),
            ),
          ],
        ),
      ),
    );
    if (value != null && mounted) await _review(fact, fact.state == 'accepted' ? 'edit' : 'accept', content: value);
  }

  Future<void> _delete(LocalMemory fact) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label('memoryDelete')),
        content: Text(label('memoryDeleteMessage')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.delete)),
        ],
      ),
    );
    if (mounted && agreed == true) await _review(fact, 'delete');
  }

  void _source(LocalMemory fact) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordingPage(
          library: widget.library,
          id: fact.conversationId,
          initialMatch: fact.quote == null
              ? null
              : TranscriptMatchSnippet(text: fact.quote!, segmentId: fact.segmentId, startMs: fact.startMs),
          verifyInitialExcerpt: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(label('memoryTitle')),
        actions: [IconButton(tooltip: l.refresh, onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(OmiSpacing.md),
        children: [
          if (_busy) const LinearProgressIndicator(),
          Text(label('memoryExplanation')),
          if (_error != null)
            Text(
              _error == LocalMemoryFailure.changed
                  ? label('memoryChanged')
                  : _error == LocalMemoryFailure.invalid
                  ? label('memoryNoSources')
                  : l.couldNotLoadPage,
            ),
          if (_notice != null) Text(_notice!),
          if (_limited) Text(label('memoryLimited')),
          if (widget.sourceId != null)
            FilledButton(onPressed: _busy ? null : _extract, child: Text(label('memoryExtract'))),
          DropdownButton<String>(
            value: _state,
            isExpanded: true,
            items: [
              for (final state in ['proposed', 'accepted', 'rejected'])
                DropdownMenuItem(value: state, child: Text(label('memoryState_$state'))),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    setState(() {
                      _state = value!;
                      _query = '';
                    });
                    unawaited(_load());
                  },
          ),
          if (_state == 'accepted')
            TextFormField(
              key: ValueKey(_query),
              initialValue: _query,
              maxLength: 160,
              decoration: InputDecoration(labelText: label('memorySearch')),
              onFieldSubmitted: _busy
                  ? null
                  : (value) {
                      setState(() => _query = value.trim());
                      unawaited(_load());
                    },
            ),
          if (!_busy && _rows.isEmpty) Text(label('memoryEmpty')),
          for (final fact in _rows)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(OmiSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label(fact.sourceStatus == 'current' ? 'memoryState_${fact.state}' : 'memorySourceChanged')),
                    SelectableText(fact.content),
                    if (fact.quote != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: OmiSpacing.sm),
                        child: SelectableText('“${fact.quote}”'),
                      ),
                    if (fact.revisions.isNotEmpty)
                      ExpansionTile(
                        title: Text(label('memoryHistory')),
                        children: [
                          for (final revision in fact.revisions.reversed)
                            ListTile(
                              title: Text(revision['content'] as String),
                              subtitle: Text(revision['changed_at'] as String),
                            ),
                        ],
                      ),
                    TextButton(onPressed: () => _source(fact), child: Text(label('memorySource'))),
                    Wrap(
                      spacing: OmiSpacing.sm,
                      children: [
                        if (fact.sourceStatus == 'current') ...[
                          if (fact.state != 'accepted')
                            FilledButton(
                              onPressed: _busy ? null : () => _review(fact, 'accept'),
                              child: Text(label('memoryConfirm')),
                            ),
                          TextButton(onPressed: _busy ? null : () => _edit(fact), child: Text(label('memoryEdit'))),
                        ],
                        if (fact.state == 'proposed')
                          TextButton(
                            onPressed: _busy ? null : () => _review(fact, 'reject'),
                            child: Text(label('memoryReject')),
                          ),
                        TextButton(onPressed: _busy ? null : () => _delete(fact), child: Text(l.delete)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (_next != null) TextButton(onPressed: _busy ? null : () => _load(more: true), child: Text(l.showMore)),
        ],
      ),
    );
  }
}
