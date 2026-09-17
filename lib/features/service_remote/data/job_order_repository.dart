import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_service.dart';
import '../models/job_order.dart';
import 'hours_entry_store.dart';
import 'job_order_submission.dart';

// DIAGNOSTIC (2026): temporary-or-keep logging to isolate which call in the
// phase-2 "open job order" flow actually fails. Kept even after the fix
// below, since it's what surfaced it — cheap insurance against the next
// surprise on this API.
String _shortBody(dynamic data) {
  final s = data.toString();
  return s.length > 800 ? '${s.substring(0, 800)}…' : s;
}

bool _is2xx(int? statusCode) =>
    statusCode != null && statusCode >= 200 && statusCode < 300;

/// Ridder's error responses on `POST /ServiceRemote/JobOrder/{id}` are
/// JSON with a `detail` field naming the actual failure (e.g. "Nullable
/// object must have a value." or "Fout tijdens aanmaken .pdf bestand van
/// html") — confirmed via live debugging outside this app. That's the
/// message worth surfacing, not dio's generic "Http status error [500]".
/// Falls back to the raw body, then to [fallback], if the body isn't the
/// expected `{detail: ...}` shape.
String extractErrorDetail(dynamic body, String fallback) {
  if (body is Map && body['detail'] != null) {
    return body['detail'].toString();
  }
  if (body is String && body.isNotEmpty) {
    return body;
  }
  if (body != null) {
    return body.toString();
  }
  return fallback;
}

/// Whether a `POST /ServiceRemote/appointment/{id}` response (used for both
/// the State=5 "open" call and the State=7 "close" call in
/// [JobOrderRepository.submitJobOrder]) counts as success.
///
/// Confirmed via Swagger + live testing (2026-08): unlike
/// `POST /ServiceRemote/JobOrder/{id}` (documented `{type: boolean}`, and
/// which genuinely does return the literal `true` on success — that check
/// is separate and untouched), this endpoint's 200 response schema is only
/// ever `{type: string}`, and a real successful call returns an
/// empty/non-boolean body. So checking `data == true` here — copied over
/// from the JobOrder POST's behavior — was simply wrong, and made every
/// successful open call look like a failure. Status code is the only
/// signal this endpoint gives; don't reintroduce a body check.
bool isAppointmentCallSuccessful(Response<dynamic> response) =>
    _is2xx(response.statusCode);

/// Internal — the raw status/body from a failed appointment State POST,
/// before it's translated into the caller-appropriate public exception
/// ([AppointmentOpenFailed] for the open call, or
/// [JobOrderSubmissionAppointmentCloseFailed] for the close call in
/// [JobOrderRepository.submitJobOrder]).
class _AppointmentStatePostFailed implements Exception {
  const _AppointmentStatePostFailed(this.statusCode, this.body);
  final int? statusCode;
  final Object? body;
  @override
  String toString() => 'status=$statusCode body=$body';
}

class JobOrderRepository {
  JobOrderRepository({Dio? dio})
    : _dio = dio ?? ApiClient.instance.serviceRemoteDio;

  static final instance = JobOrderRepository();
  static const appointmentStateOpen = 5;

  /// Distinct from [appointmentStateOpen] — closes/submits the appointment,
  /// as the last step before posting the job order back. Empirically
  /// confirmed, same "magic constant until more states are documented"
  /// treatment as the open state.
  static const appointmentStateClosing = 7;

  final Dio _dio;
  final Uuid _uuid = const Uuid();

  Future<List<JobOrderSummary>> getActiveJobOrders() async {
    final response = await _dio.get(
      '/ServiceRemote/JobOrder/GetActiveJobOrders',
    );
    final data = response.data;
    if (data is! List) {
      throw StateError('GetActiveJobOrders returned an unexpected response.');
    }
    return data
        .whereType<Map>()
        .map((e) => JobOrderSummary(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<JobOrder> getJobOrderDetail(int jobOrderId) async {
    final url = '/ServiceRemote/JobOrder/$jobOrderId';
    try {
      final response = await _dio.get(
        url,
        queryParameters: {
          'changed': DateTime.now().toUtc().toIso8601String(),
        },
      );
      debugPrint(
        '[diag] GET $url -> ${response.statusCode} '
        'body=${_shortBody(response.data)}',
      );
      if (response.data is! Map) {
        throw JobOrderDetailFetchFailed(response.statusCode, response.data);
      }
      return JobOrder(Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (e) {
      debugPrint(
        '[diag] GET $url FAILED -> status=${e.response?.statusCode} '
        'body=${_shortBody(e.response?.data)} type=${e.type} '
        'message=${e.message}',
      );
      throw JobOrderDetailFetchFailed(e.response?.statusCode, e.response?.data);
    }
  }

  /// Shared by [openAppointment] and [submitJobOrder]'s close step — both
  /// POST to the same endpoint, only [state] differs. Throws
  /// [_AppointmentStatePostFailed] on any non-2xx result (whether via a
  /// thrown [DioException] or, defensively, a non-2xx status that somehow
  /// didn't raise one); callers translate that into their own public
  /// exception type.
  Future<void> _postAppointmentState(int appointmentId, int state) async {
    final url = '/ServiceRemote/appointment/$appointmentId';
    try {
      final response = await _dio.post(
        url,
        queryParameters: {'State': state},
        data: null,
        options: Options(contentType: null),
      );
      debugPrint(
        '[diag] POST $url?State=$state -> ${response.statusCode} '
        'body=${_shortBody(response.data)}',
      );
      if (!isAppointmentCallSuccessful(response)) {
        throw _AppointmentStatePostFailed(response.statusCode, response.data);
      }
    } on DioException catch (e) {
      debugPrint(
        '[diag] POST $url?State=$state FAILED -> '
        'status=${e.response?.statusCode} body=${_shortBody(e.response?.data)} '
        'type=${e.type} message=${e.message}',
      );
      throw _AppointmentStatePostFailed(e.response?.statusCode, e.response?.data);
    }
  }

  Future<bool> openAppointment(int appointmentId) async {
    try {
      await _postAppointmentState(appointmentId, appointmentStateOpen);
      return true;
    } on _AppointmentStatePostFailed catch (e) {
      throw AppointmentOpenFailed(e.statusCode, e.body);
    }
  }

  /// Submits [jobOrder]'s locally-entered hours (phase 5a — hours only, no
  /// signature yet): re-verifies the session, closes [appointmentId], then
  /// POSTs the full job order — including this session's
  /// `HoursEntryStore` entries for it — back to Ridder.
  ///
  /// This is a three-step, non-idempotent sequence against a live record.
  /// Each step can fail independently, and which one failed matters for
  /// debugging, so each throws its own [JobOrderSubmissionException]
  /// subtype instead of a generic error:
  ///  1. [JobOrderSubmissionLoginFailed] — `GET /ServiceRemote/login`
  ///     re-verification (required before every submission, not optional —
  ///     mirrors what the official app does).
  ///  2. [JobOrderSubmissionAppointmentCloseFailed] — closing the
  ///     appointment (`State=7`).
  ///  3. [JobOrderSubmissionPostFailed] — posting the full job order.
  ///
  /// On success, the local hours for [jobOrder] are cleared from
  /// [HoursEntryStore] — they've been sent, so they must not linger as
  /// still-editable local drafts.
  Future<void> submitJobOrder(JobOrder jobOrder, int appointmentId) async {
    final jobOrderId = jobOrder.id;
    if (jobOrderId == null) {
      throw const JobOrderSubmissionPostFailed('Job order has no id.');
    }

    final credentials = AuthService.instance.currentCredentials;
    if (credentials == null) {
      throw const JobOrderSubmissionLoginFailed('Not logged in.');
    }
    try {
      // Step 1 — re-verify the session. Required before every submission,
      // even though we're already logged in; the official app does this
      // too, and it was not optional in practice.
      await AuthService.instance.reverifySession();
    } catch (e) {
      throw JobOrderSubmissionLoginFailed(e.toString());
    }

    try {
      // Step 2 — close the appointment (State=7, distinct from the
      // State=5 used to open it in phase 2). Same endpoint/response shape
      // as openAppointment — see isAppointmentCallSuccessful for why body
      // content isn't checked here either.
      await _postAppointmentState(appointmentId, appointmentStateClosing);
    } on _AppointmentStatePostFailed catch (e) {
      throw JobOrderSubmissionAppointmentCloseFailed(e.toString());
    }
    // DIAGNOSTIC: step 2 is `await`ed above, so this line only runs once
    // the close call's response has actually been received — there is no
    // concurrency/race between step 2 and step 3 to investigate here.
    debugPrint(
      '[diag] submitJobOrder: step 2 (close, State=$appointmentStateClosing) '
      'completed at ${DateTime.now().toIso8601String()}, starting step 3 (POST job order)',
    );

    // DIAGNOSTIC-ONLY re-GET, purely to compare against what's about to be
    // POSTed below — does NOT feed into the outgoing body, no behavior
    // change. Checks whether closing the appointment (State=7) changed
    // employees[]/appointmentActionId server-side, which `jobOrder` (fetched
    // in phase 2, before the close) wouldn't reflect.
    try {
      final freshAfterClose = await getJobOrderDetail(jobOrderId);
      debugPrint(
        '[diag] submitJobOrder: employees[] in `jobOrder` param (from the '
        'phase-2 GET, BEFORE this close — this is what gets POSTed below) = '
        '${jobOrder.raw['employees']}',
      );
      debugPrint(
        '[diag] submitJobOrder: employees[] from a FRESH GET taken '
        'immediately AFTER the close (comparison only, not sent) = '
        '${freshAfterClose.raw['employees']}',
      );
    } catch (e) {
      debugPrint(
        '[diag] submitJobOrder: diagnostic re-GET after close failed (harmless, comparison only): $e',
      );
    }

    // Step 3 — POST the full job order, with this session's local hours.
    // Confirmed via Swagger: THIS endpoint's 200 response really is a bare
    // boolean, so the `data == true` check stays as-is here — do not apply
    // the appointment-endpoint fix above to this call.
    final hours = HoursEntryStore.instance.entriesFor(jobOrderId);
    final body = buildJobOrderSubmission(
      jobOrder: jobOrder,
      appointmentId: appointmentId,
      hours: hours,
      uniqueId: _uuid.v4(),
    );
    // DIAGNOSTIC: the exact employees[] this body is about to send —
    // buildJobOrderSubmission only ever touches uniqueId/appointment/hours/
    // readyForSignature/htmlFile (see its source), so this should be
    // byte-for-byte the same list as `jobOrder.raw['employees']` logged
    // above, just confirming that here on the actual outgoing body too.
    debugPrint(
      '[diag] submitJobOrder: outgoing POST body employees[] = ${body['employees']}',
    );

    bool posted;
    try {
      final response = await _dio.post(
        '/ServiceRemote/JobOrder/$jobOrderId',
        data: body,
      );
      debugPrint(
        '[diag] POST /ServiceRemote/JobOrder/$jobOrderId -> '
        '${response.statusCode} body=${_shortBody(response.data)}',
      );
      posted = response.statusCode == 200 && response.data == true;
    } on DioException catch (e) {
      // A 500 on this endpoint always carries a JSON body with a `detail`
      // field naming the actual failure mode (e.g. a null somewhere in the
      // payload, or a PDF-rendering failure) — that's far more useful for
      // debugging than dio's generic "Http status error [500]" message, so
      // surface it instead.
      debugPrint(
        '[diag] POST /ServiceRemote/JobOrder/$jobOrderId FAILED -> '
        'status=${e.response?.statusCode} body=${_shortBody(e.response?.data)} '
        'message=${e.message}',
      );
      throw JobOrderSubmissionPostFailed(
        'status=${e.response?.statusCode}: '
        '${extractErrorDetail(e.response?.data, e.message ?? e.toString())}',
      );
    } catch (e) {
      throw JobOrderSubmissionPostFailed(e.toString());
    }
    if (!posted) {
      throw const JobOrderSubmissionPostFailed(
        'Job order submission did not return true.',
      );
    }

    HoursEntryStore.instance.markSubmitted(jobOrderId);
  }

  // ─── TEMPORARY EXPERIMENT — remove once the hypothesis below is
  // confirmed or ruled out. NOT part of phase 5a's real shape; do not wire
  // this into the default submit button or treat its presence as phase 5b
  // being "done". ──────────────────────────────────────────────────────

  /// Tests the hypothesis that the live 500 ("Wijzigen afspraak niet
  /// gelukt") on the final JobOrder POST is caused by posting
  /// `readyForSignature: true` with no signature right after the
  /// appointment was closed via State=7 — i.e. that the server requires a
  /// JobOrder body which itself claims to be signed-off once the
  /// appointment is closed, and the previously-confirmed-working shape
  /// outside this app always paired State=7 with `readyForSignature: false`
  /// plus a real signature.
  ///
  /// Runs the identical login → close → POST sequence as [submitJobOrder],
  /// but with `readyForSignature: false` and a minimal placeholder
  /// signature (`{name, email, paths: []}`) instead of the phase-5a
  /// default. If this succeeds where [submitJobOrder] 500s, phase 5a and
  /// 5b are not as cleanly separable as planned — that's a decision to
  /// make deliberately, not something to silently bake in here.
  ///
  /// Deliberately does NOT call `HoursEntryStore.markSubmitted` on
  /// success: this is a diagnostic run against a live record, not a real
  /// submission the mechanic should lose local drafts over.
  Future<void> submitJobOrderWithSignatureExperiment(
    JobOrder jobOrder,
    int appointmentId,
  ) async {
    final jobOrderId = jobOrder.id;
    if (jobOrderId == null) {
      throw const JobOrderSubmissionPostFailed('Job order has no id.');
    }

    final credentials = AuthService.instance.currentCredentials;
    if (credentials == null) {
      throw const JobOrderSubmissionLoginFailed('Not logged in.');
    }
    try {
      await AuthService.instance.reverifySession();
    } catch (e) {
      throw JobOrderSubmissionLoginFailed(e.toString());
    }

    try {
      await _postAppointmentState(appointmentId, appointmentStateClosing);
    } on _AppointmentStatePostFailed catch (e) {
      throw JobOrderSubmissionAppointmentCloseFailed(e.toString());
    }

    final hours = HoursEntryStore.instance.entriesFor(jobOrderId);
    final body = buildJobOrderSubmission(
      jobOrder: jobOrder,
      appointmentId: appointmentId,
      hours: hours,
      uniqueId: _uuid.v4(),
      readyForSignature: false,
      signature: const {
        'name': 'TEST',
        'email': 'test@example.com',
        'paths': [],
      },
    );
    debugPrint(
      '[diag][EXPERIMENT] outgoing body readyForSignature='
      '${body['readyForSignature']} signature=${body['signature']}',
    );

    bool posted;
    try {
      final response = await _dio.post(
        '/ServiceRemote/JobOrder/$jobOrderId',
        data: body,
      );
      debugPrint(
        '[diag][EXPERIMENT] POST /ServiceRemote/JobOrder/$jobOrderId -> '
        '${response.statusCode} body=${_shortBody(response.data)}',
      );
      posted = response.statusCode == 200 && response.data == true;
    } on DioException catch (e) {
      debugPrint(
        '[diag][EXPERIMENT] POST /ServiceRemote/JobOrder/$jobOrderId FAILED -> '
        'status=${e.response?.statusCode} body=${_shortBody(e.response?.data)}',
      );
      throw JobOrderSubmissionPostFailed(
        'status=${e.response?.statusCode}: '
        '${extractErrorDetail(e.response?.data, e.message ?? e.toString())}',
      );
    } catch (e) {
      throw JobOrderSubmissionPostFailed(e.toString());
    }
    if (!posted) {
      throw const JobOrderSubmissionPostFailed(
        'Job order submission did not return true (experiment).',
      );
    }

    debugPrint(
      '[diag][EXPERIMENT] SUCCESS — readyForSignature:false + placeholder '
      'signature avoided the 500. Hypothesis confirmed.',
    );
  }

  /// TEMPORARY EXPERIMENT #3 — remove once this hypothesis is confirmed or
  /// ruled out. NOT part of phase 5a's real shape; do not wire this into
  /// the default submit button.
  ///
  /// Experiments #1 (stale employees[]/appointmentActionId) and #2
  /// (readyForSignature:true with no signature) are both ruled out — the
  /// live 500 ("Wijzigen afspraak niet gelukt") persists regardless of body
  /// content, as long as the JobOrder POST happens after the appointment
  /// was already closed via State=7. This tests whether the ORDER is the
  /// problem: reversed sequence — login → JobOrder POST (normal phase-5a
  /// body, `readyForSignature: true`, no signature, `appointment:
  /// $appointmentId` as usual) → THEN close the appointment (State=7).
  /// If the POST succeeds here, that confirms the JobOrder POST must
  /// happen before closing, not after.
  Future<void> submitJobOrderReversedOrderExperiment(
    JobOrder jobOrder,
    int appointmentId,
  ) async {
    final jobOrderId = jobOrder.id;
    if (jobOrderId == null) {
      throw const JobOrderSubmissionPostFailed('Job order has no id.');
    }

    final credentials = AuthService.instance.currentCredentials;
    if (credentials == null) {
      throw const JobOrderSubmissionLoginFailed('Not logged in.');
    }
    try {
      await AuthService.instance.reverifySession();
    } catch (e) {
      throw JobOrderSubmissionLoginFailed(e.toString());
    }

    // Step "2" (reversed order) — POST the job order FIRST, before closing
    // the appointment. Same body shape as the real submitJobOrder: normal
    // readyForSignature:true, no signature.
    final hours = HoursEntryStore.instance.entriesFor(jobOrderId);
    final body = buildJobOrderSubmission(
      jobOrder: jobOrder,
      appointmentId: appointmentId,
      hours: hours,
      uniqueId: _uuid.v4(),
    );
    debugPrint(
      '[diag][EXPERIMENT3] posting JobOrder BEFORE closing the appointment '
      '(appointment=$appointmentId still open at this point)',
    );

    bool posted;
    try {
      final response = await _dio.post(
        '/ServiceRemote/JobOrder/$jobOrderId',
        data: body,
      );
      debugPrint(
        '[diag][EXPERIMENT3] POST /ServiceRemote/JobOrder/$jobOrderId -> '
        '${response.statusCode} body=${_shortBody(response.data)}',
      );
      posted = response.statusCode == 200 && response.data == true;
    } on DioException catch (e) {
      debugPrint(
        '[diag][EXPERIMENT3] POST /ServiceRemote/JobOrder/$jobOrderId FAILED '
        '(before close) -> status=${e.response?.statusCode} '
        'body=${_shortBody(e.response?.data)}',
      );
      throw JobOrderSubmissionPostFailed(
        'status=${e.response?.statusCode}: '
        '${extractErrorDetail(e.response?.data, e.message ?? e.toString())}',
      );
    } catch (e) {
      throw JobOrderSubmissionPostFailed(e.toString());
    }
    if (!posted) {
      throw const JobOrderSubmissionPostFailed(
        'Job order submission did not return true (experiment #3, before close).',
      );
    }
    debugPrint(
      '[diag][EXPERIMENT3] JobOrder POST succeeded BEFORE the close — '
      'now closing the appointment (State=7).',
    );

    // Step "3" (reversed order) — close the appointment AFTER the POST
    // succeeded.
    try {
      await _postAppointmentState(appointmentId, appointmentStateClosing);
    } on _AppointmentStatePostFailed catch (e) {
      debugPrint(
        '[diag][EXPERIMENT3] close AFTER successful POST FAILED -> $e',
      );
      throw JobOrderSubmissionAppointmentCloseFailed(e.toString());
    }

    debugPrint(
      '[diag][EXPERIMENT3] SUCCESS — both the JobOrder POST and the '
      'subsequent close succeeded with the reversed order.',
    );
    HoursEntryStore.instance.markSubmitted(jobOrderId);
  }
}

/// Failure fetching the job order detail
/// (`GET /ServiceRemote/JobOrder/{id}`) — carries the raw status/body so
/// the UI can show what actually went wrong instead of a generic message.
class JobOrderDetailFetchFailed implements Exception {
  const JobOrderDetailFetchFailed(this.statusCode, this.body);
  final int? statusCode;
  final Object? body;

  @override
  String toString() =>
      'GET job order failed (status: $statusCode, body: $body)';
}

/// Failure opening an appointment
/// (`POST /ServiceRemote/appointment/{id}?State=5`) — a non-2xx status.
/// A 2xx response with an empty/unexpected body is NOT a failure, see
/// [isAppointmentCallSuccessful].
class AppointmentOpenFailed implements Exception {
  const AppointmentOpenFailed(this.statusCode, this.body);
  final int? statusCode;
  final Object? body;

  @override
  String toString() =>
      'Open appointment failed (status: $statusCode, body: $body)';
}

/// Base type for a failure during [JobOrderRepository.submitJobOrder],
/// distinguishing which of the three steps failed.
sealed class JobOrderSubmissionException implements Exception {
  const JobOrderSubmissionException(this.message);
  final String message;

  @override
  String toString() => message;
}

class JobOrderSubmissionLoginFailed extends JobOrderSubmissionException {
  const JobOrderSubmissionLoginFailed(super.message);
}

class JobOrderSubmissionAppointmentCloseFailed
    extends JobOrderSubmissionException {
  const JobOrderSubmissionAppointmentCloseFailed(super.message);
}

class JobOrderSubmissionPostFailed extends JobOrderSubmissionException {
  const JobOrderSubmissionPostFailed(super.message);
}
