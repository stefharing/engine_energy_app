import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/data/visit_report_pdf.dart';
import 'package:engine_energy_app/features/planning/models/visit_report.dart';
import 'package:engine_energy_app/features/planning/models/work_report_draft.dart';

void main() {
  test('maakt een geldige pdf, ook met bijzondere tekens en zonder handtekening',
      () async {
    final pdf = await buildVisitReportPdf(
      VisitReportData(
        bonNummer: '200041',
        omschrijving: 'Testbon – “met” tekens 🔧',
        klant: 'Jansen & Zn',
        monteur: 'Pieter Kiela',
        datum: DateTime(2026, 9, 29),
        uren: [
          VisitReportHourLine(
            datum: DateTime(2026, 10, 7),
            soort: 'Service NL (Standaard)',
            minuten: 480,
            memo: 'Motor uit elkaar gehaald',
          ),
        ],
        materialen: const [
          VisitReportMaterial(omschrijving: 'GASKET', code: '0000160521', aantal: 10),
        ],
        rapport: const WorkReportDraft(
          workDescription: 'Een hele hoop veranderd',
          findings: [Finding(id: 'f', text: 'Rare dingen')],
        ),
      ),
      ondertekenaar: const VisitReportSigner(name: 'Jason Spence'),
    );
    expect(pdf.length, greaterThan(1000));
    expect(ascii.decode(pdf.sublist(0, 5)), '%PDF-');
  });
}
