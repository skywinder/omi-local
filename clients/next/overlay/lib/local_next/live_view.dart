import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/transcript.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_labels.g.dart';
import 'live_preview.dart';

String _label(BuildContext context, String key) {
  final locale = Localizations.localeOf(context);
  return pairedTranslationLabels[locale.toLanguageTag()]?[key] ??
      pairedTranslationLabels[locale.languageCode]?[key] ??
      pairedTranslationLabels['en']![key]!;
}

class LocalNextLiveButton extends StatefulWidget {
  const LocalNextLiveButton({
    super.key,
    required this.preview,
    required this.capture,
    required this.isRecording,
    this.isMuted,
    required this.onStop,
    required this.serverLabel,
  });

  final NextLivePreview preview;
  final Listenable capture;
  final bool Function() isRecording;
  final bool Function()? isMuted;
  final Future<void> Function() onStop;
  final String serverLabel;

  @override
  State<LocalNextLiveButton> createState() => _LocalNextLiveButtonState();
}

class _LocalNextLiveButtonState extends State<LocalNextLiveButton> {
  MaterialPageRoute<void>? _route;
  int _changes = 0;
  Future<void> _saving = Future.value();
  String get _key => 'next.live.translation.${widget.preview.owner}';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final preview = widget.preview;
    final key = _key;
    final changes = _changes;
    try {
      final settings = await SharedPreferences.getInstance();
      final values = settings.getStringList(key);
      if (!mounted || preview != widget.preview || changes != _changes || values == null || values.length != 2) return;
      final code = RegExp(r'^[a-z]{2,3}$');
      if (code.hasMatch(values.first) &&
          (values.last.isEmpty || (values.last != values.first && code.hasMatch(values.last)))) {
        preview.setTranslation(values.first, other: values.last);
      }
    } catch (_) {
      // An unreadable preference leaves translation off for this pairing.
    }
  }

  void _change(String target, String other) {
    _changes++;
    widget.preview.setTranslation(target, other: other);
    final key = _key;
    final messenger = ScaffoldMessenger.of(context);
    final label = context.l10n.failedToSaveCheckConnection;
    _saving = _saving
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setStringList(key, [target, other])) throw StateError('Translation settings unavailable');
        })
        .catchError((Object _) {
          if (mounted && messenger.mounted) messenger.showSnackBar(SnackBar(content: Text(label)));
        });
  }

  void _endRoute() {
    final route = _route;
    _route = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
  }

  @override
  void didUpdateWidget(LocalNextLiveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview != widget.preview) {
      _endRoute();
      _restore();
    }
  }

  @override
  void dispose() {
    _endRoute();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.subtitles_outlined),
    label: Text(context.l10n.liveTranscript),
    onPressed: () async {
      if (_route != null) return;
      final view = widget;
      final route = _route = MaterialPageRoute<void>(
        builder: (_) => _LivePage(
          view: view,
          change: (target, other) {
            if (mounted && widget.preview == view.preview) _change(target, other);
          },
        ),
      );
      await Navigator.of(context).push(route);
      if (_route == route) _route = null;
    },
  );
}

class _LivePage extends StatefulWidget {
  const _LivePage({required this.view, required this.change});
  final LocalNextLiveButton view;
  final void Function(String target, String other) change;
  @override
  State<_LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<_LivePage> {
  bool _stopping = false;
  bool _settings = false;

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    try {
      await widget.view.onStop();
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final preview = view.preview;
    final l = context.l10n;
    return ListenableBuilder(
      listenable: Listenable.merge([view.capture, preview]),
      builder: (context, _) {
        final recording = view.isRecording();
        final status = recording && view.isMuted?.call() == true
            ? l.muted
            : switch (preview.phase) {
                NextPreviewPhase.idle => recording ? l.waitingForData : l.off,
                NextPreviewPhase.connecting => l.livePreviewStarting,
                NextPreviewPhase.listening => l.deviceOnboardingListening,
                NextPreviewPhase.unavailable when preview.reason == 'disabled' => l.off,
                NextPreviewPhase.unavailable =>
                  recording ? l.transcriptionUnavailableRecordingContinues : l.statusFailed,
              };
        return Scaffold(
          appBar: AppBar(
            title: Text(l.liveTranscript),
            actions: [
              if (recording)
                TextButton.icon(onPressed: _stopping ? null : _stop, icon: const Icon(Icons.stop), label: Text(l.stop)),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(view.serverLabel),
                  subtitle: Text(status),
                  trailing: IconButton(
                    icon: Icon(_settings ? Icons.close : Icons.translate),
                    tooltip: _settings ? l.close : _label(context, 'liveTranslation'),
                    onPressed: () => setState(() => _settings = !_settings),
                  ),
                ),
                if (preview.translationStatus == 'unconfigured' || preview.translationStatus == 'failed')
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.md),
                    child: Text(
                      _label(
                        context,
                        preview.translationStatus == 'unconfigured'
                            ? 'liveTranslationUnconfigured'
                            : 'liveTranslationFailed',
                      ),
                    ),
                  ),
                Expanded(
                  child: _settings
                      ? _TranslationSettings(preview: preview, change: widget.change)
                      : _Transcript(lines: preview.lines),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({required this.lines});
  final List<NextPreviewLine> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    final ordinals = <String, int>{};
    final committed = <TranscriptSegment>[];
    final drafts = <NextPreviewLine>[];
    var unknownSpeaker = false;
    for (final line in lines) {
      if (line.isDraft) {
        drafts.add(line);
        continue;
      }
      final speaker = line.speaker ?? '';
      unknownSpeaker |= speaker.isEmpty;
      committed.add(
        TranscriptSegment(
          id: line.id,
          text: line.text,
          speaker: speaker,
          speakerId: ordinals.putIfAbsent(speaker, () => ordinals.length),
          isUser: false,
          personId: null,
          start: line.start,
          end: line.end,
          translations: [
            for (final entry in line.translations.entries) Translation(lang: entry.key, text: entry.value),
          ],
        ),
      );
    }
    final draft = drafts.isEmpty
        ? null
        : ListTile(
            key: const ValueKey('next-live-drafts'),
            title: Text(context.l10n.preview),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in drafts) ...[
                  Text(line.text),
                  for (final translation in line.translations.values)
                    Text(translation, style: OmiType.subhead.copyWith(color: OmiColors.textSecondary)),
                ],
              ],
            ),
          );
    if (committed.isEmpty) return SingleChildScrollView(child: draft);
    return TranscriptWidget(
      segments: committed,
      unresolvedSpeakers: unknownSpeaker,
      followLatest: true,
      topMargin: false,
      bottomMargin: 0,
      jumpToLatestButtonBottom: 8,
      showTranslationNotice: false,
      trailingItem: draft,
    );
  }
}

class _TranslationSettings extends StatelessWidget {
  const _TranslationSettings({required this.preview, required this.change});
  final NextLivePreview preview;
  final void Function(String target, String other) change;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final localeCode = Localizations.localeOf(context).languageCode;
    return SafeArea(
      child: ListenableBuilder(
        listenable: preview,
        builder: (context, _) {
          final target = preview.targetLanguage;
          final other = preview.otherLanguage;
          final options = {...SttLanguages.common}..removeWhere((code, _) => !RegExp(r'^[a-z]{2,3}$').hasMatch(code));
          if (target.isNotEmpty) options.putIfAbsent(target, () => target.toUpperCase());
          if (other.isNotEmpty) options.putIfAbsent(other, () => other.toUpperCase());
          final codes = options.keys.toList()
            ..sort((a, b) {
              if (a == b) return 0;
              if (a == localeCode) return -1;
              if (b == localeCode) return 1;
              return options[a]!.compareTo(options[b]!);
            });
          return SingleChildScrollView(
            padding: const EdgeInsets.all(OmiSpacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_label(context, 'liveTranslationTargetLanguage'), style: OmiType.headline),
                DropdownButton<String>(
                  key: const ValueKey('next-live-target'),
                  value: target,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(value: '', child: Text(l.off)),
                    for (final code in codes) DropdownMenuItem(value: code, child: Text(options[code]!)),
                  ],
                  onChanged: (code) {
                    if (code != null) change(code, code.isEmpty || code == other ? '' : other);
                  },
                ),
                if (target.isNotEmpty) ...[
                  Text(_label(context, 'liveTranslationBidirectional'), style: OmiType.headline),
                  Text(_label(context, 'liveTranslationPairHelp')),
                  DropdownButton<String>(
                    key: const ValueKey('next-live-other'),
                    value: other,
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(value: '', child: Text(l.off)),
                      for (final code in codes)
                        if (code != target) DropdownMenuItem(value: code, child: Text(options[code]!)),
                    ],
                    onChanged: (code) {
                      if (code != null) change(target, code);
                    },
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
