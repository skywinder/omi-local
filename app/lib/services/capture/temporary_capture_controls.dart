// LIFECYCLE: one-time
// DELETE-AFTER: G12-live-capture-controls
import 'package:omi/env/env.dart';

/// Remove with the temporary home controls once the local live screen owns Stop.
abstract final class TemporaryCaptureControls {
  static bool get enabled => Env.isOfflineRuntime;
}
