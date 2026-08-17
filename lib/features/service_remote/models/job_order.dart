/// A tolerant, round-trip-safe representation of a Service Remote job order.
///
/// The API adds fields over time and phase 5 must POST the complete response
/// back. Therefore [raw] is the source of truth: typed properties below are
/// convenient views only, and [toJson] returns the original object unchanged.
class JobOrder {
  JobOrder(Map<String, dynamic> raw) : raw = raw;

  final Map<String, dynamic> raw;

  int? get id => _asInt(raw['id']);
  String get recordTag => _asString(raw['recordTag'] ?? raw['recordtag']);
  String get description => _asString(raw['description']);
  dynamic get serviceType => raw['serviceType'] ?? raw['servicetype'];
  ServiceObject? get serviceObject => _asMap(
    raw['serviceObject'] ?? raw['serviceobject'],
  )?.let(ServiceObject.new);
  Order? get order => _asMap(raw['order'])?.let(Order.new);
  dynamic get location => raw['location'] ?? raw['objectlocation'];
  dynamic get serviceMechanic =>
      raw['serviceMechanic'] ?? raw['servicemechanic'];
  List<AppointmentEntry> get employees => _asList(raw['employees'])
      .whereType<Map>()
      .map((entry) => AppointmentEntry(Map<String, dynamic>.from(entry)))
      .toList(growable: false);
  List<dynamic> get detailItems =>
      _asList(raw['detailItems'] ?? raw['detailitems']);
  List<dynamic> get detailMisc =>
      _asList(raw['detailMisc'] ?? raw['detailmisc']);

  /// Intentionally returns the exact map received from the detail endpoint.
  Map<String, dynamic> toJson() => raw;
}

/// Summary returned by `GetActiveJobOrders`.
class JobOrderSummary {
  JobOrderSummary(Map<String, dynamic> raw) : raw = raw;

  final Map<String, dynamic> raw;
  int? get id => _asInt(raw['id']);
  String get recordTag => _asString(raw['recordTag'] ?? raw['recordtag']);
  String get description => _asString(raw['description']);
  dynamic get serviceType => raw['serviceType'] ?? raw['servicetype'];
  ServiceObject? get serviceObject => _asMap(
    raw['serviceObject'] ?? raw['serviceobject'],
  )?.let(ServiceObject.new);
}

class ServiceObject {
  ServiceObject(this.raw);
  final Map<String, dynamic> raw;
  int? get id => _asInt(raw['id']);
  dynamic get relation => raw['relation'];
  String get description =>
      _asString(raw['description'] ?? raw['recordTag'] ?? raw['recordtag']);
}

class Order {
  Order(this.raw);
  final Map<String, dynamic> raw;
  int? get id => _asInt(raw['id']);
  dynamic get relation => raw['relation'];
  dynamic get contact => raw['contact'];
}

class AppointmentEntry {
  AppointmentEntry(this.raw);
  final Map<String, dynamic> raw;
  int? get id => _asInt(raw['id']);
  int? get employeeId {
    final employee = raw['employee'];
    return _asInt(employee) ?? _asInt(_asMap(employee)?['id']);
  }

  dynamic get employee => raw['employee'];
  dynamic get date => raw['date'];
  int? get appointmentActionId =>
      _asInt(raw['appointmentActionId'] ?? raw['appointmentactionid']);
}

/// Explicit error for a job that is not assigned to the authenticated mechanic.
class MechanicAppointmentNotFound implements Exception {
  const MechanicAppointmentNotFound(this.mechanicId);
  final int mechanicId;

  @override
  String toString() => 'No appointment is assigned to mechanic $mechanicId.';
}

AppointmentEntry appointmentForMechanic(JobOrder jobOrder, int mechanicId) {
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
