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

  static NextProcessingStage? _parse(Object? wire) {
    for (final stage in values) {
      if (stage.name == wire) return stage;
    }
    return null;
  }
}

/// The prepared and effective cards share this projection. The harness owns
/// provider addresses, model paths, credentials and editable settings.
class NextProcessingProfile {
  const NextProcessingProfile._(
    this.id,
    this.name,
    this.stage,
    this.kind,
    this.configurationRevision,
    this.inheritedFrom,
  );

  final String id;
  final String name;
  final NextProcessingStage stage;
  final String kind;
  final int? configurationRevision;
  final NextProcessingStage? inheritedFrom;

  factory NextProcessingProfile._parse(Map row, NextProcessingStage stage) {
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
      final card = NextProcessingProfile._parse(row, stage);
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
}

/// Mutations refer to an exact snapshot issued by this client for one pairing.
/// A failed or uncertain write consumes the approval until the next explicit read.
class NextProcessingClient {
  NextProcessingClient({
    required Future<Map<String, dynamic>> Function() read,
    required Future<Map<String, dynamic>> Function(Map<String, dynamic>) activatePrepared,
    this.permitsActivation,
  }) : _read = read,
       _activate = activatePrepared;

  final Future<Map<String, dynamic>> Function() _read;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) _activate;
  final bool Function()? permitsActivation;
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
    if (!identical(approved, _confirmed) || _reading != null || _writing) throw NextProcessingFailure.conflict;
    if (!(permitsActivation?.call() ?? true) || !approved.canActivate(stage, id)) throw NextProcessingFailure.invalid;
    final selected = approved.profiles.where((p) => p.stage == stage && p.id == id).firstOrNull;
    _confirmed = null;
    _writing = true;
    try {
      final response = await _activate({'revision': approved.revision, 'stage': stage.name, 'id': id});
      // Publication may already have happened when a response is malformed or
      // another writer changes the effective selection before it is returned.
      final NextProcessingSettings after;
      try {
        after = NextProcessingSettings.fromJson(response);
      } on NextProcessingFailure {
        throw NextProcessingFailure.indeterminate;
      }
      final active = after.active(stage);
      if (!after.supports(stage) ||
          after.revision <= approved.revision ||
          active?.id != id ||
          active?.configurationRevision != selected?.configurationRevision) {
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
