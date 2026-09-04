import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/notifications/notification_service.dart';

void main() {
  test('offline runtime selects local/basic notifications', () {
    expect(notificationImplementationFor(offline: true), NotificationImplementation.basic);
    expect(notificationImplementationFor(offline: false), NotificationImplementation.fcm);
  });
}
