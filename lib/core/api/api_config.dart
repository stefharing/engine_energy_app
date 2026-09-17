class ApiConfig {
  static const String tenantId = 'Engine Energy B.V.';
  static const String administrationId = 'RIQ_80167_3';
  static const String apiKey = '5f854435-aa71-4d12-843b-cc80188c66cc';

  static String get baseUrl =>
      'https://api.eciridderiq.com/${tenantId.replaceAll(' ', '%20')}/$administrationId/v2';

  // The "Service Remote" job order endpoint lives under its own /v1 path,
  // separate from the general v2 REST API used elsewhere in this app.
  static String get serviceRemoteBaseUrl =>
      'https://api.eciridderiq.com/${tenantId.replaceAll(' ', '%20')}/$administrationId/v1';
}
