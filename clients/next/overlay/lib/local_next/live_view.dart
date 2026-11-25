import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/transcript.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_preview.dart';
import 'live_tuning.dart';
import 'paired_library.dart';
import 'settings_labels.dart';

class LocalNextLiveButton extends StatefulWidget {
  const LocalNextLiveButton({
    super.key,
    required this.preview,
    required this.capture,
    required this.isRecording,
    this.isMuted,
    required this.onStop,
    this.inputNotice,
    this.captureControls,
    this.captureSettings,
    required this.serverLabel,
    this.library,
  });

  final NextLivePreview preview;
  final Listenable capture;
  final bool Function() isRecording;
  final bool Function()? isMuted;
  final Future<void> Function() onStop;
  final String? Function(BuildContext)? inputNotice;
  final WidgetBuilder? captureControls;
  final WidgetBuilder? captureSettings;
  final String serverLabel;
  final PairedLibrary? library;

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

  Future<void> _open() async {
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
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.capture, widget.preview]),
    builder: (context, _) {
      final l = context.l10n;
      if (!widget.isRecording()) {
        return TextButton.icon(
          icon: const Icon(Icons.subtitles_outlined),
          label: Text(l.liveTranscript),
          onPressed: _open,
        );
      }
      final preview = widget.preview;
      final muted = widget.isMuted?.call() == true;
      final status = _liveStatus(context, preview, recording: true, muted: muted);
      final line = !muted && preview.phase == NextPreviewPhase.listening && preview.lines.isNotEmpty
          ? preview.lines.last.text.replaceAll(RegExp(r'\s+'), ' ').trim()
          : '';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.md),
        child: Card(
          margin: EdgeInsets.zero,
          color: OmiColors.surface1,
          elevation: 0,
          shape: const RoundedRectangleBorder(borderRadius: OmiRadius.mdAll),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            key: const ValueKey('next-live-strip'),
            leading: const Icon(Icons.subtitles_outlined),
            title: Text('${l.liveTranscript} · $status', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: line.isEmpty ? null : Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: _open,
          ),
        ),
      );
    },
  );
}

String _liveStatus(BuildContext context, NextLivePreview preview, {required bool recording, required bool muted}) {
  final l = context.l10n;
  if (recording && muted) return l.muted;
  return switch (preview.phase) {
    NextPreviewPhase.idle => recording ? l.waitingForData : l.off,
    NextPreviewPhase.connecting => preview.lines.isEmpty ? l.livePreviewStarting : l.reconnecting,
    NextPreviewPhase.listening => preview.lines.isEmpty ? l.saySomething : l.deviceOnboardingListening,
    NextPreviewPhase.unavailable when preview.reason == 'disabled' => l.off,
    NextPreviewPhase.unavailable => recording ? l.transcriptionUnavailableRecordingContinues : l.statusFailed,
  };
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

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    try {
      await widget.view.onStop();
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  Future<void> _openSettings(BuildContext context, LocalNextLiveButton view) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => Scaffold(
        appBar: AppBar(title: Text(context.l10n.settings)),
        body: SafeArea(
          child: Column(
            children: [
              if (view.library case final library?)
                ListTile(
                  leading: const Icon(Icons.groups_outlined),
                  title: Text(pairedSettingsLabel(context, 'liveSpeakerLimit')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => NextLiveTuningSheet(library: library),
                  ),
                ),
              if (view.captureSettings case final settings?) settings(context),
              Expanded(
                child: ListenableBuilder(
                  listenable: view.preview,
                  builder: (context, _) => _TranslationSettings(preview: view.preview, change: widget.change),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final preview = view.preview;
    final l = context.l10n;
    return ListenableBuilder(
      listenable: Listenable.merge([view.capture, preview]),
      builder: (context, _) {
        final recording = view.isRecording();
        final status = _liveStatus(context, preview, recording: recording, muted: view.isMuted?.call() == true);
        return Scaffold(
          appBar: AppBar(
            title: Text(l.liveTranscript),
            actions: [
              IconButton(
                icon: const Icon(Icons.tune),
                tooltip: l.settings,
                onPressed: () => _openSettings(context, view),
              ),
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
                  subtitle: Text(view.inputNotice?.call(context) ?? status),
                ),
                if (preview.speakerStatus case final reporting?)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.md),
                    child: Text(switch (reporting.state) {
                      'applied' => '${pairedSettingsLabel(context, 'liveSpeakerApplied')} ${reporting.speakers}',
                      'failed' => pairedSettingsLabel(context, 'liveSpeakerApplyFailed'),
                      _ => pairedSettingsLabel(context, 'liveSpeakerUnsupported'),
                    }),
                  ),
                if (preview.translationStatus == 'unconfigured' || preview.translationStatus == 'failed')
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.md),
                    child: Text(
                      pairedSettingsLabel(
                        context,
                        preview.translationStatus == 'unconfigured'
                            ? 'liveTranslationUnconfigured'
                            : 'liveTranslationFailed',
                      ),
                    ),
                  ),
                Expanded(child: _Transcript(lines: preview.lines)),
                if (view.captureControls case final controls? when recording) controls(context),
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
                Text(pairedSettingsLabel(context, 'liveTranslationTargetLanguage'), style: OmiType.headline),
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
                  Text(pairedSettingsLabel(context, 'liveTranslationBidirectional'), style: OmiType.headline),
                  Text(pairedSettingsLabel(context, 'liveTranslationPairHelp')),
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
