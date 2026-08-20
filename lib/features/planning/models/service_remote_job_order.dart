/// A tolerant, round-trip-safe representation of a Service Remote job order
/// (`GET/POST /ServiceRemote/JobOrder/{id}`).
///
/// The API adds fields over time and the hours-submission flow must POST the
/// complete response back. Therefore [raw] is the source of truth: typed
/// properties below are convenient views only, and [toJson] returns the
/// original object unchanged. Named `ServiceRemoteJobOrder` (rather than
/// `JobOrder`) to avoid clashing with the v2-API `ServiceOrder` model in
/// `job_order.dart` — these represent the same underlying record via two
/// different API versions.
class ServiceRemoteJobOrder {
  ServiceRemoteJobOrder(Map<String, dynamic> raw) : raw = raw;

  final Map<String, dynamic> raw;

  int? get id => _asInt(raw['id']);
  String get recordTag => _asString(raw['recordTag'] ?? raw['recordtag']);
  String get description => _asString(raw['description']);
  ServiceObject? get serviceObject => _asMap(
    raw['serviceObject'] ?? raw['serviceobject'],
  )?.let(ServiceObject.new);
  List<AppointmentEntry> get employees => _asList(raw['employees'])
      .whereType<Map>()
      .map((entry) => AppointmentEntry(Map<String, dynamic>.from(entry)))
      .toList(growable: false);

  /// Intentionally returns the exact map received from the detail endpoint.
  Map<String, dynamic> toJson() => raw;
}

class ServiceObject {
  ServiceObject(this.raw);
  final Map<String, dynamic> raw;
  int? get id => _asInt(raw['id']);
  String get description =>
      _asString(raw['description'] ?? raw['recordTag'] ?? raw['recordtag']);
}

class AppointmentEntry {
  AppointmentEntry(this.raw);
  final Map<String, dynamic> raw;
  int? get id => _asInt(raw['id']);
  int? get employeeId {
    final employee = raw['employee'];
    return _asInt(employee) ?? _asInt(_asMap(employee)?['id']);
  }
}

/// Explicit error for a job that is not assigned to the authenticated mechanic.
class MechanicAppointmentNotFound implements Exception {
  const MechanicAppointmentNotFound(this.mechanicId);
  final int mechanicId;

  @override
  String toString() => 'No appointment is assigned to mechanic $mechanicId.';
}

/// Resolves the appointment id to use for opening/closing/submitting this
/// job order: the `employees[]` entry matching [mechanicId]'s own `.id`
/// field — NOT `appointmentActionId`, which is a different, unrelated id on
/// the same entry.
AppointmentEntry appointmentForMechanic(
  ServiceRemoteJobOrder jobOrder,
  int mechanicId,
) {
  for (final entry in jobOrder.employees) {
    if (entry.employeeId == mechanicId && entry.id != null) return entry;
  }
  throw MechanicAppointmentNotFound(mechanicId);
}

Map<String, dynamic>? _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;
List<dynamic> _asList(dynamic value) => value is List ? value : const [];
int? _asInt(dynamic value) =>
    value is int ? value : int.tryParse(value?.toString() ?? '');
String _asString(dynamic value) => value?.toString() ?? '';

extension _NullableMapTransform on Map<String, dynamic>? {
  T? let<T>(T Function(Map<String, dynamic>) transform) =>
      this == null ? null : transform(this!);
}
