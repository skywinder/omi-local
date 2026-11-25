import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:uuid/uuid.dart';

import 'paired_library.dart';
import 'recording_chat.dart';
import 'settings_labels.dart';

class RecordingChatPage extends StatefulWidget {
  const RecordingChatPage({super.key, required String this.id, required this.library}) : onOpenSource = null;
  const RecordingChatPage.archive({super.key, required this.library, required this.onOpenSource}) : id = null;
  final String? id;
  final PairedLibrary library;
  final void Function(String, TranscriptMatchSnippet)? onOpenSource;

  @override
  State<RecordingChatPage> createState() => _RecordingChatPageState();
}

class _RecordingChatPageState extends State<RecordingChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <RecordingChatTurn>[];
  RecordingChatProvider? _provider;
  String? _approvedBinding;
  ({String id, String question})? _attempt;
  Object? _error;
  int? _nextBefore;
  bool _busy = true;
  bool _unsupported = false;
  bool _hasTranscript = false;
  bool get _archive => widget.id == null;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool earlier = false}) async {
    final cursor = earlier ? _nextBefore : null;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.library.readRecordingChat(widget.id, before: cursor);
      if (!mounted) return;
      setState(() {
        _unsupported = page == null;
        if (page == null) return;
        _nextBefore = page.nextBefore;
        if (!earlier) {
          _provider = page.provider;
          _hasTranscript = page.hasTranscript;
          if (!_archive) _turns.clear();
        }
        if (!_archive) _turns.addAll(page.turns);
        if (_attempt != null && _turns.any((turn) => turn.id == _attempt!.id)) {
          _input.clear();
          _attempt = null;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _approve(RecordingChatProvider provider) async {
    if (_approvedBinding == provider.binding) return true;
    final l = context.l10n;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_archive ? pairedSettingsLabel(context, 'archiveChatTitle') : l.askOmi),
        content: Text(
          '${pairedSettingsLabel(context, _archive ? 'archiveChatConsent' : 'recordingChatConsent')}'
          '\n\n${provider.model}\n${provider.host}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.send)),
        ],
      ),
    );
    if (accepted != true || !mounted) return false;
    _approvedBinding = provider.binding;
    return true;
  }

  Future<void> _send() async {
    final provider = _provider;
    final question = _input.text.trim();
    if (_busy || provider == null || question.isEmpty || !_hasTranscript || question.runes.length > 1400) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    try {
      if (!await _approve(provider)) return;
      final attempt = _attempt?.question == question ? _attempt! : (id: const Uuid().v4(), question: question);
      _attempt = attempt;
      final turn = await widget.library.askRecordingChat(
        id: widget.id,
        turnId: attempt.id,
        previous: _turns.firstOrNull?.id,
        binding: provider.binding,
        question: question,
        history: _archive ? _turns : const [],
      );
      if (!mounted) return;
      setState(() {
        _turns.removeWhere((value) => value.id == turn.id);
        _turns.insert(0, turn);
        _attempt = null;
        _input.clear();
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final provider = _provider;
    final notice = switch (_error) {
      LibraryFailure.key => l.invalidKey,
      RecordingChatFailure.changed => pairedSettingsLabel(context, 'recordingChatChanged'),
      RecordingChatFailure.noMatches => pairedSettingsLabel(context, 'archiveChatNoMatches'),
      RecordingChatFailure.scanLimited => pairedSettingsLabel(context, 'archiveChatScanLimited'),
      _ when _error != null => l.couldNotLoadPage,
      _ when _busy => null,
      _ when _unsupported => pairedSettingsLabel(
        context,
        _archive ? 'archiveChatUnsupported' : 'recordingChatUnsupported',
      ),
      _ when !_hasTranscript => l.noTranscriptAvailable,
      _ when provider == null => pairedSettingsLabel(context, 'recordingChatNoProvider'),
      _ => null,
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(_archive ? pairedSettingsLabel(context, 'archiveChatTitle') : l.askOmi),
        actions: [IconButton(icon: const Icon(Icons.refresh), tooltip: l.refresh, onPressed: _busy ? null : _load)],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (provider != null) Text('${provider.model} · ${provider.host}', textAlign: TextAlign.center),
            if (_busy) const LinearProgressIndicator(),
            if (notice != null) Padding(padding: const EdgeInsets.all(OmiSpacing.md), child: Text(notice)),
            Expanded(
              child: ListView.builder(
                reverse: true,
                controller: _scroll,
                padding: const EdgeInsets.all(OmiSpacing.md),
                itemCount: _turns.length + (_nextBefore == null ? 0 : 1),
                itemBuilder: (context, index) {
                  if (index == _turns.length) {
                    return TextButton(onPressed: _busy ? null : () => _load(earlier: true), child: Text(l.showMore));
                  }
                  return _turnCard(context, _turns[index]);
                },
              ),
            ),
            if (provider != null && _hasTranscript)
              Padding(
                padding: const EdgeInsets.all(OmiSpacing.md),
                child: TextField(
                  controller: _input,
                  enabled: !_busy,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 1400,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    labelText: l.askAnything,
                    suffixIcon: IconButton(
                      tooltip: l.send,
                      icon: const Icon(Icons.send),
                      onPressed: _busy ? null : _send,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _turnCard(BuildContext context, RecordingChatTurn turn) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(title: Text(turn.question, style: Theme.of(context).textTheme.titleMedium)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.md, vertical: OmiSpacing.sm),
        child: SelectableText(turn.answer),
      ),
      if (turn.contextLimited) ListTile(title: Text(pairedSettingsLabel(context, 'recordingChatPartialContext'))),
      if (turn.scanLimited) ListTile(title: Text(pairedSettingsLabel(context, 'archiveChatScanLimited'))),
      for (final reference in turn.references)
        ListTile(
          leading: const Icon(Icons.notes),
          title: Text(reference.summary ?? context.l10n.viewTranscript, maxLines: 3, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (_archive && reference.title?.isNotEmpty == true) reference.title!,
              if (reference.startMs != null) OmiDuration.offset(reference.startMs! / 1000),
            ].join(' · '),
          ),
          onTap: reference.segmentId == null && reference.startMs == null
              ? null
              : () {
                  final match = TranscriptMatchSnippet(
                    text: reference.summary ?? '',
                    segmentId: reference.segmentId,
                    start: reference.startMs == null ? null : reference.startMs! / 1000,
                    startMs: reference.startMs,
                  );
                  if (_archive) {
                    widget.onOpenSource?.call(reference.conversationId!, match);
                  } else {
                    Navigator.of(context).pop(match);
                  }
                },
        ),
      const Divider(),
    ],
  );
}
