import 'package:engine_energy_app/features/planning/data/planning_repository.dart';
import 'package:engine_energy_app/features/planning/models/job_order.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceOrder _order(String id, {ServicePerson? mechanic}) => ServiceOrder(
  id: id,
  recordTag: '',
  orderNumber: '',
  description: 'Bon $id',
  startDate: null,
  endTime: null,
  deliveryDate: null,
  workflowState: 'Gepland',
  mechanic: mechanic,
  serviceObjectTag: '',
  serviceObjectDescription: '',
  serviceType: '',
  location: '',
  relationName: '',
);

Map<String, dynamic> _appt(int id, int actionId, int employeeId, String name) =>
    {
      'id': id,
      'appointmentaction': {'id': actionId, 'description': 'x'},
      'employee': {'id': employeeId, 'code': 'P', 'recordtag': name},
    };

void main() {
  const lex = ServicePerson(id: 6, name: 'Lex de Bruijn');

  // Shapes as returned live for job order 44 ("Mul_mon_test").
  final actions = [
    {
      'id': 23,
      'joborder': {'id': 44, 'recordtag': '200029.1'},
    },
    {
      'id': 99,
      'joborder': {'id': 50},
    },
  ];
  final appointments = [
    _appt(31, 23, 6, 'Lex de Bruijn'),
    _appt(32, 23, 3, 'Wim Boekestijn'),
    _appt(40, 99, 7, 'Anna'),
    _appt(41, 99, 2, 'Bert'),
  ];

  test('every mechanic with an appointment on the bon is assigned', () {
    final result = applyJobOrderAssignments(
      [_order('44', mechanic: lex)],
      actions: actions,
      appointments: appointments,
    );
    final order = result.single;

    expect(order.assignedMechanics.map((m) => m.name), [
      'Lex de Bruijn',
      'Wim Boekestijn',
    ]);
    expect(order.isAssignedTo(6), isTrue);
    expect(order.isAssignedTo(3), isTrue);
    expect(order.isAssignedTo(7), isFalse);
    expect(order.appointmentActionIds, {23});
  });

  test('servicemechanic stays first; the others are sorted by name', () {
    final result = applyJobOrderAssignments(
      [_order('50', mechanic: const ServicePerson(id: 9, name: 'Zoë'))],
      actions: actions,
      appointments: appointments,
    );
    expect(result.single.assignedMechanics.map((m) => m.name), [
      'Zoë',
      'Anna',
      'Bert',
    ]);
  });

  test('a bon without linked appointments keeps just its servicemechanic', () {
    final result = applyJobOrderAssignments(
      [_order('77', mechanic: lex), _order('78')],
      actions: actions,
      appointments: appointments,
    );
    expect(result[0].assignedMechanics.single.id, 6);
    expect(result[0].appointmentActionIds, isEmpty);
    expect(result[1].assignedMechanics, isEmpty);
    expect(result[1].isAssignedTo(6), isFalse);
  });

  test('Appointment.fromJson keeps the appointmentaction id', () {
    final appt = Appointment.fromJson({
      'id': 32,
      'appointmentaction': {'id': 23, 'description': 'Mul_mon_test'},
      'employee': {'id': 3, 'recordtag': 'Wim Boekestijn'},
      'start': '2026-10-01T02:00:00',
      'end': '2026-10-01T02:00:00',
    });
    expect(appt.appointmentActionId, 23);
    expect(appt.isAssignedTo(3), isTrue);
  });
}
