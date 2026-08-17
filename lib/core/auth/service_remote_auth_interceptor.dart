import 'dart:convert';

import 'package:dio/dio.dart';

import 'credentials.dart';

/// Adds the per-mechanic HTTP Basic Auth header to every outgoing
/// `/ServiceRemote/*` request.
///
/// `X-API-KEY` is already set as a default header on the Dio client itself
/// (see `ApiClient.serviceRemoteDio`) — that's the fixed per-tenant key.
/// This interceptor adds the second, independent auth mechanism: Basic Auth
/// for whichever mechanic is currently logged in. Both are required on
/// every call; a missing Basic Auth header was, in practice, the cause of
/// repeated 500s on write endpoints, so this is not optional.
class ServiceRemoteAuthInterceptor extends Interceptor {
  ServiceRemoteAuthInterceptor(this._currentCredentials);

  /// Returns the currently logged-in mechanic's credentials, or `null` if
  /// nobody is logged in. Passed in as a callback (rather than reading
  /// `AuthService.instance` directly) so this interceptor can be unit
  /// tested without touching the Keychain or making a network call.
  final RidderCredentials? Function() _currentCredentials;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final credentials = _currentCredentials();
    if (credentials != null) {
      final token = base64Encode(
        utf8.encode('${credentials.username}:${credentials.password}'),
      );
      options.headers['Authorization'] = 'Basic $token';
    }
    handler.next(options);
  }
}
