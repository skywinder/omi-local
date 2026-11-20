import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/env/dev_env.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/offline_onboarding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => Env.init(DevEnv()));
  tearDown(() => Env.setRuntimeModeForTesting(null));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('offline runtime skips the cloud onboarding steps but still requires permissions', () {
    Env.setRuntimeModeForTesting(OmiRuntimeMode.offline);
    applyOfflineOnboardingDefaults();
    expect(SharedPreferencesUtil().aiConsentGiven, isTrue);
    expect(SharedPreferencesUtil().onboardingCompleted, isTrue);
    expect(SharedPreferencesUtil().permissionsCompleted, isFalse);
  });

  test('standard runtime keeps its onboarding state untouched', () {
    Env.setRuntimeModeForTesting(OmiRuntimeMode.standard);
    applyOfflineOnboardingDefaults();
    expect(SharedPreferencesUtil().aiConsentGiven, isFalse);
    expect(SharedPreferencesUtil().onboardingCompleted, isFalse);
  });
}
