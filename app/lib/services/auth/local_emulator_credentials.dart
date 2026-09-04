final class LocalEmulatorCredentials {
  const LocalEmulatorCredentials({required this.email, required this.password});

  final String email;
  final String password;
}

LocalEmulatorCredentials localEmulatorCredentialsFor(String alias) {
  if (alias != 'alice') {
    throw StateError('Only the synthetic local user "alice" is permitted.');
  }
  return LocalEmulatorCredentials(email: '$alias@local.omi.invalid', password: '$alias-local-password-030');
}
