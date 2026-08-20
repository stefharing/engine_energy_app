import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/data/service_remote_job_order_repository.dart';

/// Builds a Dio whose every request is short-circuited (via
/// `handler.resolve`/`handler.reject` in a request interceptor) to a fixed
/// response, without ever touching the network. Resolving bypasses dio's
/// own `validateStatus`, so this can simulate any status code — including
/// ones dio would normally turn into a `DioException` itself.
Dio _fakeDio({required int statusCode, dynamic data}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (statusCode >= 200 && statusCode < 300) {
          handler.resolve(
            Response(requestOptions: options, statusCode: statusCode, data: data),
          );
        } else {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: statusCode,
                data: data,
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        }
      },
    ),
  );
  return dio;
}

void main() {
  // isAppointmentCallSuccessful is the exact logic shared by both the
  // State=5 open and State=7 close calls inside submitHoursForJobOrder —
  // both route through the same private `_postAppointmentState` helper,
  // only the `state` argument differs.
  group('isAppointmentCallSuccessful (shared by State=5 open and State=7 close)', () {
    Response<dynamic> responseWith(int? statusCode, dynamic data) => Response(
      requestOptions: RequestOptions(path: '/x'),
      statusCode: statusCode,
      data: data,
    );

    test('200 with an empty string body is success — the original bug', () {
      expect(isAppointmentCallSuccessful(responseWith(200, '')), isTrue);
    });

    test('200 with a null body is success', () {
      expect(isAppointmentCallSuccessful(responseWith(200, null)), isTrue);
    });

    test('200 with a non-boolean string body is success', () {
      expect(isAppointmentCallSuccessful(responseWith(200, 'ok')), isTrue);
    });

    test('204 (no content) is success', () {
      expect(isAppointmentCallSuccessful(responseWith(204, null)), isTrue);
    });

    test('a non-2xx status is not success, regardless of body', () {
      expect(isAppointmentCallSuccessful(responseWith(500, 'true')), isFalse);
      expect(isAppointmentCallSuccessful(responseWith(404, null)), isFalse);
      expect(isAppointmentCallSuccessful(responseWith(401, null)), isFalse);
    });

    test('a null status code is not success', () {
      expect(isAppointmentCallSuccessful(responseWith(null, '')), isFalse);
    });
  });

  group('ServiceRemoteJobOrderRepository.getJobOrderDetail', () {
    test(
      'a non-2xx status throws JobOrderDetailFetchFailed with the real status/body',
      () async {
        final repo = ServiceRemoteJobOrderRepository(
          dio: _fakeDio(statusCode: 401, data: 'Unauthorized'),
        );
        await expectLater(
          () => repo.getJobOrderDetail(79),
          throwsA(
            isA<JobOrderDetailFetchFailed>()
                .having((e) => e.statusCode, 'statusCode', 401)
                .having((e) => e.body, 'body', 'Unauthorized'),
          ),
        );
      },
    );

    test('parses a successful map response into a ServiceRemoteJobOrder', () async {
      final repo = ServiceRemoteJobOrderRepository(
        dio: _fakeDio(statusCode: 200, data: {'id': 79, 'employees': const []}),
      );
      final jobOrder = await repo.getJobOrderDetail(79);
      expect(jobOrder.id, 79);
    });
  });

  // extractErrorDetail is the exact logic submitHoursForJobOrder's final
  // POST step uses to turn a 500's body into JobOrderSubmissionPostFailed's
  // message — which the UI shows verbatim via its toString().
  group('extractErrorDetail (JobOrder POST 500 body -> exception message)', () {
    test('extracts detail from a live-confirmed {detail: ...} body (null ref)', () {
      expect(
        extractErrorDetail({
          'status': 500,
          'detail': 'Nullable object must have a value.',
          'traceId': 'abc-123',
        }, 'fallback'),
        'Nullable object must have a value.',
      );
    });

    test('falls back to the raw body if it has no detail field', () {
      expect(
        extractErrorDetail('Internal Server Error', 'fallback'),
        'Internal Server Error',
      );
    });

    test('falls back to the given fallback if the body is null', () {
      expect(extractErrorDetail(null, 'fallback message'), 'fallback message');
    });
  });

  group('JobOrderSubmissionPostFailed surfaces the detail to the UI', () {
    test('toString() (what the UI interpolates) contains the server detail', () {
      final message =
          'status=500: '
          '${extractErrorDetail({
            'status': 500,
            'detail': 'Nullable object must have a value.',
          }, 'unused')}';
      final exception = JobOrderSubmissionPostFailed(message);

      expect(exception.toString(), contains('Nullable object must have a value.'));
      expect(exception.toString(), contains('500'));
    });
  });
}
