import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/core/auth/employee.dart';
import 'package:engine_energy_app/core/auth/employee_matcher.dart';

void main() {
  const monteurs = [
    Employee(id: 6, name: 'Stef Haring', code: 'SH'),
    Employee(id: 7, name: 'Eric Jansen', code: 'EJ'),
  ];
  final ridder = <Map<String, dynamic>>[
    {'id': 6, 'code': 'SH', 'email': 'Stef@Engine-Energy.nl'},
    {'id': 7, 'code': 'EJ', 'email': 'eric@engine-energy.nl'},
    {'id': 9, 'code': 'KANTOOR', 'email': 'brenda@engine-energy.nl'},
  ];

  test('vindt de monteur hoofdletterongevoelig op e-mail', () {
    final e = matchEmployeeByEmail(
      emails: ['  stef@engine-energy.nl '],
      ridderEmployees: ridder,
      fieldEngineers: monteurs,
    );
    expect(e?.id, 6);
    expect(e?.name, 'Stef Haring');
  });

  test('probeert meerdere e-mailadressen van het account', () {
    final e = matchEmployeeByEmail(
      emails: ['onbekend@x.nl', 'eric@engine-energy.nl'],
      ridderEmployees: ridder,
      fieldEngineers: monteurs,
    );
    expect(e?.code, 'EJ');
  });

  test('kantoorpersoneel zonder monteursrol krijgt geen toegang', () {
    final e = matchEmployeeByEmail(
      emails: ['brenda@engine-energy.nl'],
      ridderEmployees: ridder,
      fieldEngineers: monteurs,
    );
    expect(e, isNull);
  });

  test('onbekend of leeg adres geeft null', () {
    expect(
      matchEmployeeByEmail(
        emails: ['niemand@engine-energy.nl'],
        ridderEmployees: ridder,
        fieldEngineers: monteurs,
      ),
      isNull,
    );
    expect(
      matchEmployeeByEmail(
        emails: const [],
        ridderEmployees: ridder,
        fieldEngineers: monteurs,
      ),
      isNull,
    );
  });

  test('valt terug op id als de code niet overeenkomt', () {
    final e = matchEmployeeByEmail(
      emails: ['stef@engine-energy.nl'],
      ridderEmployees: [
        {'id': 6, 'code': 'ANDERS', 'email': 'stef@engine-energy.nl'},
      ],
      fieldEngineers: monteurs,
    );
    expect(e?.id, 6);
  });
}
