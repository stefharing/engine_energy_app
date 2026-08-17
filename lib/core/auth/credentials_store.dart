import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credentials.dart';

/// Persists the logged-in mechanic's Ridder credentials in the iOS Keychain
/// (via `flutter_secure_storage`), so they aren't asked to log in again on
/// every app launch. Deliberately not `SharedPreferences` — credentials
/// don't belong in plist-backed storage.
class CredentialsStore {
  CredentialsStore._();
  static final CredentialsStore instance = CredentialsStore._();

  static const _usernameKey = 'ridder_username';
  static const _passwordKey = 'ridder_password';
  static const _mechanicIdKey = 'ridder_mechanic_id';

  final _storage = const FlutterSecureStorage();

  Future<RidderCredentials?> read() async {
    final username = await _storage.read(key: _usernameKey);
    final password = await _storage.read(key: _passwordKey);
    if (username == null || password == null) return null;
    final mechanicId = int.tryParse(
      await _storage.read(key: _mechanicIdKey) ?? '',
    );
    return RidderCredentials(
      username: username,
      password: password,
      mechanicId: mechanicId,
    );
  }

  Future<void> save(RidderCredentials credentials) async {
    await _storage.write(key: _usernameKey, value: credentials.username);
    await _storage.write(key: _passwordKey, value: credentials.password);
    if (credentials.mechanicId != null) {
      await _storage.write(
        key: _mechanicIdKey,
        value: credentials.mechanicId.toString(),
      );
    }
  }

  Future<void> clear() async {
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _passwordKey);
    await _storage.delete(key: _mechanicIdKey);
  }
}
