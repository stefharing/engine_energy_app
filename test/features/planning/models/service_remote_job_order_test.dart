import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/models/service_remote_job_order.dart';

void main() {
  test('finds the logged-in mechanic appointment by employee id', () {
    final jobOrder = ServiceRemoteJobOrder({
      'employees': [
        {'id': 8, 'employee': 12},
        {'id': 9, 'employee': 34},
      ],
    });
    expect(appointmentForMechanic(jobOrder, 34).id, 9);
  });

  test('missing mechanic appointment is an explicit error', () {
    final jobOrder = ServiceRemoteJobOrder({
      'employees': [
        {'id': 8, 'employee': 12},
      ],
    });
    expect(
      () => appointmentForMechanic(jobOrder, 34),
      throwsA(isA<MechanicAppointmentNotFound>()),
    );
  });

  test('resolves via the entry\'s own id, not appointmentActionId', () {
    final jobOrder = ServiceRemoteJobOrder({
      'employees': [
        {'id': 112, 'employee': 6, 'appointmentActionId': 999},
      ],
    });
    expect(appointmentForMechanic(jobOrder, 6).id, 112);
  });

  test('detail model retains unknown fields for a later full POST', () {
    final raw = {
      'id': 7,
      'futureServerField': {'nested': true},
      'employees': const [],
    };
    expect(ServiceRemoteJobOrder(raw).toJson(), same(raw));
  });
}
