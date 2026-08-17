import 'package:dio/dio.dart';

import '../../../core/api/api_client.dart';
import '../data/planning_repository.dart' show workActivityIdWork;
import '../models/job_order_lines.dart';

/// Top-level keys on the job order JSON that this service reads/writes.
/// Everything else on the object is passed through untouched.
///
/// Confirmed against the Swagger/OpenAPI schema for "ECI Service Remote"
/// (2026-08-05): the job order has BOTH an `employees` array (day+employee
/// assignment/appointment link — `jobOrder`, `employee`, `date`,
/// `appointmentActionId`, no duration) AND a separate `hours` array (actual
/// worked time + server-computed pricing). Flow 2 ("uren invullen") writes
/// to `hours`; `employees` is left untouched by this service.
class JobOrderKeys {
  static const hours = 'hours';
  static const detailItems = 'detailItems';
  // `employees` and `detailMisc` also exist on the job order but aren't
  // touched by either flow implemented here.
}

/// Service layer for the Ridder iQ "Service Remote" job order endpoint.
///
/// There is no partial-update endpoint for hours/material: a job order is
/// always mutated by GET → edit the in-memory JSON → POST the whole object
/// back (last-write-wins). [_getMutatePost] is the one place that pattern
/// lives; both flows below call it instead of hand-rolling GET/POST pairs.
class JobOrderService {
  JobOrderService._();
  static final JobOrderService instance = JobOrderService._();

  final _dio = ApiClient.instance.serviceRemoteDio;

  Future<Map<String, dynamic>> _getJobOrder(String jobOrderId) async {
    final response = await _dio.get('/ServiceRemote/JobOrder/$jobOrderId');
    return response.data as Map<String, dynamic>;
  }

  /// GET → mutate → POST helper shared by both flows.
  ///
  /// [mutate] receives the freshly-fetched job order JSON and edits it in
  /// place (or returns a new map); whatever it returns is POSTed back
  /// verbatim. Fetching right before mutating minimizes — but, since this
  /// is last-write-wins, does not eliminate — the window in which another
  /// user's concurrent edit could be overwritten.
  ///
  /// Confirmed (Swagger): `POST /ServiceRemote/JobOrder/{id}` returns a
  /// bare boolean on success (`true`) — not the updated job order — and a
  /// string on a 500. So this always re-GETs afterwards; there is no way to
  /// read server-assigned ids (e.g. for newly-added lines) straight from
  /// the POST response. Throws if the POST didn't report success.
  Future<Map<String, dynamic>> _getMutatePost(
    String jobOrderId,
    Map<String, dynamic> Function(Map<String, dynamic> jobOrder) mutate,
  ) async {
    final current = await _getJobOrder(jobOrderId);
    final updated = mutate(current);

    final response = await _dio.post(
      '/ServiceRemote/JobOrder/$jobOrderId',
      data: updated,
    );

    if (response.data != true) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        error: 'POST /ServiceRemote/JobOrder/$jobOrderId did not return '
            'true (got: ${response.data})',
      );
    }

    return _getJobOrder(jobOrderId);
  }

  // ─── Flow 1: pick-scherm "bevestigen en afsluiten" ──────────────────────

  /// Adds [newLines] to the job order's `detailItems` and reposts the whole
  /// job order. This is plain "materiaal toevoegen" — no separate
  /// registration object is created. Build [newLines] with
  /// [JobOrderDetailItemLine.newPart]; leave `id` unset (confirmed: an
  /// omitted/zero id means "new record, let the server autonumber").
  Future<List<JobOrderDetailItemLine>> addDetailItems(
    String jobOrderId,
    List<JobOrderDetailItemLine> newLines,
  ) async {
    final updated = await _getMutatePost(jobOrderId, (jobOrder) {
      final existing =
          (jobOrder[JobOrderKeys.detailItems] as List<dynamic>?) ?? [];
      jobOrder[JobOrderKeys.detailItems] = [
        ...existing,
        ...newLines.map((l) => l.toJson()),
      ];
      return jobOrder;
    });

    return _detailItemLines(updated);
  }

  // ─── Flow 2: uren-scherm ─────────────────────────────────────────────────

  /// Saves [duration] worked by [employeeId] on [date]: updates the
  /// existing `hours` line for that day+employee if one exists, otherwise
  /// appends a new one. There is at most one hours line per day+employee.
  ///
  /// Deliberately does not use the standalone hour-registration endpoint —
  /// that endpoint can create lines but not update an existing one, which
  /// would produce duplicate lines for the same day.
  ///
  /// [km] is accepted for forward-compatibility but should be left `null`
  /// for now — see [JobOrderHoursLine.km]. [duration] itself is UNCONFIRMED
  /// — see [HoursLineKeys.totalTime]/[HoursLineKeys.timeEmployee] — until a
  /// sample response with actual worked hours on a line has been seen,
  /// calling this may silently fail to persist the duration even though the
  /// request succeeds.
  Future<List<JobOrderHoursLine>> upsertHoursLine(
    String jobOrderId, {
    required DateTime date,
    required int employeeId,
    required Duration duration,
    double? km,
  }) async {
    final jobOrderIdInt = int.parse(jobOrderId);

    final updated = await _getMutatePost(jobOrderId, (jobOrder) {
      final existingRaw =
          (jobOrder[JobOrderKeys.hours] as List<dynamic>?) ?? [];
      final existingLines = existingRaw
          .map((e) => JobOrderHoursLine.fromJson(e as Map<String, dynamic>))
          .toList();

      final matchIndex = existingLines.indexWhere(
        (line) => isSameDayAndEmployee(
          line,
          date: date,
          employeeId: employeeId,
        ),
      );

      if (matchIndex == -1) {
        final newLine = JobOrderHoursLine(
          employeeId: employeeId,
          jobOrderId: jobOrderIdInt,
          start: date,
          // TODO: verifiëren of `workActivityId` verplicht is voor een
          // nieuwe hours-regel op deze /v1 API, en of dezelfde id's als de
          // v2 `/hours/projecttimes`-flow gelden.
          workActivityId: workActivityIdWork,
          duration: duration,
          km: km,
        );
        jobOrder[JobOrderKeys.hours] = [...existingRaw, newLine.toJson()];
      } else {
        final updatedLine = existingLines[matchIndex].copyWith(
          duration: duration,
          km: km,
        );
        final newRawList = List<dynamic>.from(existingRaw);
        newRawList[matchIndex] = updatedLine.toJson();
        jobOrder[JobOrderKeys.hours] = newRawList;
      }

      return jobOrder;
    });

    return _hoursLines(updated);
  }

  List<JobOrderHoursLine> _hoursLines(Map<String, dynamic> jobOrder) {
    final raw = (jobOrder[JobOrderKeys.hours] as List<dynamic>?) ?? [];
    return raw
        .map((e) => JobOrderHoursLine.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  List<JobOrderDetailItemLine> _detailItemLines(
    Map<String, dynamic> jobOrder,
  ) {
    final raw = (jobOrder[JobOrderKeys.detailItems] as List<dynamic>?) ?? [];
    return raw
        .map(
          (e) => JobOrderDetailItemLine.fromJson(e as Map<String, dynamic>),
        )
        .toList();
  }
}

/// Determines whether an existing [line] represents the same day+employee
/// as the ([date], [employeeId]) being saved — i.e. "is this the one hours
/// line we should update, instead of appending a new one".
///
/// TODO: verifiëren tegen echte GET-response met ingevulde uren. Aannames
/// die nog bevestigd moeten worden:
///   - dat de matchsleutel echt (datumcomponent van [HoursLineKeys.start],
///     employeeId) is, en niet bijvoorbeeld iets dat rekening houdt met
///     `end` of met `workActivityId` (bv. per uursoort een eigen regel per
///     dag, in plaats van één regel per dag totaal);
///   - dat [HoursLineKeys.start] voor dit doel puur als datumdrager
///     fungeert (vandaar de `year/month/day`-vergelijking hieronder) in
///     plaats van een echte begin-werktijd die per keer kan verschillen.
/// Aanpassen: pas alleen de body van deze functie aan, de call sites hoeven
/// niet te wijzigen.
bool isSameDayAndEmployee(
  JobOrderHoursLine line, {
  required DateTime date,
  required int employeeId,
}) {
  if (line.employeeId != employeeId) return false;
  final lineDate = line.start;
  if (lineDate == null) return false;
  return lineDate.year == date.year &&
      lineDate.month == date.month &&
      lineDate.day == date.day;
}
