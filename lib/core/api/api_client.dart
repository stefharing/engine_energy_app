import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_service.dart';
import '../auth/service_remote_auth_interceptor.dart';
import 'api_config.dart';

class ApiClient {
  ApiClient._() {
    serviceRemoteDio.interceptors.add(
      ServiceRemoteAuthInterceptor(() => AuthService.instance.currentCredentials),
    );
  }

  static final ApiClient instance = ApiClient._();

  static const _environmentKey = 'api_environment';

  /// Restores the environment picked on the login screen last time (live
  /// by default). Call once at startup, before any request is made.
  static Future<void> loadSavedEnvironment() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_environmentKey);
    ApiConfig.environment = ApiEnvironment.values.firstWhere(
      (e) => e.name == saved,
      orElse: () => ApiEnvironment.live,
    );
    instance._applyConfig();
  }

  /// Switches every request — both clients — to [environment]'s tenant,
  /// administration and API key, and remembers the choice.
  Future<void> useEnvironment(ApiEnvironment environment) async {
    ApiConfig.environment = environment;
    _applyConfig();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_environmentKey, environment.name);
  }

  void _applyConfig() {
    dio.options
      ..baseUrl = ApiConfig.baseUrl
      ..headers['X-API-KEY'] = ApiConfig.apiKey;
    serviceRemoteDio.options
      ..baseUrl = ApiConfig.serviceRemoteBaseUrl
      ..headers['X-API-KEY'] = ApiConfig.apiKey;
  }

  late final Dio dio = Dio(
    BaseOptions(
      baseUrl: ApiConfig.baseUrl,
      headers: {'X-API-KEY': ApiConfig.apiKey},
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  /// Separate client for the "Service Remote" /v1 API (e.g.
  /// `/ServiceRemote/JobOrder/{id}`), which is versioned independently from
  /// the general v2 REST API above. Every request also needs the logged-in
  /// mechanic's Basic Auth credentials alongside the fixed X-API-KEY below
  /// — see [ServiceRemoteAuthInterceptor], attached in the constructor.
  late final Dio serviceRemoteDio = Dio(
    BaseOptions(
      baseUrl: ApiConfig.serviceRemoteBaseUrl,
      headers: {'X-API-KEY': ApiConfig.apiKey},
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );
}
