import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:uuid/uuid.dart';

import 'processing.dart';
import 'settings_labels.dart';

typedef _Template = ({String id, String name, String prompt});

class _Catalog {
  const _Catalog(this.revision, this.defaultId, this.templates);

  factory _Catalog.fromJson(Map<String, dynamic> wire) {
    final revision = wire['revision'] as int;
    final defaultId = wire['default_template_id'] as String;
    final entries = (wire['templates'] as List).cast<Map<String, dynamic>>();
    final templates = entries
        .map((row) => (id: row['id'] as String, name: row['name'] as String, prompt: row['prompt'] as String))
        .toList();
    final ids = templates.map((template) => template.id).toSet();
    if (revision < 0 || ids.length != templates.length || !ids.contains(defaultId) || templates.length > 24) {
      throw const FormatException('Invalid summary template catalog');
    }
    return _Catalog(revision, defaultId, templates);
  }

  final int revision;
  final String defaultId;
  final List<_Template> templates;
}

class SummaryTemplatesPage extends StatefulWidget {
  const SummaryTemplatesPage({super.key, required this.request});

  final Future<Map<String, dynamic>> Function(Map<String, dynamic>?) request;

  @override
  State<SummaryTemplatesPage> createState() => _SummaryTemplatesPageState();
}

class _SummaryTemplatesPageState extends State<SummaryTemplatesPage> {
  final _name = TextEditingController();
  final _prompt = TextEditingController();
  _Catalog? _catalog;
  String? _selected;
  bool _makeDefault = false;
  bool _busy = false;
  NextProcessingFailure? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _select(_Template? template) {
    _selected = template?.id;
    _name.text = template?.name ?? '';
    _prompt.text = template?.prompt ?? '';
    _makeDefault = _selected == _catalog?.defaultId;
  }

  Future<void> _load() => _update();

  Future<void> _save(_Catalog catalog) async {
    final entry = (id: _selected ?? const Uuid().v4(), name: _name.text.trim(), prompt: _prompt.text.trim());
    final templates = [
      for (final row in catalog.templates) row.id == entry.id ? entry : row,
      if (_selected == null) entry,
    ];
    final defaultId = _makeDefault ? entry.id : catalog.defaultId;
    await _update(
      entry: entry,
      body: {
        'revision': catalog.revision,
        'default_template_id': defaultId,
        'templates': [
          for (final row in templates) {'id': row.id, 'name': row.name, 'prompt': row.prompt},
        ],
      },
    );
  }

  Future<void> _update({Map<String, dynamic>? body, _Template? entry}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final catalog = _Catalog.fromJson(await widget.request(body));
      final selection = catalog.templates.firstWhere((row) => row.id == (entry?.id ?? catalog.defaultId));
      if (entry != null &&
          (selection != entry ||
              catalog.defaultId != body!['default_template_id'] ||
              catalog.revision <= _catalog!.revision)) {
        throw NextProcessingFailure.indeterminate;
      }
      if (!mounted) return;
      _catalog = catalog;
      _select(selection);
      if (entry != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.saved)));
      }
    } catch (error) {
      if (mounted) {
        _failure = error is NextProcessingFailure
            ? error
            : (body == null ? NextProcessingFailure.unavailable : NextProcessingFailure.indeterminate);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final catalog = _catalog;
    final editable = !_busy && (_failure == null || _failure == NextProcessingFailure.invalid);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.summaryTemplate),
        actions: [IconButton(tooltip: l.refresh, onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(OmiSpacing.md),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_failure case final failure?) Text(processingFailureLabel(context, failure)),
          if (catalog != null) ...[
            for (final row in catalog.templates)
              ListTile(
                title: Text(row.name),
                selected: row.id == _selected,
                trailing: row.id == catalog.defaultId ? Text(l.defaultLabel) : null,
                onTap: editable ? () => setState(() => _select(row)) : null,
              ),
            TextButton.icon(
              onPressed: editable && catalog.templates.length < 24 ? () => setState(() => _select(null)) : null,
              icon: const Icon(Icons.add),
              label: Text(l.add),
            ),
            TextField(
              controller: _name,
              enabled: editable,
              maxLength: 100,
              decoration: InputDecoration(labelText: l.templateName),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _prompt,
              enabled: editable,
              minLines: 4,
              maxLines: 8,
              maxLength: 8000,
              decoration: InputDecoration(labelText: l.prompt),
              onChanged: (_) => setState(() {}),
            ),
            SwitchListTile(
              title: Text(pairedSettingsLabel(context, 'summaryUseForNew')),
              value: _makeDefault,
              onChanged: editable && _selected != catalog.defaultId
                  ? (value) => setState(() => _makeDefault = value)
                  : null,
            ),
            FilledButton(
              onPressed: editable && _name.text.trim().isNotEmpty && _prompt.text.trim().isNotEmpty
                  ? () => _save(catalog)
                  : null,
              child: Text(l.saveChanges),
            ),
          ],
        ],
      ),
    );
  }
}
