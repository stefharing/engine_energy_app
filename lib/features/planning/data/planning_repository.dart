import 'dart:typed_data';
import 'package:dio/dio.dart' show Options, ResponseType;
import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_config.dart';
import '../models/job_order.dart';

// Vaste uursoort-id's, alleen nog gebruikt door de oude
// `/hours/projecttimes`-flow ([PlanningRepository.createProjectTime]).
// LET OP: id's verschillen per Ridder-administratie (in live is 20
// "ZSRV-ABR" en 24 "SRV-NL"). De urenregistratie in de app gebruikt daarom
// `WorkActivityCatalog`, dat uursoorten op code opzoekt.
const workActivityIdWork = 20;
const workActivityIdTravel = 24;
const _wagegroupId = 1;

/// Adds every mechanic assigned to each job order in [orders].
///
/// A job order's own `servicemechanic` holds only one mechanic. Assigning
/// more in Ridder creates an `/crm/appointmentactions` record linked to the
/// job order ([actions], `joborder.id`), with one `/crm/appointments`
/// record per mechanic ([appointments], `appointmentaction.id` +
/// `employee`). That's the same list Service Remote returns as a job
/// order's `employees[]`. `servicemechanic` stays first; the rest follow
/// sorted by name.
List<ServiceOrder> applyJobOrderAssignments(
  List<ServiceOrder> orders, {
  required List<Map<String, dynamic>> actions,
  required List<Map<String, dynamic>> appointments,
}) {
  final jobOrderByAction = <int, String>{};
  for (final a in actions) {
    final actionId = a['id'] as int?;
    final jobOrderId = (a['joborder'] as Map<String, dynamic>?)?['id'];
    if (actionId != null && jobOrderId != null) {
      jobOrderByAction[actionId] = jobOrderId.toString();
    }
  }

  final mechanicsByJobOrder = <String, Map<int, ServicePerson>>{};
  final actionsByJobOrder = <String, Set<int>>{};
  for (final entry in jobOrderByAction.entries) {
    actionsByJobOrder.putIfAbsent(entry.value, () => {}).add(entry.key);
  }
  for (final appt in appointments) {
    final actionId =
        (appt['appointmentaction'] as Map<String, dynamic>?)?['id'] as int?;
    final jobOrderId = jobOrderByAction[actionId];
    final employee = appt['employee'] as Map<String, dynamic>?;
    if (jobOrderId == null || employee == null) continue;
    final person = ServicePerson.fromJson(employee);
    mechanicsByJobOrder.putIfAbsent(jobOrderId, () => {})[person.id] = person;
  }

  return orders.map((order) {
    final actionIds = actionsByJobOrder[order.id];
    if (actionIds == null) return order;
    final others =
        (mechanicsByJobOrder[order.id]?.values ?? const <ServicePerson>[])
            .where((m) => m.id != order.mechanic?.id)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    return order.copyWith(
      appointmentActionIds: actionIds,
      assignedMechanics: [?order.mechanic, ...others],
    );
  }).toList();
}

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

  /// Boekt indirecte uren (uren die niet op een bon staan) voor [date]:
  /// een projecttijd met alleen medewerker en uursoort, zonder `joborder`
  /// en `order`. [workActivityId] is het id van de uursoort "Indirecte
  /// uren" (zie [WorkActivityCatalog.indirect]).
  Future<void> createIndirectProjectTime({
    required DateTime date,
    required int employeeId,
    required int workActivityId,
    required Duration duration,
  }) async {
    final timeStr = _formatDuration(duration);
    await _dio.post(
      '/hours/projecttimes',
      data: {
        'date': _isoLocalMidnight(date),
        'employee': {'id': employeeId},
        'wagegroup': {'id': _wagegroupId},
        'workactivity': {'id': workActivityId},
        'operationorsetup': {'choicenumber': 1},
        'timedevice': timeStr,
        'timeemployee': timeStr,
      },
    );
  }

  /// Alle projecttijden van [employeeId] vanaf [from] (op datum, nieuwste
  /// eerst). Het filter op medewerker gebeurt door Ridder zelf, zodat een
  /// medewerker nooit uren van een ander te zien krijgt.
  Future<List<Map<String, dynamic>>> fetchProjectTimesForEmployee(
    int employeeId, {
    required DateTime from,
  }) async {
    const size = 200;
    final start = DateTime(from.year, from.month, from.day);
    final all = <Map<String, dynamic>>[];
    for (var page = 1; ; page++) {
      final response = await _dio.get(
        '/hours/projecttimes',
        queryParameters: {
          'page': page,
          'size': size,
          'sort': 'date.desc',
          'filter': 'employee.id[eq]$employeeId',
        },
      );
      final data = (response.data['data'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      for (final entry in data) {
        // Voor de zekerheid nogmaals controleren op eigenaar.
        if ((entry['employee'] as Map?)?['id'] != employeeId) continue;
        final datum = DateTime.tryParse(entry['date'] as String? ?? '');
        if (datum == null || datum.isBefore(start)) continue;
        all.add(entry);
      }
      final oudste = data.isEmpty
          ? null
          : DateTime.tryParse(data.last['date'] as String? ?? '');
      if (data.length < size || (oudste != null && oudste.isBefore(start))) {
        return all;
      }
    }
  }

  /// De projecttijden zonder bon met een uursoort uit [codes] (indirecte
  /// uren, overnachting) van [employeeId] vanaf [from].
  Future<List<Map<String, dynamic>>> fetchIndirectProjectTimes(
    int employeeId, {
    required DateTime from,
    required Set<String> codes,
  }) async {
    final hoofd = codes.map((c) => c.toUpperCase()).toSet();
    final alle = await fetchProjectTimesForEmployee(employeeId, from: from);
    return [
      for (final e in alle)
        if (e['joborder'] == null &&
            hoofd.contains(
              ((e['workactivity'] as Map?)?['code'] as String? ?? '')
                  .trim()
                  .toUpperCase(),
            ))
          e,
    ];
  }

  /// Past datum en duur van een bestaande projecttijd aan.
  Future<void> updateProjectTime({
    required int id,
    required DateTime date,
    required Duration duration,
  }) async {
    final timeStr = _formatDuration(duration);
    await _dio.put(
      '/hours/projecttimes/$id',
      data: {
        'id': id,
        'date': _isoLocalMidnight(date),
        'timedevice': timeStr,
        'timeemployee': timeStr,
      },
    );
  }

  Future<void> deleteProjectTime(int id) async {
    await _dio.delete('/hours/projecttimes/$id');
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

  /// Every record of a list endpoint matching [filter], across all pages.
  Future<List<Map<String, dynamic>>> _fetchAllPages(
    String path, {
    required String filter,
  }) async {
    const size = 200;
    final all = <Map<String, dynamic>>[];
    for (var page = 1; ; page++) {
      final response = await _dio.get(
        path,
        queryParameters: {'page': page, 'size': size, 'filter': filter},
      );
      final data = (response.data['data'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      all.addAll(data);
      if (data.length < size) return all;
    }
  }

  /// Job orders, each with all of its assigned mechanics (see
  /// [applyJobOrderAssignments]). If the assignments can't be loaded, the
  /// orders are still returned with just their `servicemechanic`.
  Future<List<ServiceOrder>> fetchServiceOrders() async {
    final ordersFuture = _dio.get(
      '/production/joborders',
      queryParameters: {'page': 1, 'size': 200, 'sort': 'startdate.asc'},
    );
    final assignmentsFuture = Future.wait([
      _fetchAllPages('/crm/appointmentactions', filter: 'joborder.id[gt]0'),
      _fetchAllPages(
        '/crm/appointments',
        filter: 'appointmentaction.joborder.id[gt]0',
      ),
    ]);
    final response = await ordersFuture;
    final data = response.data['data'] as List<dynamic>;
    final orders = data
        .map((e) => ServiceOrder.fromJson(e as Map<String, dynamic>))
        .toList();
    try {
      final assignments = await assignmentsFuture;
      return applyJobOrderAssignments(
        orders,
        actions: assignments[0],
        appointments: assignments[1],
      );
    } catch (e) {
      debugPrint('[planning] loading job order assignments failed: $e');
      return orders;
    }
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

  /// Documenten die aan een serviceobject hangen (nieuwste eerst). Gooit bij
  /// een fout, zodat het scherm "geen documenten" kan onderscheiden van
  /// "kon niet laden". De API geeft een kale lijst; `{data: [...]}` wordt
  /// ook geaccepteerd.
  Future<List<Map<String, dynamic>>> fetchServiceObjectDocuments(
    String serviceObjectId,
  ) async {
    final response = await _dio.get(
      '/service/serviceobjects/$serviceObjectId/documents',
      queryParameters: {'page': 1, 'size': 200},
    );
    final raw = response.data;
    final lijst = raw is List ? raw : (raw is Map ? raw['data'] : null);
    final docs = (lijst as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .toList();
    docs.sort(
      (a, b) => (b['datecreated']?.toString() ?? '').compareTo(
        a['datecreated']?.toString() ?? '',
      ),
    );
    return docs;
  }

  /// Aantal documenten van een serviceobject; null bij een fout (in
  /// tegenstelling tot 0), zodat de knop dan gewoon "Documenten" toont.
  Future<int?> fetchServiceObjectDocumentCount(String serviceObjectId) async {
    try {
      return (await fetchServiceObjectDocuments(serviceObjectId)).length;
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, dynamic>> _lijstUit(dynamic raw) {
    final lijst = raw is List ? raw : (raw is Map ? raw['data'] : null);
    return (lijst as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .toList();
  }

  /// Alle bonnen (job orders) van een serviceobject, nieuwste eerst — de
  /// historie van het object. Gooit bij een fout.
  Future<List<Map<String, dynamic>>> fetchServiceObjectHistory(
    String serviceObjectId,
  ) async {
    final response = await _dio.get(
      '/production/joborders',
      queryParameters: {
        'page': 1,
        'size': 200,
        'sort': 'startdate.desc',
        'filter': 'serviceobject.id[eq]$serviceObjectId',
      },
    );
    return _lijstUit(response.data);
  }

  /// Gewerkte uren op één bon (alle monteurs). Gooit bij een fout.
  Future<List<Map<String, dynamic>>> fetchJobOrderHours(
    String jobOrderId,
  ) async {
    final response = await _dio.get(
      '/hours/projecttimes',
      queryParameters: {
        'page': 1,
        'size': 200,
        'filter': 'joborder.id[eq]$jobOrderId',
      },
    );
    return _lijstUit(response.data);
  }

  /// Regels (onderdelen, kilometers) op één bon. Gooit bij een fout.
  Future<List<Map<String, dynamic>>> fetchJobOrderParts(
    String jobOrderId,
  ) async {
    final response = await _dio.get(
      '/production/joborderdetails',
      queryParameters: {
        'page': 1,
        'size': 200,
        'filter': 'joborder.id[eq]$jobOrderId',
      },
    );
    return _lijstUit(
      response.data,
    ).where((e) => e['joborderdetailitem'] != null).toList();
  }

  final Map<String, int?> _stuksEenheidPerAdmin = {};

  /// Id van de eenheid "Stuks" (`/itemmanagement/itemunits`, code `STUKS`) in
  /// de actieve administratie — de ids verschillen per administratie, dus
  /// opzoeken op code. Null als er geen is of het ophalen mislukt; dan blijft
  /// de eenheid van een diverse regel leeg, zoals voorheen.
  Future<int?> fetchStuksUnitId() async {
    final admin = ApiConfig.administrationId;
    if (_stuksEenheidPerAdmin.containsKey(admin)) {
      return _stuksEenheidPerAdmin[admin];
    }
    try {
      final response = await _dio.get(
        '/itemmanagement/itemunits',
        queryParameters: {'page': 1, 'size': 200},
      );
      final raw = response.data;
      final lijst =
          (raw is List ? raw : (raw is Map ? raw['data'] : null))
              as List<dynamic>? ??
          const [];
      final units = lijst.cast<Map<String, dynamic>>();
      Map<String, dynamic>? gekozen;
      for (final u in units) {
        if ((u['code']?.toString().toUpperCase() ?? '') == 'STUKS') {
          gekozen = u;
          break;
        }
      }
      gekozen ??= units.cast<Map<String, dynamic>?>().firstWhere(
        (u) => (u?['description']?.toString().toLowerCase() ?? '') == 'stuks',
        orElse: () => null,
      );
      final id = gekozen?['id'] as int?;
      _stuksEenheidPerAdmin[admin] = id;
      return id;
    } catch (e) {
      debugPrint('[eenheden] ophalen mislukt: $e');
      return null;
    }
  }

  /// De bytes van een document (Ridder `/iqsystem/documents/{id}/document`).
  Future<Uint8List> downloadDocument(String documentId) async {
    final response = await _dio.get<List<int>>(
      '/iqsystem/documents/$documentId/document',
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data ?? const []);
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

  /// Exact-code catalog lookup — unlike [searchPartsByCode] this can't miss
  /// a short code like "KM" behind 25 other codes that merely contain it.
  Future<Map<String, dynamic>?> fetchItemByCode(String code) async {
    final response = await _dio.get(
      '/itemmanagement/items',
      queryParameters: {'page': 1, 'size': 1, 'filter': 'code[eq]"$code"'},
    );
    final data = response.data['data'] as List<dynamic>?;
    if (data == null || data.isEmpty) return null;
    return data.first as Map<String, dynamic>;
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
