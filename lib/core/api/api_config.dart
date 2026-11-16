/// Which Ridder IQ administration the app talks to. Chosen with the toggle
/// on the login screen and remembered across launches — see
/// `ApiClient.useEnvironment`.
enum ApiEnvironment { live, test }

class ApiEnvironmentConfig {
  final String tenantId;
  final String administrationId;
  final String apiKey;

  const ApiEnvironmentConfig({
    required this.tenantId,
    required this.administrationId,
    required this.apiKey,
  });
}

class ApiConfig {
  /// Geoapify (geocoding + statische kaartjes op het bon-detailscherm).
  static const geoapifyApiKey = 'fb9cae2c4efd4aceb8ecd3d783bdf5da';

  static const live = ApiEnvironmentConfig(
    tenantId: 'Engine Energy B.V.',
    administrationId: 'RIQ_80167_0',
    apiKey: 'fab19227-d7b4-4b2e-824a-df464c1e9d6a',
  );

  static const test = ApiEnvironmentConfig(
    tenantId: 'Engine Energy B.V.',
    administrationId: 'RIQ_80167_3',
    apiKey: '5f854435-aa71-4d12-843b-cc80188c66cc',
  );

  /// Set via `ApiClient.useEnvironment` / `ApiClient.loadSavedEnvironment`,
  /// which also point the HTTP clients at it — don't assign directly.
  static ApiEnvironment environment = ApiEnvironment.live;

  static ApiEnvironmentConfig get _current => switch (environment) {
    ApiEnvironment.live => live,
    ApiEnvironment.test => test,
  };

  static String get tenantId => _current.tenantId;
  static String get administrationId => _current.administrationId;
  static String get apiKey => _current.apiKey;

  static String get baseUrl =>
      'https://api.eciridderiq.com/${tenantId.replaceAll(' ', '%20')}/$administrationId/v2';

  // The "Service Remote" job order endpoint lives under its own /v1 path,
  // separate from the general v2 REST API used elsewhere in this app.
  static String get serviceRemoteBaseUrl =>
      'https://api.eciridderiq.com/${tenantId.replaceAll(' ', '%20')}/$administrationId/v1';
}
