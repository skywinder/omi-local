import 'package:omi/env/env.dart';

bool shouldCheckFirmwareUpdates({bool? offlineRuntime}) {
  return !(offlineRuntime ?? Env.isOfflineRuntime);
}
