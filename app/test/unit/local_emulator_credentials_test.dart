import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/auth/local_emulator_credentials.dart';

void main() {
  test('offline login resolves only the seeded alice emulator account', () {
    final credentials = localEmulatorCredentialsFor('alice');
    expect(credentials.email, 'alice@local.omi.invalid');
    expect(credentials.password, 'alice-local-password-030');
    expect(() => localEmulatorCredentialsFor('bob'), throwsStateError);
  });
}
