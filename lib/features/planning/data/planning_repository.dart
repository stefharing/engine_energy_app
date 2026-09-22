import '../../../core/api/api_client.dart';
import '../models/job_order.dart';

// Tenant-specific `/workactivity/workactivities` record ids (this
// administration only has one tenant, so these are hardcoded rather than
// looked up at runtime — see id=20 "SRV-NL" and id=24 "TRAV-H" in that list).
// Kilometer registration (TRAV-KM, id=25) isn't wired up yet: its
// timedevice/timeemployee values don't decode to a plain distance in any
// of the existing records, so the real input format still needs to be
// confirmed against a manually-entered example in Ridder IQ itself.
const workActivityIdWork = 20;
const workActivityIdTravel = 24;
const _wagegroupId = 1;

class WorkActivityOption {
  final int id;
  final String label;
  const WorkActivityOption(this.id, this.label);
}

/// Selectable "werktijd" uursoorten (all tenant-configured `workactivity`
/// records with `workactivitytype` "Directe uren" that represent actual
/// worked time — travel (TRAV-H) and mileage (TRAV-KM) are excluded since
/// those are wired to their own dedicated columns).
const workActivityOptions = [
  WorkActivityOption(workActivityIdWork, 'Service NL (Standaard)'),
  WorkActivityOption(23, 'Service Abroad (Dagtarief)'),
  WorkActivityOption(21, 'Overwerk NL (1) - >8u of zat.'),
  WorkActivityOption(22, 'Overwerk NL (2) - zon/feestdag'),
  WorkActivityOption(26, 'Machinale bewerkingen'),
];

class PlanningRepository {
  PlanningRepository._();
  static final PlanningRepository instance = PlanningRepository._();

  final _dio = ApiClient.instance.dio;

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  static String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    return '${_pad2(hours)}:${_pad2(minutes)}:00';
  }

  static String _isoLocalMidnight(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    return '${d.year.toString().padLeft(4, '0')}-${_pad2(d.month)}-${_pad2(d.day)}T00:00:00';
  }

  /// Writes a single hour registration (werktijd or reistijd) for [date],
  /// linked to [joborderId]/[orderId] and [employeeId]. Use
  /// [workActivityIdWork] or [workActivityIdTravel] for [workActivityId].
  /// `order` is required by Ridder for "directe uren" — it's not enough to
  /// send `joborder` alone.
  Future<void> createProjectTime({
    required DateTime date,
    required int employeeId,
    required int joborderId,
    required int orderId,
    required int workActivityId,
    required Duration duration,
  }) async {
    final timeStr = _formatDuration(duration);
    await _dio.post(
      '/hours/projecttimes',
      data: {
        'date': _isoLocalMidnight(date),
        'employee': {'id': employeeId},
        'joborder': {'id': joborderId},
        'order': {'id': orderId},
        'wagegroup': {'id': _wagegroupId},
        'workactivity': {'id': workActivityId},
        'operationorsetup': {'choicenumber': 1},
        'timedevice': timeStr,
        'timeemployee': timeStr,
      },
    );
  }

  /// Looks up the `/itemmanagement/itemsinwarehouse` record id for [itemId]
  /// — the FK every write against a job order line needs, but which item
  /// search results don't include directly.
  Future<int?> fetchItemWarehouseId(int itemId) async {
    final response = await _dio.get(
      '/itemmanagement/itemsinwarehouse',
      queryParameters: {'page': 1, 'size': 1, 'filter': 'item.id[eq]$itemId'},
    );
    final data = response.data['data'] as List<dynamic>?;
    if (data == null || data.isEmpty) return null;
    return (data.first as Map<String, dynamic>)['id'] as int?;
  }

  Map<String, dynamic> _extraPartPayload({
    required int itemId,
    required int itemWarehouseId,
    required int joborderId,
    required int orderId,
    required double quantity,
    int sawingCodeChoiceNumber = 1,
    String? memo,
  }) => {
    'allocatedone': false,
    'batchdependent': false,
    'deliverymethod': {'choicenumber': 1},
    'fixedwaste': false,
    'item': {'id': itemId},
    'itemwarehouse': {'id': itemWarehouseId},
    'joborder': {'id': joborderId},
    'order': {'id': orderId},
    'preproduction': false,
    'quantity': quantity,
    'registrationpath': {'choicenumber': 5},
    'rotation': {'choicenumber': 5},
    'sawingcode': {'choicenumber': sawingCodeChoiceNumber},
    'stockaspurchase': false,
    'stockcompleted': true,
    'memo': ?memo,
  };

  /// Adds a new material line to a job order's material list for a part
  /// picked in the field that wasn't on the original office-planned list.
  /// This does NOT touch the stock ledger — `/stock/stockouts`/`stockins`
  /// are the only endpoints that move real inventory; this just extends the
  /// order's own material list. Returns the new line's id so the caller can
  /// update it later instead of creating a duplicate.
  Future<int> createJobOrderExtraPart({
    required int itemId,
    required int itemWarehouseId,
    required int joborderId,
    required int orderId,
    required double quantity,
    int sawingCodeChoiceNumber = 1,
    String? memo,
  }) async {
    final response = await _dio.post(
      '/production/joborderdetailsitem',
      data: _extraPartPayload(
        itemId: itemId,
        itemWarehouseId: itemWarehouseId,
        joborderId: joborderId,
        orderId: orderId,
        quantity: quantity,
        sawingCodeChoiceNumber: sawingCodeChoiceNumber,
        memo: memo,
      ),
    );
    return response.data['id'] as int;
  }

  /// Updates the quantity (and other fields) of a previously-created extra
  /// part line, identified by [id] (the id returned by
  /// [createJobOrderExtraPart]) — avoids creating a duplicate line when the
  /// mechanic changes their mind about how many they picked.
  Future<void> updateJobOrderExtraPart({
    required int id,
    required int itemId,
    required int itemWarehouseId,
    required int joborderId,
    required int orderId,
    required double quantity,
    int sawingCodeChoiceNumber = 1,
    String? memo,
  }) async {
    await _dio.put(
      '/production/joborderdetailsitem/$id',
      data: _extraPartPayload(
        itemId: itemId,
        itemWarehouseId: itemWarehouseId,
        joborderId: joborderId,
        orderId: orderId,
        quantity: quantity,
        sawingCodeChoiceNumber: sawingCodeChoiceNumber,
        memo: memo,
      ),
    );
  }

  Future<List<ServiceOrder>> fetchServiceOrders() async {
    final response = await _dio.get(
      '/production/joborders',
      queryParameters: {'page': 1, 'size': 200, 'sort': 'startdate.asc'},
    );
    final data = response.data['data'] as List<dynamic>;
    return data
        .map((e) => ServiceOrder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Appointment>> fetchAppointments() async {
    final response = await _dio.get(
      '/crm/appointments',
      queryParameters: {'page': 1, 'size': 200, 'sort': 'start.asc'},
    );
    final data = response.data['data'] as List<dynamic>;
    return data
        .map((e) => Appointment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchProjectTimes(
    String joborderId,
  ) async {
    final response = await _dio.get(
      '/hours/projecttimes',
      queryParameters: {
        'page': 1,
        'size': 200,
        'filter': 'joborder.id[eq]$joborderId',
      },
    );
    final data = response.data['data'] as List<dynamic>?;
    if (data == null) return [];
    return data.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>?> fetchProductionOrder(String id) async {
    try {
      final response = await _dio.get('/production/orders/$id');
      return response.data as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchRelation(String id) async {
    try {
      final response = await _dio.get('/crm/relations/$id');
      return response.data as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchAddress(String id) async {
    try {
      final response = await _dio.get('/crm/addresses/$id');
      return response.data as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchDeliveryAddress(String id) async {
    try {
      final response = await _dio.get(
        '/crm/deliveryaddresses',
        queryParameters: {'page': 1, 'size': 1, 'filter': 'id[eq]$id'},
      );
      final data = response.data['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) return null;
      return data.first as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Fetches the full catalog record for an item, including `itemunit` —
  /// which `/production/joborderdetails`' own embedded `item` subfield
  /// doesn't include, but which [ScannedExtra.unitId] (and thus the `wip`
  /// line built from it) needs.
  Future<Map<String, dynamic>?> fetchItem(int id) async {
    try {
      final response = await _dio.get('/itemmanagement/items/$id');
      return response.data as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchServiceObject(String id) async {
    try {
      final response = await _dio.get('/service/serviceobjects/$id');
      return response.data as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// The maintenance intervals configured for a service object (e.g.
  /// "every 6 months", "every 90 days") — used to compute the next
  /// upcoming maintenance date. Returns an empty list on failure so callers
  /// can treat "no data" and "fetch failed" the same way (silently hide the
  /// "Volgend onderhoud" row).
  Future<List<Map<String, dynamic>>> fetchServiceIntervals(
    String serviceObjectId,
  ) async {
    try {
      final response = await _dio.get(
        '/service/serviceintervals',
        queryParameters: {
          'page': 1,
          'size': 200,
          'filter': 'serviceobject.id[eq]$serviceObjectId',
        },
      );
      final data = response.data['data'] as List<dynamic>?;
      if (data == null) return [];
      return data.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Number of documents attached to a service object. Returns null on
  /// failure (as opposed to 0), so callers can tell "no documents" apart
  /// from "couldn't load" and hide the row rather than show a wrong count.
  Future<int?> fetchServiceObjectDocumentCount(String serviceObjectId) async {
    try {
      final response = await _dio.get(
        '/service/serviceobjects/$serviceObjectId/documents',
      );
      final data = response.data['data'] as List<dynamic>?;
      return data?.length;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchServiceContract(String id) async {
    try {
      final response = await _dio.get('/service/servicecontracts/$id');
      return response.data as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchContact(String id) async {
    try {
      final response = await _dio.get(
        '/crm/contactpersons',
        queryParameters: {'filter': 'id[eq]$id', 'page': 1, 'size': 1},
      );
      final data = response.data['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) return null;
      return data.first as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> searchParts(String query) async {
    try {
      final response = await _dio.get(
        '/itemmanagement/items',
        queryParameters: {
          'page': 1,
          'size': 25,
          'filter': 'description[contains]"$query"',
          'sort': 'description.asc',
        },
      );
      final data = response.data['data'] as List<dynamic>?;
      if (data == null) return [];
      return data.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> searchPartsByCode(String code) async {
    try {
      final response = await _dio.get(
        '/itemmanagement/items',
        queryParameters: {
          'page': 1,
          'size': 25,
          'filter': 'code[contains]"$code"',
          'sort': 'code.asc',
        },
      );
      final data = response.data['data'] as List<dynamic>?;
      if (data == null) return [];
      return data.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<List<ServicePerson>> fetchEmployees() async {
    final response = await _dio.get(
      '/hours/employees',
      queryParameters: {'page': 1, 'size': 200, 'sort': 'recordtag.asc'},
    );
    final data = response.data['data'] as List<dynamic>;
    return data
        .map((e) => e as Map<String, dynamic>)
        .where((e) => (e['code'] as String? ?? '').startsWith('P'))
        .map(
          (e) => ServicePerson(
            id: e['id'] as int,
            name: e['recordtag'] as String? ?? '',
          ),
        )
        .toList();
  }
}
