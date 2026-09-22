class ApiConfig {
  static const String tenantId = 'Engine Energy B.V.';
  static const String administrationId = 'RIQ_80167_1';
  static const String apiKey = '77d019ae-4738-4e35-9e5f-7c828d06f5af';

  static String get baseUrl =>
      'https://api.eciridderiq.com/${tenantId.replaceAll(' ', '%20')}/$administrationId/v2';

  // The "Service Remote" job order endpoint lives under its own /v1 path,
  // separate from the general v2 REST API used elsewhere in this app.
  static String get serviceRemoteBaseUrl =>
      'https://api.eciridderiq.com/${tenantId.replaceAll(' ', '%20')}/$administrationId/v1';
}
