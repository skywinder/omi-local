import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/transcript.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/providers/locale_provider.dart';

import 'live_preview.dart';
import 'cv1_transport.dart';
import 'device_diagnostics_page.dart';
import 'server_connection_indicator.dart';
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
    this.cv1,
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
  final Cv1Connection? cv1;

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
        return ListTile(
          leading: const Icon(Icons.subtitles_outlined),
          title: Text(l.liveTranscript),
          subtitle: Text(_liveStatus(context, widget.preview, recording: false, muted: false)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _open,
        );
      }
      final preview = widget.preview;
      final muted = widget.isMuted?.call() == true;
      final status = _liveStatus(context, preview, recording: true, muted: muted);
      final atSessionLimit = !muted && preview.reason == 'session_limit';
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
            title: Text(
              atSessionLimit ? l.liveTranscript : '${l.liveTranscript} · $status',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: atSessionLimit
                ? Text(status)
                : (line.isEmpty ? null : Text(line, maxLines: 1, overflow: TextOverflow.ellipsis)),
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
  if (!recording) {
    return pairedSettingsLabel(context, preview.lines.isEmpty ? 'nextIdleTranscript' : 'nextLastTranscript');
  }
  if (muted) return l.muted;
  return switch (preview.phase) {
    NextPreviewPhase.idle => l.waitingForData,
    NextPreviewPhase.connecting => preview.lines.isEmpty ? l.livePreviewStarting : l.reconnecting,
    NextPreviewPhase.listening => preview.lines.isEmpty ? l.saySomething : l.deviceOnboardingListening,
    NextPreviewPhase.unavailable when preview.reason == 'disabled' => pairedSettingsLabel(context, 'nextLiveDisabled'),
    NextPreviewPhase.unavailable when preview.reason == 'session_limit' => pairedSettingsLabel(
      context,
      'liveSessionLimit',
    ),
    NextPreviewPhase.unavailable => l.transcriptionUnavailableRecordingContinues,
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
            title: Cv1HeaderTitle(title: l.liveTranscript, link: view.cv1),
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.md, vertical: OmiSpacing.xs),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: view.library != null
                        ? NextServerIndicator(library: view.library!, name: view.serverLabel)
                        : Text(view.serverLabel),
                  ),
                ),
                ListTile(
                  leading: Icon(
                    Icons.subtitles_outlined,
                    color: recording && preview.phase == NextPreviewPhase.listening
                        ? OmiColors.success
                        : OmiColors.textTertiary,
                  ),
                  title: Text(status),
                  subtitle: switch (view.inputNotice?.call(context)) {
                    final String notice => Text(notice),
                    _ when !recording && preview.lines.isEmpty => Text(
                      pairedSettingsLabel(context, 'nextStartForText'),
                    ),
                    _ => null,
                  },
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
                _LanguageChoice(
                  key: const ValueKey('next-live-target'),
                  value: target,
                  options: options,
                  codes: codes,
                  title: pairedSettingsLabel(context, 'liveTranslationTargetLanguage'),
                  onSelected: (code) => change(code, code.isEmpty || code == other ? '' : other),
                ),
                if (target.isNotEmpty) ...[
                  Text(pairedSettingsLabel(context, 'liveTranslationBidirectional'), style: OmiType.headline),
                  Text(pairedSettingsLabel(context, 'liveTranslationPairHelp')),
                  _LanguageChoice(
                    key: const ValueKey('next-live-other'),
                    value: other,
                    options: options,
                    codes: codes.where((code) => code != target).toList(),
                    title: pairedSettingsLabel(context, 'liveTranslationBidirectional'),
                    onSelected: (code) => change(target, code),
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

class _LanguageChoice extends StatelessWidget {
  const _LanguageChoice({
    super.key,
    required this.value,
    required this.options,
    required this.codes,
    required this.title,
    required this.onSelected,
  });
  final String value;
  final Map<String, String> options;
  final List<String> codes;
  final String title;
  final ValueChanged<String> onSelected;

  String _name(String code) {
    final native = LocaleProvider.getDisplayName(Locale(code));
    return native == code ? options[code]! : native;
  }

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(value.isEmpty ? context.l10n.off : _name(value)),
    trailing: const Icon(Icons.expand_more),
    onTap: () async {
      var query = '';
      final selected = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (context) => StatefulBuilder(
            builder: (context, refresh) {
              final l = context.l10n;
              final matches = codes.where(
                (code) => '$code ${options[code]} ${_name(code)}'.toLowerCase().contains(query),
              );
              final visible = [if (query.isEmpty || l.off.toLowerCase().contains(query)) '', ...matches];
              return Scaffold(
                appBar: AppBar(title: Text(title)),
                body: SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(OmiSpacing.md),
                        child: TextField(
                          autofocus: true,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: l.searchLanguageHint,
                          ),
                          onChanged: (text) => refresh(() => query = text.trim().toLowerCase()),
                        ),
                      ),
                      Expanded(
                        child: visible.isEmpty
                            ? Center(child: Text(l.noResultsFound))
                            : ListView.builder(
                                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                                itemCount: visible.length,
                                itemBuilder: (context, i) {
                                  final code = visible[i];
                                  return ListTile(
                                    title: Text(code.isEmpty ? l.off : _name(code)),
                                    subtitle: code.isEmpty ? null : Text(code),
                                    trailing: value == code ? const Icon(Icons.check) : null,
                                    onTap: () => Navigator.pop(context, code),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      if (context.mounted && selected != null) onSelected(selected);
    },
  );
}
