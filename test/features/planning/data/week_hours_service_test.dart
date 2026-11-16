import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/data/week_hours_service.dart';

void main() {
  // Week van maandag 28-09-2026 t/m zondag 04-10-2026.
  final maandag = DateTime(2026, 9, 28);

  WeekUrenKaart kaart(String id, DateTime d, int min, {bool verstuurd = false}) =>
      WeekUrenKaart(id: id, datum: d, minuten: min, verstuurd: verstuurd);

  test('maandagVan', () {
    expect(WeekHoursService.maandagVan(DateTime(2026, 10, 4, 23)), maandag);
    expect(WeekHoursService.maandagVan(DateTime(2026, 9, 28, 7)), maandag);
  });

  test('telt alleen deze week, splitst verstuurd/concept, geen dubbelen', () {
    final uit = WeekHoursService.tel([
      kaart('a', DateTime(2026, 9, 28), 480, verstuurd: true),
      kaart('b', DateTime(2026, 10, 4), 90),
      kaart('a', DateTime(2026, 9, 28), 480, verstuurd: true), // dubbel
      kaart('c', DateTime(2026, 9, 27), 600), // vorige week
      kaart('d', DateTime(2026, 10, 5), 600), // volgende week
    ], maandag);
    expect(uit.verstuurd, 8);
    expect(uit.concept, 1.5);
  });

  test('eerste kaart met een id wint (lokaal vóór Firestore)', () {
    final uit = WeekHoursService.tel([
      kaart('a', DateTime(2026, 9, 29), 60, verstuurd: true),
      kaart('a', DateTime(2026, 9, 29), 60),
    ], maandag);
    expect(uit.verstuurd, 1);
    expect(uit.concept, 0);
  });

  group('WeekUren', () {
    test('verstuurd maar nog niet goedgekeurd telt als wachtend', () {
      const w = WeekUren(goedgekeurd: 8, verstuurd: 16, concept: 4);
      expect(w.wachtOpKantoor, 8);
      expect(w.totaal, 20);
    });

    test('goedgekeurd meer dan verstuurd (bijv. kantoor boekte zelf)', () {
      const w = WeekUren(goedgekeurd: 24, verstuurd: 16, concept: 2);
      expect(w.wachtOpKantoor, 0);
      expect(w.totaal, 26);
    });

    test('indirecte uren tellen mee in het totaal, maar verbergen geen '
        'bon-uren die op kantoor wachten', () {
      const w = WeekUren(
        goedgekeurd: 0,
        verstuurd: 8,
        concept: 0,
        indirect: 8,
      );
      expect(w.wachtOpKantoor, 8);
      expect(w.totaal, 16);
    });
  });
}
