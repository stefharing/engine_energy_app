import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_service.dart';
import '../models/hours_entry.dart';
import '../models/scanned_extra.dart';
import '../models/service_remote_job_order.dart';
import 'job_order_submission_builder.dart';

String _shortBody(dynamic data) {
  final s = data.toString();
  return s.length > 800 ? '${s.substring(0, 800)}…' : s;
}

bool _is2xx(int? statusCode) =>
    statusCode != null && statusCode >= 200 && statusCode < 300;

/// Ridder's error responses on `POST /ServiceRemote/JobOrder/{id}` are JSON
/// with a `detail` field naming the actual failure (e.g. "Nullable object
/// must have a value."). That's the message worth surfacing, not dio's
/// generic "Http status error [500]". Falls back to the raw body, then to
/// [fallback], if the body isn't the expected `{detail: ...}` shape.
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
/// the State=5 "open" call and the State=7 "close" call) counts as success.
/// Confirmed: this endpoint's 200 response schema is only ever `{type:
/// string}`, and a real successful call returns an empty/non-boolean body —
/// status code is the only signal it gives. Don't reintroduce a body check.
bool isAppointmentCallSuccessful(Response<dynamic> response) =>
    _is2xx(response.statusCode);

/// Internal — the raw status/body from a failed appointment State POST,
/// before it's translated into the caller-appropriate public exception.
class _AppointmentStatePostFailed implements Exception {
  const _AppointmentStatePostFailed(this.statusCode, this.body);
  final int? statusCode;
  final Object? body;
  @override
  String toString() => 'status=$statusCode body=$body';
}

/// Ported from `features/service_remote/data/job_order_repository.dart`
/// into the planning stack, per the "single stack" decision — this is now
/// the one place that writes hours back to Ridder.
class ServiceRemoteJobOrderRepository {
  ServiceRemoteJobOrderRepository({Dio? dio})
    : _dio = dio ?? ApiClient.instance.serviceRemoteDio;

  static final instance = ServiceRemoteJobOrderRepository();
  static const _appointmentStateOpen = 5;
  static const _appointmentStateClosing = 7;

  final Dio _dio;
  final Uuid _uuid = const Uuid();

  Future<ServiceRemoteJobOrder> getJobOrderDetail(int jobOrderId) async {
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
      return ServiceRemoteJobOrder(
        Map<String, dynamic>.from(response.data as Map),
      );
    } on DioException catch (e) {
      debugPrint(
        '[diag] GET $url FAILED -> status=${e.response?.statusCode} '
        'body=${_shortBody(e.response?.data)} type=${e.type} '
        'message=${e.message}',
      );
      throw JobOrderDetailFetchFailed(e.response?.statusCode, e.response?.data);
    }
  }

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

  /// Submits [hours] for [jobOrderId]/[employeeId]: re-verifies the session,
  /// fetches the freshest job order, resolves the appointment matching
  /// [employeeId], opens (State=5) then closes (State=7) that appointment,
  /// and POSTs the full job order back with [hours] populated.
  ///
  /// Confirmed-working 4-step sequence (live curl session, job order 79):
  /// GET job order → POST appointment State=5 → POST appointment State=7 →
  /// POST job order. Runs open+close together as one atomic submission —
  /// unlike the old `service_remote` flow this was ported from (which
  /// opened once when its screen was first viewed, and only closed at
  /// submit time), there is no separate "open on view" moment in the new
  /// hours screen, so both happen here, back to back.
  ///
  /// The job order used to build the POST body is fetched fresh right
  /// before posting (not reused from an earlier point in the session) — the
  /// new hours screen lets a technician accumulate a week's entries across
  /// multiple sessions before submitting, so working from the latest server
  /// state at submit time is safer than an object fetched whenever the
  /// screen first opened.
  ///
  /// Each step throws its own [JobOrderSubmissionException] subtype so the
  /// caller can show which step failed, mirroring the original
  /// `service_remote` flow's distinct-failure-reason UI.
  Future<void> submitHoursForJobOrder({
    required int jobOrderId,
    required int employeeId,
    required List<HoursEntry> hours,
    List<ScannedExtra> extras = const [],
  }) async {
    final credentials = AuthService.instance.currentCredentials;
    if (credentials == null) {
      throw const JobOrderSubmissionLoginFailed('Not logged in.');
    }
    try {
      // Re-verify the session before every submission — required in
      // practice even when already logged in; the official app does this
      // too.
      await AuthService.instance.reverifySession();
    } catch (e) {
      throw JobOrderSubmissionLoginFailed(e.toString());
    }

    final ServiceRemoteJobOrder jobOrder;
    try {
      jobOrder = await getJobOrderDetail(jobOrderId);
    } on JobOrderDetailFetchFailed catch (e) {
      throw JobOrderSubmissionFetchFailed(e.toString());
    }

    final AppointmentEntry appointment;
    try {
      appointment = appointmentForMechanic(jobOrder, employeeId);
    } on MechanicAppointmentNotFound catch (e) {
      throw JobOrderSubmissionAppointmentNotFound(e.toString());
    }
    final appointmentId = appointment.id;
    if (appointmentId == null) {
      throw const JobOrderSubmissionAppointmentNotFound(
        'Matched appointment entry has no id.',
      );
    }

    try {
      await _postAppointmentState(appointmentId, _appointmentStateOpen);
    } on _AppointmentStatePostFailed catch (e) {
      throw JobOrderSubmissionAppointmentOpenFailed(e.toString());
    }

    try {
      await _postAppointmentState(appointmentId, _appointmentStateClosing);
    } on _AppointmentStatePostFailed catch (e) {
      throw JobOrderSubmissionAppointmentCloseFailed(e.toString());
    }

    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: jobOrder.raw,
      appointmentId: appointmentId,
      hours: hours,
      uniqueId: _uuid.v4(),
      extras: extras,
    );

    bool posted;
    try {
      // Temporary diagnostic: compare the exact outgoing `hours[].memo`
      // values with what Ridder persists after this submission.
      debugPrint(
        '[diag] POST /ServiceRemote/JobOrder/$jobOrderId request body: $body',
        wrapWidth: 1024,
      );
      debugPrint(
        '[diag] material payload: detailItems=${body['detailItems']} '
        'detailMisc=${body['detailMisc']}',
        wrapWidth: 1024,
      );
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
      // field naming the actual failure mode — surface that instead of
      // dio's generic "Http status error [500]" message.
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

/// Base type for a failure during [ServiceRemoteJobOrderRepository.
/// submitHoursForJobOrder], distinguishing which step failed.
sealed class JobOrderSubmissionException implements Exception {
  const JobOrderSubmissionException(this.message);
  final String message;

  @override
  String toString() => message;
}

class JobOrderSubmissionLoginFailed extends JobOrderSubmissionException {
  const JobOrderSubmissionLoginFailed(super.message);
}

class JobOrderSubmissionFetchFailed extends JobOrderSubmissionException {
  const JobOrderSubmissionFetchFailed(super.message);
}

class JobOrderSubmissionAppointmentNotFound
    extends JobOrderSubmissionException {
  const JobOrderSubmissionAppointmentNotFound(super.message);
}

class JobOrderSubmissionAppointmentOpenFailed
    extends JobOrderSubmissionException {
  const JobOrderSubmissionAppointmentOpenFailed(super.message);
}

class JobOrderSubmissionAppointmentCloseFailed
    extends JobOrderSubmissionException {
  const JobOrderSubmissionAppointmentCloseFailed(super.message);
}

class JobOrderSubmissionPostFailed extends JobOrderSubmissionException {
  const JobOrderSubmissionPostFailed(super.message);
}
