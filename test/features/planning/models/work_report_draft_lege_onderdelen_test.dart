import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/models/work_report_draft.dart';

void main() {
  test('leeg rapport: alle onderdelen leeg', () {
    expect(const WorkReportDraft().legeOnderdelen, [
      'Werkomschrijving',
      'Beginsituatie',
      'Bevindingen',
      'Aanbevelingen',
      "Foto's & documenten",
    ]);
  });

  test('bevinding met alleen spaties telt als leeg', () {
    const r = WorkReportDraft(
      workDescription: 'Filters vervangen',
      findings: [Finding(id: 'f', text: '  ')],
      photoPaths: ['/a.jpg'],
    );
    expect(r.legeOnderdelen, ['Beginsituatie', 'Bevindingen', 'Aanbevelingen']);
  });
}
