import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import 'credentials.dart';
import 'credentials_store.dart';
import 'employee.dart';
import 'employee_repository.dart';
import '../firebase/firebase_bootstrap.dart';
import 'microsoft_auth_config.dart';

enum LoginFailureReason { invalidCredentials, network }

class LoginException implements Exception {
  LoginException(this.reason);
  final LoginFailureReason reason;
}

/// Central place the rest of the app gets the logged-in mechanic's identity
/// and credentials from. Future features (job orders, hours, ...) should
/// read [isLoggedIn], [currentEmployee], or [currentMechanicId] here rather
/// than each rolling their own auth state; [ApiClient.serviceRemoteDio]'s
/// auth interceptor also reads credentials through this service, via
/// [currentCredentials].
///
/// `/ServiceRemote/login` doesn't actually authenticate per user on this
/// tenant right now — any username/password (even none) resolves to the
/// Administrator account. So [login] still calls it (kept for parity with
/// the real flow, in case that's ever fixed server-side), but the identity
/// the rest of the app treats as "logged in" comes from [currentEmployee] —
/// the [Employee] the technician picks on the login screen — not that
/// endpoint's response.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  RidderCredentials? _credentials;
  Employee? _employee;

  /// Notifies listeners whenever login state changes, so UI (e.g. the root
  /// widget deciding between the login screen and the app) can react.
  final ValueNotifier<bool> isLoggedInListenable = ValueNotifier(false);

  RidderCredentials? get currentCredentials => _credentials;
  Employee? get currentEmployee => _employee;
  bool get isLoggedIn => _employee != null;
  String? get username => _credentials?.username;

  /// The mechanic id the rest of the app filters/attributes work against —
  /// the picked [currentEmployee]'s id, which matches job orders'
  /// `servicemechanic.id`.
  int? get currentMechanicId => _employee?.id;

  /// Medewerkers die in het bonnenscherm de bonnen van iedereen mogen zien
  /// (op naam, want de ids verschillen per administratie).
  static const _alleBonnenNamen = {'wim boekestijn', 'jos weterings'};

  bool get seesAllBonnen =>
      _alleBonnenNamen.contains(_employee?.name.trim().toLowerCase());

  /// Loads any previously-saved credentials/employee from the Keychain into
  /// memory. Call once at app startup, before rendering the login/home
  /// decision.
  Future<void> bootstrap() async {
    _credentials = await CredentialsStore.instance.read();
    _employee = await CredentialsStore.instance.readEmployee();
    // Een bewaarde sessie telt alleen als er ook een Microsoft-sessie is.
    // Sessies uit eerdere versies (monteur gekozen, geen Microsoft) moeten
    // dus één keer opnieuw inloggen.
    if (_employee != null && !_hasMicrosoftSession) {
      _credentials = null;
      _employee = null;
      await CredentialsStore.instance.clear();
    }
    isLoggedInListenable.value = isLoggedIn;
  }

  /// In debug-builds blijft de oude medewerkerskeuze werken (zonder
  /// Microsoft-sessie, dus zonder gedeelde tussenopslag).
  bool get _hasMicrosoftSession =>
      kDebugMode ||
      !MicrosoftAuthConfig.enabled || !FirebaseBootstrap.isReady || FirebaseBootstrap.isSignedIn;

  /// Logt in met het Microsoft-werkaccount en zoekt de bijbehorende monteur
  /// in Ridder op e-mailadres. Gooit [MicrosoftLoginException] (leesbare
  /// melding) of [LoginException] (Ridder niet bereikbaar).
  Future<void> loginWithMicrosoft() async {
    final result = await FirebaseBootstrap.signInWithMicrosoft();
    try {
      final Employee? employee;
      try {
        employee = await EmployeeRepository.instance.findByEmails(result.emails);
      } on DioException {
        throw LoginException(LoginFailureReason.network);
      }
      if (employee == null) {
        final adres = result.emails.isEmpty ? '' : ' (${result.emails.first})';
        throw MicrosoftLoginException(
          'Je Microsoft-account$adres is niet gekoppeld aan een monteur in '
          'Ridder. Neem contact op met kantoor.',
        );
      }
      await login(employee);
    } catch (_) {
      // Geen halve sessie achterlaten: Firebase-toegang hoort bij een
      // gekoppelde monteur.
      await FirebaseBootstrap.signOut();
      rethrow;
    }
  }

  /// Calls `GET /ServiceRemote/login` (see the class doc for why its
  /// response is otherwise unused) and, if reachable, stores [employee] —
  /// picked on the login screen — as who's logged in.
  ///
  /// Throws [LoginException] with [LoginFailureReason.invalidCredentials]
  /// on a 401, or [LoginFailureReason.network] on any other failure (no
  /// connection, timeout, unexpected status, ...).
  Future<void> login(Employee employee) async {
    final credentials = RidderCredentials(
      username: employee.code,
      password: '',
    );
    final login = await _callLoginEndpoint(credentials);

    _credentials = RidderCredentials(
      username: credentials.username,
      password: credentials.password,
      mechanicId: login.mechanicId,
    );
    _employee = employee;
    isLoggedInListenable.value = true;
    await CredentialsStore.instance.save(_credentials!);
    await CredentialsStore.instance.saveEmployee(_employee!);
  }

  /// Re-hits `GET /ServiceRemote/login` with the already-stored credentials,
  /// without changing [currentEmployee] — some write endpoints 500 without
  /// this immediately beforehand, even though we're already "logged in";
  /// the official app does this too. Throws [LoginException] the same way
  /// [login] does; callers should treat that as the write itself failing.
  Future<void> reverifySession() async {
    final credentials = _credentials;
    if (credentials == null) {
      throw LoginException(LoginFailureReason.invalidCredentials);
    }
    await _callLoginEndpoint(credentials);
  }

  Future<ServiceRemoteLogin> _callLoginEndpoint(
    RidderCredentials credentials,
  ) async {
    final dio = ApiClient.instance.serviceRemoteDio;
    final basicAuth = base64Encode(
      utf8.encode('${credentials.username}:${credentials.password}'),
    );

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
    return login;
  }

  /// Clears the in-memory and Keychain-stored credentials/employee.
  Future<void> logout() async {
    _credentials = null;
    _employee = null;
    isLoggedInListenable.value = false;
    await CredentialsStore.instance.clear();
    await FirebaseBootstrap.signOut();
  }
}
