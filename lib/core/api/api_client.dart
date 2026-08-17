import 'package:dio/dio.dart';

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
