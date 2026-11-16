import 'dart:io' show File;

import 'package:archive/archive.dart';
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
      // Temporary diagnostic: `_shortBody` truncates at 800 chars, well
      // before `detailItems`/`detailMisc` in the full body — print those
      // two fields on their own so we can see whether a previously-POSTed
      // material line actually persisted (real id) or never landed at all.
      if (response.data is Map) {
        final data = response.data as Map;
        debugPrint(
          '[diag] GET $url detailItems=${data['detailItems']}',
          wrapWidth: 1024,
        );
        debugPrint(
          '[diag] GET $url detailMisc=${data['detailMisc']}',
          wrapWidth: 1024,
        );
      }
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
  Future<JobOrderSubmissionResult> submitHoursForJobOrder({
    required int jobOrderId,
    required int employeeId,
    required List<HoursEntry> hours,
    List<ScannedExtra> extras = const [],
    List<List<List<int>>>? signaturePaths,
    String? signerName,
    String? signerEmail,
    String? employeeName,
    String? htmlFile,
    bool? overnachting,
    List<String> attachmentPaths = const [],
    bool onderbreken = false,
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

    final uniqueId = _uuid.v4();
    final Map<String, dynamic> body;
    try {
      body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: jobOrder.raw,
        appointmentId: appointmentId,
        employeeId: employeeId,
        hours: hours,
        uniqueId: uniqueId,
        extras: extras,
        signaturePaths: signaturePaths,
        signerName: signerName,
        signerEmail: signerEmail,
        employeeName: employeeName,
        htmlFile: htmlFile,
        overnachting: overnachting,
        onHold: onderbreken,
      );
    } catch (e) {
      throw JobOrderSubmissionPostFailed('Body opbouwen mislukt: $e');
    }

    var rapportMeegestuurd = body.containsKey('htmlFile');
    try {
      await _postJobOrder(jobOrderId, body);
    } on JobOrderSubmissionPostFailed catch (e) {
      if (!rapportMeegestuurd) rethrow;
      // Ridder kon het meegestuurde bezoekrapport eerder niet verwerken
      // (pdf-fout). Dan liever de registratie zonder rapport dan helemaal
      // niet: nog één keer, zelfde uniqueId, zonder htmlFile.
      debugPrint(
        '[diag] POST met bezoekrapport mislukt ($e) — opnieuw zonder htmlFile',
      );
      rapportMeegestuurd = false;
      await _postJobOrder(jobOrderId, Map.of(body)..remove('htmlFile'));
    }

    final bijlagen = await _uploadBijlagen(
      jobOrderId,
      uniqueId,
      attachmentPaths,
    );
    return JobOrderSubmissionResult(
      uniqueId: uniqueId,
      rapportMeegestuurd: rapportMeegestuurd,
      bijlagenAangeboden: attachmentPaths.length,
      bijlagenGeupload: bijlagen,
    );
  }

  Future<void> _postJobOrder(int jobOrderId, Map<String, dynamic> body) async {
    bool posted;
    try {
      // Temporary diagnostic: compare the exact outgoing `hours[].memo`
      // values with what Ridder persists after this submission.
      // Het bezoekrapport (met handtekening als base64) is te groot om te
      // loggen; alleen de lengte.
      final html = body['htmlFile'];
      final logBody = html is String
          ? (Map.of(body)..['htmlFile'] = '<bezoekrapport: ${html.length} tekens>')
          : body;
      debugPrint(
        '[diag] POST /ServiceRemote/JobOrder/$jobOrderId request body: $logBody',
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

  /// Zet foto's en documenten uit "Rapport schrijven" als bijlagen bij de
  /// servicebonregistratie in Ridder: één zip naar
  /// `POST /ServiceRemote/JobOrder/{id}/registration/{uniqueId}/documents`.
  /// Mag het afronden nooit laten mislukken; geeft het aantal geüploade
  /// bestanden terug (0 bij een fout, of op web waar geen lokale bestanden
  /// zijn).
  Future<int> _uploadBijlagen(
    int jobOrderId,
    String registrationId,
    List<String> paden,
  ) async {
    if (paden.isEmpty || kIsWeb) return 0;
    try {
      final archief = Archive();
      final gebruikt = <String>{};
      for (final pad in paden) {
        final bestand = File(pad);
        if (!await bestand.exists()) continue;
        final bytes = await bestand.readAsBytes();
        var naam = pad.split('/').last;
        var i = 1;
        while (!gebruikt.add(naam)) {
          naam = '${i++}_$naam';
        }
        archief.addFile(ArchiveFile(naam, bytes.length, bytes));
      }
      if (archief.isEmpty) return 0;
      final List<int>? zip = ZipEncoder().encode(archief);
      if (zip == null) return 0;
      final response = await _dio.post(
        '/ServiceRemote/JobOrder/$jobOrderId/registration/$registrationId/documents',
        data: FormData.fromMap({
          'zip': MultipartFile.fromBytes(zip, filename: 'bijlagen.zip'),
        }),
      );
      debugPrint(
        '[diag] bijlagen-upload -> ${response.statusCode} '
        'body=${_shortBody(response.data)}',
      );
      return response.statusCode == 200 ? archief.length : 0;
    } catch (e) {
      debugPrint('[diag] bijlagen-upload mislukt: $e');
      return 0;
    }
  }
}

/// Resultaat van [ServiceRemoteJobOrderRepository.submitHoursForJobOrder]:
/// de registratie zelf is altijd gelukt (anders volgt een exception); dit
/// zegt of het bezoekrapport en de bijlagen ook zijn meegekomen.
class JobOrderSubmissionResult {
  const JobOrderSubmissionResult({
    required this.uniqueId,
    required this.rapportMeegestuurd,
    required this.bijlagenAangeboden,
    required this.bijlagenGeupload,
  });

  final String uniqueId;
  final bool rapportMeegestuurd;
  final int bijlagenAangeboden;
  final int bijlagenGeupload;

  bool get bijlagenMislukt => bijlagenAangeboden > 0 && bijlagenGeupload == 0;
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

/// Een collega is deze bon op dit moment al aan het afronden.
class JobOrderSubmissionBezetDoorCollega extends JobOrderSubmissionException {
  const JobOrderSubmissionBezetDoorCollega(super.message);
}

/// De gedeelde tussenopslag (Firestore) was niet bereikbaar.
class JobOrderSubmissionSyncFailed extends JobOrderSubmissionException {
  const JobOrderSubmissionSyncFailed(super.message);
}
