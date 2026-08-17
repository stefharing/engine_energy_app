import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import 'credentials.dart';
import 'credentials_store.dart';

enum LoginFailureReason { invalidCredentials, network }

class LoginException implements Exception {
  LoginException(this.reason);
  final LoginFailureReason reason;
}

/// Central place the rest of the app gets the logged-in mechanic's identity
/// and credentials from. Future features (job orders, hours, ...) should
/// read [isLoggedIn], [username], or [currentMechanicId] here rather than
/// each rolling their own auth state; [ApiClient.serviceRemoteDio]'s auth
/// interceptor also reads credentials through this service, via
/// [currentCredentials].
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  RidderCredentials? _credentials;

  /// Notifies listeners whenever login state changes, so UI (e.g. the root
  /// widget deciding between the login screen and the app) can react.
  final ValueNotifier<bool> isLoggedInListenable = ValueNotifier(false);

  RidderCredentials? get currentCredentials => _credentials;
  bool get isLoggedIn => _credentials?.mechanicId != null;
  String? get username => _credentials?.username;
  int? get currentMechanicId => _credentials?.mechanicId;

  /// Loads any previously-saved credentials from the Keychain into memory.
  /// Call once at app startup, before rendering the login/home decision.
  Future<void> bootstrap() async {
    _credentials = await CredentialsStore.instance.read();
    isLoggedInListenable.value = isLoggedIn;
  }

  /// Verifies [username]/[password] against `GET /ServiceRemote/login` and,
  /// on success, stores them in the Keychain and keeps them in memory for
  /// [ServiceRemoteAuthInterceptor] to attach to subsequent requests.
  ///
  /// Throws [LoginException] with [LoginFailureReason.invalidCredentials]
  /// on a 401, or [LoginFailureReason.network] on any other failure (no
  /// connection, timeout, unexpected status, ...).
  Future<void> login(String username, String password) async {
    final credentials = RidderCredentials(
      username: username,
      password: password,
    );
    final dio = ApiClient.instance.serviceRemoteDio;
    final basicAuth = base64Encode(utf8.encode('$username:$password'));

    final Response response;
    try {
      response = await dio.get(
        '/ServiceRemote/login',
        options: Options(headers: {'Authorization': 'Basic $basicAuth'}),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw LoginException(LoginFailureReason.invalidCredentials);
      }
      throw LoginException(LoginFailureReason.network);
    }

    if (response.statusCode != 200) {
      throw LoginException(LoginFailureReason.invalidCredentials);
    }

    if (response.data is! Map) {
      throw LoginException(LoginFailureReason.network);
    }
    final login = ServiceRemoteLogin.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
    if (login.mechanicId == null) {
      throw LoginException(LoginFailureReason.network);
    }

    _credentials = RidderCredentials(
      username: credentials.username,
      password: credentials.password,
      mechanicId: login.mechanicId,
    );
    isLoggedInListenable.value = true;
    await CredentialsStore.instance.save(_credentials!);
  }

  /// Clears the in-memory and Keychain-stored credentials.
  Future<void> logout() async {
    _credentials = null;
    isLoggedInListenable.value = false;
    await CredentialsStore.instance.clear();
  }
}
