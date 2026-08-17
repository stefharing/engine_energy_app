import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/service_remote/models/job_order.dart';

void main() {
  test('finds the logged-in mechanic appointment by employee id', () {
    final jobOrder = JobOrder({
      'employees': [
        {'id': 8, 'employee': 12},
        {'id': 9, 'employee': 34},
      ],
    });
    expect(appointmentForMechanic(jobOrder, 34).id, 9);
  });

  test('missing mechanic appointment is an explicit error', () {
    final jobOrder = JobOrder({
      'employees': [
        {'id': 8, 'employee': 12},
      ],
    });
    expect(
      () => appointmentForMechanic(jobOrder, 34),
      throwsA(isA<MechanicAppointmentNotFound>()),
    );
  });

  test('detail model retains unknown fields for a later full POST', () {
    final raw = {
      'id': 7,
      'futureServerField': {'nested': true},
      'employees': const [],
    };
    expect(JobOrder(raw).toJson(), same(raw));
  });
}
