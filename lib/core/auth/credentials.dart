/// A mechanic's Ridder login (HTTP Basic Auth), independent of the fixed
/// per-tenant `X-API-KEY` in [ApiConfig].
class RidderCredentials {
  const RidderCredentials({
    required this.username,
    required this.password,
    this.mechanicId,
  });

  final String username;
  final String password;
  final int? mechanicId;
}

/// Identity returned by `GET /ServiceRemote/login`.
///
/// `id` identifies the login record; `employee` is the Service Remote
/// mechanic id used by job orders, appointments and hours.
class ServiceRemoteLogin {
  const ServiceRemoteLogin({
    required this.loginRecordId,
    required this.mechanicId,
  });

  final int? loginRecordId;
  final int? mechanicId;

  factory ServiceRemoteLogin.fromJson(Map<String, dynamic> json) =>
      ServiceRemoteLogin(
        loginRecordId: _asInt(json['id']),
        mechanicId: _asInt(json['employee']),
      );
}

int? _asInt(dynamic value) =>
    value is int ? value : int.tryParse(value?.toString() ?? '');
