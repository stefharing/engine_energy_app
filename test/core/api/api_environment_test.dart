import 'package:engine_energy_app/core/api/api_client.dart';
import 'package:engine_energy_app/core/api/api_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final client = ApiClient.instance;

  tearDown(() => client.useEnvironment(ApiEnvironment.live));

  test('defaults to live when nothing was saved', () async {
    SharedPreferences.setMockInitialValues({});
    await ApiClient.loadSavedEnvironment();

    expect(ApiConfig.environment, ApiEnvironment.live);
    expect(client.dio.options.baseUrl, contains('/RIQ_80167_0/v2'));
    expect(client.dio.options.headers['X-API-KEY'], ApiConfig.live.apiKey);
  });

  test('switching points both clients at the test administration', () async {
    SharedPreferences.setMockInitialValues({});
    await client.useEnvironment(ApiEnvironment.test);

    expect(ApiConfig.administrationId, 'RIQ_80167_3');
    expect(client.dio.options.baseUrl, contains('/RIQ_80167_3/v2'));
    expect(
      client.serviceRemoteDio.options.baseUrl,
      contains('/RIQ_80167_3/v1'),
    );
    expect(client.dio.options.headers['X-API-KEY'], ApiConfig.test.apiKey);
    expect(
      client.serviceRemoteDio.options.headers['X-API-KEY'],
      ApiConfig.test.apiKey,
    );
  });

  test('the choice survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    await client.useEnvironment(ApiEnvironment.test);
    ApiConfig.environment = ApiEnvironment.live; // simulate a fresh launch

    await ApiClient.loadSavedEnvironment();

    expect(ApiConfig.environment, ApiEnvironment.test);
    expect(client.dio.options.baseUrl, contains('/RIQ_80167_3/v2'));
  });
}
