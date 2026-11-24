import 'package:flutter/material.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'processing.dart';
import 'settings_labels.dart';

enum _Action { models, probe, save }

class NextProcessingEditor extends StatefulWidget {
  const NextProcessingEditor({
    super.key,
    required this.client,
    required this.settings,
    required this.stage,
    required this.isCurrentClient,
    required this.serverLabel,
    this.profile,
  });

  final NextProcessingClient client;
  final NextProcessingSettings settings;
  final NextProcessingStage stage;
  final NextProcessingProfile? profile;
  final bool Function() isCurrentClient;
  final String serverLabel;

  @override
  State<NextProcessingEditor> createState() => _NextProcessingEditorState();
}

class _NextProcessingEditorState extends State<NextProcessingEditor> {
  final _form = GlobalKey<FormState>();
  late final _original = widget.profile?.editableDraft;
  late final _name = TextEditingController(text: _original?.name);
  late final _endpoint = TextEditingController(text: _original?.endpoint);
  late final _model = TextEditingController(text: _original?.model);
  late final _language = TextEditingController(text: _original?.language ?? 'auto');
  late final _minimum = TextEditingController(text: _original?.minSpeakers?.toString());
  late final _maximum = TextEditingController(text: _original?.maxSpeakers?.toString());
  final _key = TextEditingController();
  bool _clearKey = false;
  bool _busy = false;
  bool _needsRefresh = false;
  String? _message;
  List<String> _models = [];

  bool get _enabled => !_busy && !_needsRefresh;
  bool get _stt => widget.stage == NextProcessingStage.stt;

  @override
  void dispose() {
    for (final controller in [_name, _endpoint, _model, _language, _minimum, _maximum, _key]) {
      controller.dispose();
    }
    super.dispose();
  }

  NextProcessingDraft get _draft => NextProcessingDraft(
    stage: widget.stage,
    id: widget.profile?.id,
    name: _name.text.trim(),
    endpoint: _endpoint.text.trim(),
    model: _model.text.trim(),
    language: _language.text.trim(),
    device: _original?.device,
    minSpeakers: int.tryParse(_minimum.text.trim()),
    maxSpeakers: int.tryParse(_maximum.text.trim()),
  );

  Future<void> _submit(_Action action) async {
    if (!_enabled || !widget.isCurrentClient() || !_form.currentState!.validate()) return;
    final l = context.l10n;
    if (_stt && action != _Action.models && _model.text.trim().isEmpty) {
      setState(() => _message = l.modelRequired);
      return;
    }
    final draft = _draft;
    final replacement = _key.text.trim();
    if (replacement.isEmpty && !_clearKey && draft.needsKeyDecision(widget.profile)) {
      setState(() => _message = pairedSettingsLabel(context, 'processingKeyChanged'));
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (action == _Action.save) {
        await widget.client.save(widget.settings, draft, apiKey: replacement, clearKey: _clearKey);
        if (mounted && widget.isCurrentClient() && ModalRoute.of(context)?.isCurrent == true) {
          _key.clear();
          Navigator.pop(context);
        }
        return;
      }
      final result = action == _Action.models
          ? await widget.client.models(widget.settings, draft, apiKey: replacement, clearKey: _clearKey)
          : await widget.client.probe(widget.settings, draft, apiKey: replacement, clearKey: _clearKey);
      if (!mounted || !widget.isCurrentClient()) return;
      setState(() {
        if (action == _Action.models) _models = result.models;
        _message = switch (result.state) {
          NextProbeState.ready || NextProbeState.available when action == _Action.models && _models.isEmpty =>
            pairedSettingsLabel(context, 'processingNoModels'),
          NextProbeState.ready => pairedSettingsLabel(context, 'processingProbeReady'),
          NextProbeState.available => l.connected,
          NextProbeState.misconfigured => pairedSettingsLabel(context, 'providerMisconfigured'),
          NextProbeState.unavailable => pairedSettingsLabel(context, 'providerUnavailable'),
        };
      });
    } on NextProcessingFailure catch (error) {
      if (!mounted || !widget.isCurrentClient()) return;
      setState(() {
        _message = processingFailureLabel(context, error);
        _needsRefresh =
            error == NextProcessingFailure.conflict ||
            error == NextProcessingFailure.indeterminate ||
            !widget.client.isCurrentSnapshot(widget.settings);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _validateBound(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final n = int.tryParse(text);
    if (n == null || n < 1 || n > 32) return pairedSettingsLabel(context, 'providerMisconfigured');
    return null;
  }

  Widget _field(
    String id,
    String label,
    TextEditingController controller, {
    String? hint,
    bool required = true,
    bool secret = false,
    bool changesProvider = false,
    String? Function(String?)? validator,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: ValueKey('next-draft-$id'),
      controller: controller,
      enabled: _enabled && !(secret && _clearKey),
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, hintText: hint),
      validator:
          validator ??
          (value) =>
              required && (value ?? '').trim().isEmpty ? pairedSettingsLabel(context, 'providerMisconfigured') : null,
      onChanged: (_) => setState(() {
        _message = null;
        if (changesProvider) _models = [];
      }),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final live = widget.stage == NextProcessingStage.live;
    return Scaffold(
      appBar: AppBar(title: Text(processingStageLabel(context, widget.stage))),
      body: Form(
        key: _form,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.serverLabel, style: Theme.of(context).textTheme.titleMedium),
              Text(
                live
                    ? 'WhisperLiveKit · WebSocket'
                    : _stt
                    ? 'OpenAI-compatible'
                    : 'Mycelia',
              ),
              const SizedBox(height: 12),
              _field('name', l.name, _name),
              _field(
                'endpoint',
                l.serverUrl,
                _endpoint,
                changesProvider: true,
                keyboard: TextInputType.url,
                validator: (_) => _draft.hasValidEndpoint ? null : l.invalidUrlError,
                hint: live
                    ? 'wss://server.example/asr'
                    : _stt
                    ? 'https://server.example/v1'
                    : 'https://server.example',
              ),
              if (_stt) ...[
                _field('model', l.model, _model, required: false),
                if (_models.isNotEmpty)
                  SizedBox(
                    height: 48.0 * _models.length.clamp(1, 3),
                    child: ListView.builder(
                      primary: false,
                      itemCount: _models.length,
                      itemExtent: 48,
                      itemBuilder: (_, index) {
                        final model = _models[index];
                        return ListTile(
                          title: Text(model, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: _enabled
                              ? () => setState(() {
                                  _model.text = model;
                                  _message = null;
                                })
                              : null,
                        );
                      },
                    ),
                  ),
                _field(
                  'language',
                  l.language,
                  _language,
                  hint: 'auto / ru / en',
                  validator: (value) => RegExp(r'^(auto|[a-z]{2,3})$').hasMatch(value?.trim() ?? '')
                      ? null
                      : pairedSettingsLabel(context, 'processingLanguageCode'),
                ),
              ],
              if (widget.stage == NextProcessingStage.diarization) ...[
                _field(
                  'minimum',
                  pairedSettingsLabel(context, 'processingMinSpeakers'),
                  _minimum,
                  keyboard: TextInputType.number,
                  validator: _validateBound,
                ),
                _field(
                  'maximum',
                  pairedSettingsLabel(context, 'processingMaxSpeakers'),
                  _maximum,
                  keyboard: TextInputType.number,
                  validator: (value) {
                    final min = int.tryParse(_minimum.text.trim()) ?? 1;
                    final max = int.tryParse(value?.trim() ?? '') ?? 32;
                    return min > max ? pairedSettingsLabel(context, 'providerMisconfigured') : _validateBound(value);
                  },
                ),
              ],
              _field('key', l.apiKey, _key, required: false, secret: true, changesProvider: true),
              Text(pairedSettingsLabel(context, 'localProcessingKeyHelp')),
              if (widget.profile?.hasKey == true)
                CheckboxListTile(
                  key: const ValueKey('next-draft-clear'),
                  title: Text('${l.delete} · ${l.apiKey}'),
                  value: _clearKey,
                  onChanged: _enabled
                      ? (checked) => setState(() {
                          _clearKey = checked == true;
                          if (_clearKey) _key.clear();
                          _models = [];
                          _message = null;
                        })
                      : null,
                ),
              if (_busy) const LinearProgressIndicator(),
              if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_message!)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  if (_stt)
                    OutlinedButton(
                      key: const ValueKey('next-draft-models'),
                      onPressed: _enabled ? () => _submit(_Action.models) : null,
                      child: Text('${l.refresh} · ${l.model}'),
                    ),
                  OutlinedButton(
                    key: const ValueKey('next-draft-probe'),
                    onPressed: _enabled ? () => _submit(_Action.probe) : null,
                    child: Text(pairedSettingsLabel(context, 'localProcessingProbe')),
                  ),
                  FilledButton(
                    key: const ValueKey('next-draft-save'),
                    onPressed: _enabled ? () => _submit(_Action.save) : null,
                    child: Text(l.save),
                  ),
                  if (_needsRefresh) TextButton(onPressed: () => Navigator.pop(context), child: Text(l.refresh)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
