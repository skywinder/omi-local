enum NextProcessingFailure implements Exception {
  unavailable,
  unauthorized,
  unsupported,
  conflict,
  invalid,
  indeterminate,
}

enum NextProcessingStage {
  live,
  stt,
  diarization,
  summary,
  translation;

  bool get canActivate => this == live || this == stt || this == diarization;
  bool get canDisable => this == live || this == diarization;
  bool get canCreateDraft => canActivate;

  static NextProcessingStage? _parse(Object? wire) {
    for (final stage in values) {
      if (stage.name == wire) return stage;
    }
    return null;
  }
}

enum NextDraftOperation { save, probe, models, delete }

enum NextProbeState { ready, available, misconfigured, unavailable }

class NextProcessingProbe {
  const NextProcessingProbe._(this.state, this.models, this.latencyMs);
  final NextProbeState state;
  final List<String> models;
  final int? latencyMs;

  factory NextProcessingProbe._parse(Map<String, dynamic> data) {
    final state = NextProbeState.values.where((s) => s.name == data['state']).firstOrNull;
    final rows = data['models'] ?? const [], latency = data['latency_ms'];
    if (state == null || rows is! List || rows.length > 2000 || (latency != null && (latency is! int || latency < 0))) {
      throw NextProcessingFailure.unavailable;
    }
    final models = <String>[];
    for (final name in rows) {
      if (name is! String || name.trim().isEmpty || name.runes.length > 256 || name.runes.any((c) => c < 32)) {
        throw NextProcessingFailure.unavailable;
      }
      models.add(name);
    }
    return NextProcessingProbe._(state, List.unmodifiable(models), latency as int?);
  }
}

/// The harness owns credentials. The editor receives only the editable adapter
/// fields and supplies any replacement key separately for one request.
class NextProcessingDraft {
  const NextProcessingDraft({
    required this.stage,
    required this.name,
    required this.endpoint,
    this.id,
    this.model = '',
    this.language = 'auto',
    this.device,
    this.minSpeakers,
    this.maxSpeakers,
  });
  final NextProcessingStage stage;
  final String name, endpoint, model, language;
  final String? id, device;
  final int? minSpeakers, maxSpeakers;

  String get _kind => switch (stage) {
    NextProcessingStage.live => 'external',
    NextProcessingStage.stt => 'openai-compatible',
    NextProcessingStage.diarization => 'mycelia',
    _ => throw NextProcessingFailure.invalid,
  };

  static NextProcessingDraft? _editable(Map row, NextProcessingStage stage) {
    if (!stage.canCreateDraft || row['can_edit'] != true) return null;
    final data = row['settings'];
    if (data is! Map) return null;
    final fields = switch (stage) {
      NextProcessingStage.live => const {'url'},
      NextProcessingStage.stt => const {'provider_url', 'model', 'language', 'device', 'diarization_model'},
      _ => const {'base_url', 'min_speakers', 'max_speakers'},
    };
    final endpointField = switch (stage) {
      NextProcessingStage.live => 'url',
      NextProcessingStage.stt => 'provider_url',
      _ => 'base_url',
    };
    final url = data[endpointField];
    if (url is! String ||
        data.keys.any((k) => !fields.contains(k)) ||
        (data['diarization_model'] != null && data['diarization_model'] != 'none') ||
        [data['model'], data['language'], data['device']].any((v) => v != null && v is! String) ||
        [data['min_speakers'], data['max_speakers']].any((v) => v != null && v is! int)) {
      return null;
    }
    final draft = NextProcessingDraft(
      stage: stage,
      name: row['name'] as String,
      id: row['id'] as String,
      endpoint: url,
      model: data['model'] as String? ?? '',
      language: data['language'] as String? ?? 'auto',
      device: data['device'] as String?,
      minSpeakers: data['min_speakers'] as int?,
      maxSpeakers: data['max_speakers'] as int?,
    );
    return row['kind'] == draft._kind && draft.hasValidEndpoint ? draft : null;
  }

  // Registry.identity uses Python urlsplit().netloc verbatim. Keep explicit
  // default ports and authority spelling, which Dart's Uri would normalize.
  String? get _networkIdentity {
    final match = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]+)').firstMatch(endpoint.trim());
    return match == null ? null : '${match[1]!.toLowerCase()}://${match[2]}';
  }

  bool needsKeyDecision(NextProcessingProfile? original) =>
      original?.hasKey == true && original?.editableDraft?._networkIdentity != _networkIdentity;

  bool get hasValidEndpoint {
    final url = endpoint.trim();
    final parsed = Uri.tryParse(url);
    final schemes = stage == NextProcessingStage.live ? const {'ws', 'wss'} : const {'http', 'https'};
    return parsed != null &&
        schemes.contains(parsed.scheme) &&
        parsed.host.isNotEmpty &&
        url.length <= 2048 &&
        !url.runes.any((c) => c < 33) &&
        !url.contains('\\') &&
        !parsed.authority.contains('@') &&
        _networkIdentity?.contains('@') != true &&
        !parsed.hasQuery &&
        !parsed.hasFragment &&
        (stage != NextProcessingStage.stt || url.replaceFirst(RegExp(r'/+$'), '').endsWith('/v1'));
  }

  Map<String, dynamic> _card(NextProcessingProfile? original, {required bool listingModels}) {
    final url = endpoint.trim().replaceFirst(RegExp(r'/+$'), '');
    if (!stage.canCreateDraft ||
        name.trim().isEmpty ||
        name.runes.length > 100 ||
        name.runes.any((c) => c < 32) ||
        !hasValidEndpoint) {
      throw NextProcessingFailure.invalid;
    }
    final settings = <String, dynamic>{};
    switch (stage) {
      case NextProcessingStage.live:
        settings['url'] = url;
      case NextProcessingStage.stt:
        if ((!listingModels && model.trim().isEmpty) ||
            model.runes.length > 256 ||
            !RegExp(r'^(auto|[a-z]{2,3})$').hasMatch(language.trim())) {
          throw NextProcessingFailure.invalid;
        }
        final originalDevice = device ?? original?.editableDraft?.device;
        settings.addAll({
          'provider_url': url,
          'model': model.trim(),
          'language': language.trim(),
          'diarization_model': 'none',
          if (originalDevice != null) 'device': originalDevice,
        });
      case NextProcessingStage.diarization:
        final min = minSpeakers ?? 1, max = maxSpeakers ?? 32;
        if (min < 1 || max > 32 || min > max) throw NextProcessingFailure.invalid;
        settings.addAll({
          'base_url': url,
          if (minSpeakers != null) 'min_speakers': minSpeakers,
          if (maxSpeakers != null) 'max_speakers': maxSpeakers,
        });
      default:
        throw NextProcessingFailure.invalid;
    }
    return {if (id != null) 'id': id, 'stage': stage.name, 'kind': _kind, 'name': name.trim(), 'settings': settings};
  }

  bool _matchesSavedSettings(Map<String, dynamic> sent) => switch (stage) {
    NextProcessingStage.live => endpoint == sent['url'],
    NextProcessingStage.stt =>
      endpoint == sent['provider_url'] &&
          model == sent['model'] &&
          language == sent['language'] &&
          device == sent['device'],
    NextProcessingStage.diarization =>
      endpoint == sent['base_url'] && minSpeakers == sent['min_speakers'] && maxSpeakers == sent['max_speakers'],
    _ => false,
  };
}

class NextProcessingProfile {
  const NextProcessingProfile._(
    this.id,
    this.name,
    this.stage,
    this.kind,
    this.configurationRevision,
    this.inheritedFrom,
    this.editableDraft,
    this.hasKey,
  );

  final String id;
  final String name;
  final NextProcessingStage stage;
  final String kind;
  final int? configurationRevision;
  final NextProcessingStage? inheritedFrom;
  final NextProcessingDraft? editableDraft;
  bool get canEdit => editableDraft != null;
  final bool hasKey;

  factory NextProcessingProfile._parse(Map row, NextProcessingStage stage, {bool prepared = false}) {
    final id = row['id'], name = row['name'], kind = row['kind'], revision = row['configuration_revision'];
    if (row['stage'] != stage.name ||
        id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.runes.length > 100 ||
        name.runes.any((rune) => rune < 32) ||
        kind is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(kind) ||
        (revision != null && (revision is! int || revision < 0))) {
      throw NextProcessingFailure.unavailable;
    }
    final inherited = stage == NextProcessingStage.translation && row['inherited_from'] == 'summary';
    return NextProcessingProfile._(
      id,
      name.trim(),
      stage,
      kind,
      revision as int?,
      inherited ? NextProcessingStage.summary : null,
      prepared ? NextProcessingDraft._editable(row, stage) : null,
      row['has_key'] == true,
    );
  }
}

class NextProcessingSettings {
  const NextProcessingSettings._(this.revision, this.profiles, this._effective);
  final int revision;
  final List<NextProcessingProfile> profiles;
  final Map<NextProcessingStage, NextProcessingProfile?> _effective;

  factory NextProcessingSettings.fromJson(Map<String, dynamic> wire) {
    final revision = wire['revision'], cards = wire['profiles'], effective = wire['effective'];
    if (revision is! int ||
        revision < 0 ||
        cards is! List ||
        effective is! Map ||
        (wire.containsKey('version') && wire['version'] != 1)) {
      throw NextProcessingFailure.unavailable;
    }
    final prepared = <NextProcessingProfile>[];
    final ids = <String>{};
    for (final row in cards) {
      if (row is! Map || row['stage'] is! String) throw NextProcessingFailure.unavailable;
      final stage = NextProcessingStage._parse(row['stage']);
      if (stage == null) continue;
      final card = NextProcessingProfile._parse(row, stage, prepared: true);
      if (!ids.add(card.id)) throw NextProcessingFailure.unavailable;
      prepared.add(card);
    }
    final active = <NextProcessingStage, NextProcessingProfile?>{};
    for (final stage in NextProcessingStage.values) {
      if (!effective.containsKey(stage.name)) continue;
      final row = effective[stage.name];
      if (row != null && row is! Map) throw NextProcessingFailure.unavailable;
      active[stage] = row == null ? null : NextProcessingProfile._parse(row as Map, stage);
    }
    return NextProcessingSettings._(revision, List.unmodifiable(prepared), Map.unmodifiable(active));
  }

  bool supports(NextProcessingStage stage) => _effective.containsKey(stage);
  NextProcessingProfile? active(NextProcessingStage stage) => _effective[stage];
  List<NextProcessingProfile> choices(NextProcessingStage stage) =>
      profiles.where((p) => p.stage == stage).toList(growable: false);

  bool canActivate(NextProcessingStage stage, String? id) =>
      stage.canActivate &&
      supports(stage) &&
      (id == null ? stage.canDisable : profiles.any((p) => p.stage == stage && p.id == id));

  bool canDelete(NextProcessingProfile p) =>
      supports(p.stage) && profiles.contains(p) && p.canEdit && !_effective.values.any((active) => active?.id == p.id);
}

/// Mutations refer to an exact snapshot issued by this client for one pairing.
/// A failed or uncertain write consumes the approval until the next explicit read.
class NextProcessingClient {
  NextProcessingClient({
    required Future<Map<String, dynamic>> Function() read,
    required Future<Map<String, dynamic>> Function(Map<String, dynamic>) activatePrepared,
    Future<Map<String, dynamic>> Function(NextDraftOperation, Map<String, dynamic>, String?)? draftRequest,
    this.summaryTemplatesRequest,
    this.permitsActivation,
  }) : _read = read,
       _activate = activatePrepared,
       _draftRequest = draftRequest;

  final Future<Map<String, dynamic>> Function() _read;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) _activate;
  final Future<Map<String, dynamic>> Function(NextDraftOperation, Map<String, dynamic>, String?)? _draftRequest;
  final bool Function()? permitsActivation;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>?)? summaryTemplatesRequest;
  NextProcessingSettings? _confirmed;
  Future<NextProcessingSettings>? _reading;
  bool _writing = false;

  Future<NextProcessingSettings> fetch() {
    if (_writing) return Future.error(NextProcessingFailure.conflict);
    return _reading ??= _fetch().whenComplete(() => _reading = null);
  }

  Future<NextProcessingSettings> _fetch() async {
    _confirmed = null;
    try {
      return _confirmed = NextProcessingSettings.fromJson(await _read());
    } on NextProcessingFailure {
      rethrow;
    } catch (_) {
      throw NextProcessingFailure.unavailable;
    }
  }

  Future<NextProcessingSettings> activate(
    NextProcessingSettings approved,
    NextProcessingStage stage,
    String? id,
  ) async {
    _requireSnapshot(approved);
    if (!(permitsActivation?.call() ?? true) || !approved.canActivate(stage, id)) throw NextProcessingFailure.invalid;
    final selected = approved.profiles.where((p) => p.stage == stage && p.id == id).firstOrNull;
    return _mutate(approved, () => _activate({'revision': approved.revision, 'stage': stage.name, 'id': id}), (after) {
      final active = after.active(stage);
      return after.supports(stage) &&
          active?.id == id &&
          active?.configurationRevision == selected?.configurationRevision;
    });
  }

  bool isCurrentSnapshot(NextProcessingSettings snapshot) =>
      identical(_confirmed, snapshot) && !_writing && _reading == null;

  void _requireSnapshot(NextProcessingSettings approved) {
    if (!isCurrentSnapshot(approved)) throw NextProcessingFailure.conflict;
  }

  Map<String, dynamic> _draftPayload(
    NextProcessingSettings approved,
    NextProcessingDraft draft,
    NextDraftOperation operation,
    String apiKey,
    bool clearKey,
  ) {
    _requireSnapshot(approved);
    if (_draftRequest == null) throw NextProcessingFailure.unsupported;
    if (!approved.supports(draft.stage) || !draft.stage.canCreateDraft) throw NextProcessingFailure.invalid;
    final original = approved.profiles.where((p) => p.id == draft.id).firstOrNull;
    if (draft.id != null && (original == null || original.stage != draft.stage || !original.canEdit)) {
      throw NextProcessingFailure.invalid;
    }
    final key = apiKey.trim();
    if (!clearKey &&
        (key.length > 8192 ||
            key.codeUnits.any((c) => c < 32 || c > 126) ||
            key.isEmpty && draft.needsKeyDecision(original))) {
      throw NextProcessingFailure.invalid;
    }
    final listing = operation == NextDraftOperation.models;
    if (listing && draft.stage != NextProcessingStage.stt) throw NextProcessingFailure.invalid;
    return {
      'profile': draft._card(original, listingModels: listing),
      if (operation == NextDraftOperation.save) 'revision': approved.revision,
      if (clearKey) 'clear_key': true else if (key.isNotEmpty) 'api_key': key,
    };
  }

  Future<NextProcessingProbe> probe(
    NextProcessingSettings approved,
    NextProcessingDraft draft, {
    String apiKey = '',
    bool clearKey = false,
  }) => _inspect(approved, draft, NextDraftOperation.probe, apiKey, clearKey);

  Future<NextProcessingProbe> models(
    NextProcessingSettings approved,
    NextProcessingDraft draft, {
    String apiKey = '',
    bool clearKey = false,
  }) => _inspect(approved, draft, NextDraftOperation.models, apiKey, clearKey);

  Future<NextProcessingProbe> _inspect(
    NextProcessingSettings approved,
    NextProcessingDraft draft,
    NextDraftOperation operation,
    String apiKey,
    bool clearKey,
  ) async {
    final payload = _draftPayload(approved, draft, operation, apiKey, clearKey);
    _writing = true;
    try {
      return NextProcessingProbe._parse(await _draftRequest!(operation, payload, null));
    } on NextProcessingFailure {
      rethrow;
    } catch (_) {
      throw NextProcessingFailure.unavailable;
    } finally {
      _writing = false;
    }
  }

  Future<NextProcessingSettings> save(
    NextProcessingSettings approved,
    NextProcessingDraft draft, {
    String apiKey = '',
    bool clearKey = false,
  }) async {
    final payload = _draftPayload(approved, draft, NextDraftOperation.save, apiKey, clearKey);
    final original = approved.profiles.where((p) => p.id == draft.id).firstOrNull;
    final expectedKey = !clearKey && (apiKey.trim().isNotEmpty || original?.hasKey == true);
    final sent = (payload['profile'] as Map)['settings'] as Map<String, dynamic>;
    return _mutate(approved, () => _draftRequest!(NextDraftOperation.save, payload, null), (after) {
      final beforeActive = approved.active(draft.stage), afterActive = after.active(draft.stage);
      if (!after.supports(draft.stage) ||
          beforeActive?.id != afterActive?.id ||
          beforeActive?.configurationRevision != afterActive?.configurationRevision) {
        return false;
      }
      final saved = after.profiles.where(
        (p) =>
            (draft.id != null ? p.id == draft.id : !approved.profiles.any((old) => old.id == p.id)) &&
            p.configurationRevision == approved.revision + 1 &&
            p.stage == draft.stage &&
            p.name == draft.name.trim() &&
            p.editableDraft?._matchesSavedSettings(sent) == true &&
            p.hasKey == expectedKey,
      );
      return saved.length == 1;
    });
  }

  Future<NextProcessingSettings> delete(NextProcessingSettings approved, NextProcessingProfile profile) async {
    _requireSnapshot(approved);
    final request = _draftRequest;
    if (request == null) throw NextProcessingFailure.unsupported;
    if (!approved.canDelete(profile)) throw NextProcessingFailure.invalid;
    return _mutate(
      approved,
      () => request(NextDraftOperation.delete, {'revision': approved.revision}, profile.id),
      (after) =>
          after.supports(profile.stage) &&
          after.active(profile.stage)?.id != profile.id &&
          !after.profiles.any((p) => p.id == profile.id),
    );
  }

  Future<NextProcessingSettings> _mutate(
    NextProcessingSettings approved,
    Future<Map<String, dynamic>> Function() send,
    bool Function(NextProcessingSettings) confirmed,
  ) async {
    _confirmed = null;
    _writing = true;
    try {
      final response = await send();
      final NextProcessingSettings after;
      try {
        after = NextProcessingSettings.fromJson(response);
      } on NextProcessingFailure {
        throw NextProcessingFailure.indeterminate;
      }
      if (after.revision <= approved.revision || !confirmed(after)) {
        throw NextProcessingFailure.indeterminate;
      }
      return _confirmed = after;
    } on NextProcessingFailure {
      rethrow;
    } catch (_) {
      throw NextProcessingFailure.indeterminate;
    } finally {
      _writing = false;
    }
  }
}
