import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/service_remote/data/job_order_submission.dart';
import 'package:engine_energy_app/features/service_remote/models/hours_entry.dart';
import 'package:engine_energy_app/features/service_remote/models/job_order.dart';

void main() {
  HoursEntry entry() => HoursEntry(
    jobOrderId: 59,
    employeeId: 6,
    start: DateTime(2026, 8, 5, 8, 0),
    end: DateTime(2026, 8, 5, 16, 0),
    totalTime: 480,
    timeEmployee: 480,
    workActivityId: 23,
    uniqueId: 'day-1-guid',
  );

  test('sets uniqueId, appointment, hours and readyForSignature', () {
    final jobOrder = JobOrder({
      'id': 59,
      'recordTag': 'B-0001',
      'employees': const [],
    });
    final hours = [entry()];

    final body = buildJobOrderSubmission(
      jobOrder: jobOrder,
      appointmentId: 90,
      hours: hours,
      uniqueId: 'submission-guid',
    );

    expect(body['uniqueId'], 'submission-guid');
    expect(body['appointment'], 90);
    expect(body['readyForSignature'], true);
    expect(body['hours'], [hours.first.toJson()]);
    // Original job order fields survive the round trip.
    expect(body['id'], 59);
    expect(body['recordTag'], 'B-0001');
  });

  test('omits htmlFile entirely, even if present on the source job order', () {
    final jobOrder = JobOrder({
      'id': 59,
      'htmlFile': 'placeholder.pdf',
      'employees': const [],
    });

    final body = buildJobOrderSubmission(
      jobOrder: jobOrder,
      appointmentId: 90,
      hours: const [],
      uniqueId: 'x',
    );

    expect(body.containsKey('htmlFile'), isFalse);
  });

  test('readyForSignature can be overridden, for phase 5b', () {
    final jobOrder = JobOrder({'id': 59, 'employees': const []});

    final body = buildJobOrderSubmission(
      jobOrder: jobOrder,
      appointmentId: 90,
      hours: const [],
      uniqueId: 'x',
      readyForSignature: false,
    );

    expect(body['readyForSignature'], false);
  });

  test('signature is omitted by default (phase 5a has no signature step)', () {
    final jobOrder = JobOrder({'id': 59, 'employees': const []});

    final body = buildJobOrderSubmission(
      jobOrder: jobOrder,
      appointmentId: 90,
      hours: const [],
      uniqueId: 'x',
    );

    expect(body.containsKey('signature'), isFalse);
  });

  test(
    'signature can be injected (temporary experiment hook, see job_order_repository.dart)',
    () {
      final jobOrder = JobOrder({'id': 59, 'employees': const []});

      final body = buildJobOrderSubmission(
        jobOrder: jobOrder,
        appointmentId: 90,
        hours: const [],
        uniqueId: 'x',
        readyForSignature: false,
        signature: const {'name': 'TEST', 'email': 'test@example.com', 'paths': []},
      );

      expect(body['signature'], {
        'name': 'TEST',
        'email': 'test@example.com',
        'paths': [],
      });
    },
  );

  test('overwrites any existing hours array on the source job order', () {
    final jobOrder = JobOrder({
      'id': 59,
      'hours': [
        {'id': 1, 'stale': true},
      ],
      'employees': const [],
    });

    final body = buildJobOrderSubmission(
      jobOrder: jobOrder,
      appointmentId: 90,
      hours: [entry()],
      uniqueId: 'x',
    );

    expect(body['hours'], hasLength(1));
    expect((body['hours'] as List).single, entry().toJson());
  });

  test('does not mutate the source job order', () {
    final raw = {'id': 59, 'employees': const []};
    final jobOrder = JobOrder(raw);

    buildJobOrderSubmission(
      jobOrder: jobOrder,
      appointmentId: 90,
      hours: const [],
      uniqueId: 'x',
    );

    expect(raw.containsKey('uniqueId'), isFalse);
    expect(raw.containsKey('appointment'), isFalse);
    expect(raw.containsKey('hours'), isFalse);
  });
}
