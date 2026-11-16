class ServicePerson {
  final int id;
  final String name;

  const ServicePerson({required this.id, required this.name});

  factory ServicePerson.fromJson(Map<String, dynamic> json) => ServicePerson(
    id: json['id'] as int,
    name: json['recordtag'] as String? ?? '',
  );
}

/// Common shape used by the planning timetable to position and render
/// blocks, regardless of whether they come from job orders (servicebonnen)
/// or from CRM appointments (Outlook-agenda-items).
abstract class PlanningItem {
  DateTime? get planningDate;
  DateTime? get endTime;

  /// Whether this item belongs in [mechanicId]'s planning row — a job order
  /// can be assigned to several mechanics at once.
  bool isAssignedTo(int mechanicId);
  String get title;
  String? get subtitle;
}

// The API returns naive datetime strings in UTC (no Z suffix).
// Append Z so Dart parses them as UTC, then convert to local.
DateTime? _parseIsoDate(dynamic val) {
  if (val == null) return null;
  final s = val as String;
  final normalized = (s.contains('+') || s.toUpperCase().contains('Z'))
      ? s
      : '${s}Z';
  return DateTime.tryParse(normalized)?.toLocal();
}

class ServiceOrder implements PlanningItem {
  final String id;
  final String recordTag;
  final String orderNumber;
  final String description;
  final DateTime? startDate;
  @override
  final DateTime? endTime;
  final DateTime? deliveryDate;
  final String workflowState;

  /// The job order's own `servicemechanic` — the "main" mechanic.
  final ServicePerson? mechanic;

  /// Everyone assigned to this job order: [mechanic] first, plus every
  /// employee with an appointment on it (see `applyJobOrderAssignments`).
  /// Falls back to just [mechanic] when that hasn't been loaded.
  List<ServicePerson> get assignedMechanics =>
      _assignedMechanics ?? [?mechanic];
  final List<ServicePerson>? _assignedMechanics;

  /// The `/crm/appointmentactions` ids linked to this job order — used to
  /// recognise the per-mechanic calendar appointments Ridder creates for it.
  final Set<int> appointmentActionIds;
  final String serviceObjectTag;
  final String serviceObjectDescription;
  final String serviceType;
  final String location;
  final String relationName;
  final String? serviceContractId;
  final String? productionOrderId;
  final String? serviceObjectId;

  const ServiceOrder({
    required this.id,
    required this.recordTag,
    required this.orderNumber,
    required this.description,
    required this.startDate,
    required this.endTime,
    required this.deliveryDate,
    required this.workflowState,
    required this.mechanic,
    List<ServicePerson>? assignedMechanics,
    this.appointmentActionIds = const {},
    required this.serviceObjectTag,
    required this.serviceObjectDescription,
    required this.serviceType,
    required this.location,
    required this.relationName,
    this.serviceContractId,
    this.productionOrderId,
    this.serviceObjectId,
  }) : _assignedMechanics = assignedMechanics;

  factory ServiceOrder.fromJson(Map<String, dynamic> json) {
    final mechJson = json['servicemechanic'] as Map<String, dynamic>?;
    final objectJson = json['serviceobject'] as Map<String, dynamic>?;
    final typeJson = json['servicetype'] as Map<String, dynamic>?;
    final stateJson = json['workflowstate'] as Map<String, dynamic>?;
    final orderJson = json['order'] as Map<String, dynamic>?;
    final locationJson = json['objectlocation'] as Map<String, dynamic>?;
    final relationJson = json['relation'] as Map<String, dynamic>?;
    final contractJson = json['servicecontract'] as Map<String, dynamic>?;

    return ServiceOrder(
      id: json['id'].toString(),
      recordTag: json['recordtag'] as String? ?? '',
      orderNumber: orderJson?['recordtag'] as String? ?? '',
      description: json['description'] as String? ?? '',
      startDate: _parseIsoDate(json['startdate']),
      endTime: _parseIsoDate(json['endtime']),
      deliveryDate: _parseIsoDate(json['deliverydate']),
      workflowState: stateJson?['state'] as String? ?? 'Nieuw',
      mechanic: mechJson != null ? ServicePerson.fromJson(mechJson) : null,
      serviceObjectTag: objectJson?['recordtag'] as String? ?? '',
      serviceObjectDescription: objectJson?['description'] as String? ?? '',
      serviceType: typeJson?['description'] as String? ?? '',
      location:
          locationJson?['name'] as String? ??
          json['addresslocation'] as String? ??
          '',
      relationName:
          relationJson?['name'] as String? ??
          relationJson?['recordtag'] as String? ??
          '',
      serviceContractId: contractJson?['id']?.toString(),
      productionOrderId: orderJson?['id']?.toString(),
      serviceObjectId: objectJson?['id']?.toString(),
    );
  }

  ServiceOrder copyWith({
    String? relationName,
    List<ServicePerson>? assignedMechanics,
    Set<int>? appointmentActionIds,
  }) => ServiceOrder(
    id: id,
    recordTag: recordTag,
    orderNumber: orderNumber,
    description: description,
    startDate: startDate,
    endTime: endTime,
    deliveryDate: deliveryDate,
    workflowState: workflowState,
    mechanic: mechanic,
    assignedMechanics: assignedMechanics ?? _assignedMechanics,
    appointmentActionIds: appointmentActionIds ?? this.appointmentActionIds,
    serviceObjectTag: serviceObjectTag,
    serviceObjectDescription: serviceObjectDescription,
    serviceType: serviceType,
    location: location,
    relationName: relationName ?? this.relationName,
    serviceContractId: serviceContractId,
    productionOrderId: productionOrderId,
    serviceObjectId: serviceObjectId,
  );

  /// Date used to position this order in the day view.
  @override
  DateTime? get planningDate => startDate ?? deliveryDate;

  @override
  bool isAssignedTo(int mechanicId) =>
      assignedMechanics.any((m) => m.id == mechanicId);

  @override
  String get title => description.isNotEmpty ? description : orderNumber;

  @override
  String? get subtitle =>
      orderNumber.isNotEmpty && orderNumber != title ? orderNumber : null;
}

/// A CRM appointment (agenda-item), e.g. synced from an employee's Outlook
/// calendar. Fetched from the `/crm/appointments` endpoint, separate from
/// the `/production/joborders` (servicebonnen) that make up [ServiceOrder].
class Appointment implements PlanningItem {
  final String id;
  final String description;
  final DateTime? start;
  final DateTime? end;
  final ServicePerson? employee;
  final String workflowState;
  final bool allDay;

  /// The `/crm/appointmentactions` record this appointment belongs to —
  /// shared by every mechanic's appointment for the same job order.
  final int? appointmentActionId;

  const Appointment({
    required this.id,
    required this.description,
    required this.start,
    required this.end,
    required this.employee,
    required this.workflowState,
    required this.allDay,
    this.appointmentActionId,
  });

  factory Appointment.fromJson(Map<String, dynamic> json) {
    final employeeJson = json['employee'] as Map<String, dynamic>?;
    final actionJson = json['appointmentaction'] as Map<String, dynamic>?;
    final stateJson = json['workflowstate'] as Map<String, dynamic>?;
    final subject = actionJson?['description'] as String?;
    final fallback = json['recordtag'] as String? ?? 'Afspraak';

    return Appointment(
      id: json['id'].toString(),
      description: (subject != null && subject.isNotEmpty) ? subject : fallback,
      start: _parseIsoDate(json['start']),
      end: _parseIsoDate(json['end']),
      employee: employeeJson != null
          ? ServicePerson.fromJson(employeeJson)
          : null,
      workflowState: stateJson?['state'] as String? ?? '',
      allDay: json['alldayevent'] as bool? ?? false,
      appointmentActionId: actionJson?['id'] as int?,
    );
  }

  @override
  DateTime? get planningDate => start;

  @override
  DateTime? get endTime => end;

  @override
  bool isAssignedTo(int mechanicId) => employee?.id == mechanicId;

  @override
  String get title => description;

  @override
  String? get subtitle => null;
}
