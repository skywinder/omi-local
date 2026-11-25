import 'package:shared_preferences/shared_preferences.dart';

enum Cv1ResumeMode { off, armed, stopped, muted }

/// The user's choice belongs to this pairing. Only explicit capture actions change it.
class Cv1ResumeSettings {
  Cv1ResumeSettings(this._prefs, String owner) : _key = 'next.cv1.resume.$owner' {
    final stored = _prefs.getString(_key);
    mode = Cv1ResumeMode.values.where((item) => item.name == stored).firstOrNull ?? Cv1ResumeMode.off;
  }

  final SharedPreferences _prefs;
  final String _key;
  late Cv1ResumeMode mode;
  Future<bool> _pending = Future.value(true);

  Future<bool> save(Cv1ResumeMode next) {
    if (mode == next) return _pending;
    mode = next;
    _pending = _pending.then((_) async {
      try {
        return await _prefs.setString(_key, next.name);
      } on Exception {
        return false;
      }
    });
    return _pending;
  }

  bool get enabled => mode != Cv1ResumeMode.off;
  Future<bool> get saved => _pending;
}
