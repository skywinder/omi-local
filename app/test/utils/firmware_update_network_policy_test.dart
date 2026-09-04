import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/firmware_update_network_policy.dart';

void main() {
  test('offline runtime suppresses optional firmware network checks', () {
    expect(shouldCheckFirmwareUpdates(offlineRuntime: true), isFalse);
    expect(shouldCheckFirmwareUpdates(offlineRuntime: false), isTrue);
  });
}
