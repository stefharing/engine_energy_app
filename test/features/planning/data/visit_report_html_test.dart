import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/data/visit_report_html.dart';
import 'package:engine_energy_app/features/planning/models/visit_report.dart';
import 'package:engine_energy_app/features/planning/models/work_report_draft.dart';

void main() {
  final data = VisitReportData(
    bonNummer: 'SB-0046',
    omschrijving: 'Onderhoud aggregaat',
    klant: 'Jansen & Zn <B.V.>',
    adres: 'Dorpsstraat 1, Utrecht',
    monteur: 'Lex de Bruijn',
    datum: DateTime(2026, 9, 28),
    uren: [
      VisitReportHourLine(
        datum: DateTime(2026, 9, 28),
        soort: 'Service Engineer',
        minuten: 480,
        memo: 'Motor uit elkaar gehaald',
      ),
      VisitReportHourLine(
        datum: DateTime(2026, 9, 28),
        soort: 'Kilometers',
        km: 42,
      ),
    ],
    materialen: const [
      VisitReportMaterial(omschrijving: 'Oliefilter', code: 'FLT-01', aantal: 2),
    ],
    rapport: const WorkReportDraft(
      workDescription: 'Filters vervangen',
      findings: [
        Finding(id: 'f1', text: 'Lekkage bij pomp', severity: FindingSeverity.urgent),
        Finding(id: 'f2', text: '   '),
      ],
    ),
  );

  test('bevat alle onderdelen en telt uren/km op', () {
    final html = buildVisitReportHtml(
      data,
      ondertekenaar: const VisitReportSigner(
        name: 'P. Jansen',
        email: 'p@jansen.nl',
      ),
      getekendOp: DateTime(2026, 9, 28, 16, 5),
    );
    expect(html, startsWith('<!DOCTYPE html>'));
    expect(html, contains('Servicebon SB-0046'));
    expect(html, contains('Filters vervangen'));
    expect(html, contains('Lekkage bij pomp'));
    expect(html, contains('Urgent'));
    expect(html, contains('Motor uit elkaar gehaald'));
    expect(html, contains('8u00 · 42 km')); // totaal
    expect(html, contains('FLT-01'));
    expect(html, contains('P. Jansen'));
    expect(html, contains('28-09-2026 16:05'));
    expect(html, endsWith('</html>'));
  });

  test('ontsnapt HTML in klantgegevens', () {
    final html = buildVisitReportHtml(data);
    expect(html, contains('Jansen &amp; Zn &lt;B.V.&gt;'));
    expect(html, isNot(contains('<B.V.>')));
  });

  test('handtekening als data-URI, alleen als die er is', () {
    expect(buildVisitReportHtml(data), isNot(contains('data:image/png')));
    final html = buildVisitReportHtml(
      data,
      handtekeningPng: Uint8List.fromList([1, 2, 3]),
    );
    expect(html, contains('src="data:image/png;base64,AQID"'));
  });

  test('lege bevindingen en ontbrekend rapport worden overgeslagen', () {
    final zonder = buildVisitReportHtml(
      VisitReportData(
        bonNummer: '1',
        omschrijving: '',
        klant: 'K',
        monteur: 'M',
        datum: DateTime(2026, 1, 1),
      ),
    );
    expect(zonder, isNot(contains('Bevindingen')));
    expect(zonder, isNot(contains('Uren</h2>')));
    expect(zonder, isNot(contains('Gebruikte materialen')));
  });
}
