import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:engine_energy_app/core/auth/credentials.dart';
import 'package:engine_energy_app/core/auth/service_remote_auth_interceptor.dart';

void main() {
  test('outgoing request keeps X-API-KEY and gains the Basic Auth header', () {
    const credentials = RidderCredentials(
      username: 'LEXDEBRUIJN',
      password: 's3cret',
    );
    final interceptor = ServiceRemoteAuthInterceptor(() => credentials);

    final options = RequestOptions(
      path: '/ServiceRemote/JobOrder/59',
      headers: {'X-API-KEY': 'test-api-key'},
    );

    final handler = RequestInterceptorHandler();

    interceptor.onRequest(options, handler);

    expect(handler.isCompleted, isTrue);
    expect(options.headers['X-API-KEY'], 'test-api-key');
    expect(
      options.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('LEXDEBRUIJN:s3cret'))}',
    );
  });

  test('no credentials → no Authorization header is added', () {
    final interceptor = ServiceRemoteAuthInterceptor(() => null);
    final options = RequestOptions(
      path: '/ServiceRemote/JobOrder/59',
      headers: {'X-API-KEY': 'test-api-key'},
    );
    final handler = RequestInterceptorHandler();

    interceptor.onRequest(options, handler);

    expect(options.headers.containsKey('Authorization'), isFalse);
  });
}
