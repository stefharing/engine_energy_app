import 'package:engine_energy_app/features/uren_overzicht/data/uren_overzicht_service.dart';
import 'package:engine_energy_app/features/uren_overzicht/data/uren_samenvoegen.dart';
import 'package:engine_energy_app/features/uren_overzicht/models/uren_formaat.dart';
import 'package:engine_energy_app/features/uren_overzicht/models/uren_overzicht.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dag = DateTime(2026, 10, 27);

  group('voegUrenSamen', () {
    test('Ridder is goedgekeurd, concept blijft concept', () {
      final uit = voegUrenSamen(
        ridder: [
          RidderUren(id: 'r1', datum: dag, minuten: 480, soort: UrenSoort.project, bonId: '1'),
          RidderUren(id: 'r2', datum: dag, minuten: 60, soort: UrenSoort.indirect),
        ],
        app: [
          AppUren(id: 'a1', datum: dag, minuten: 120, verstuurd: false, bonId: '2'),
        ],
      );
      expect(uit.length, 3);
      expect(uit.where((r) => r.status == UrenStatus.goedgekeurd).length, 2);
      expect(
        uit.firstWhere((r) => r.id == 'a1').status,
        UrenStatus.concept,
      );
    });

    test('verstuurd en al in Ridder telt niet dubbel', () {
      final uit = voegUrenSamen(
        ridder: [
          RidderUren(id: 'r1', datum: dag, minuten: 480, soort: UrenSoort.project, bonId: '1'),
        ],
        app: [
          AppUren(id: 'a1', datum: dag, minuten: 480, verstuurd: true, bonId: '1'),
        ],
      );
      expect(uit.length, 1);
      expect(uit.single.status, UrenStatus.goedgekeurd);
    });

    test('verstuurd en deels in Ridder: rest wacht op kantoor', () {
      final uit = voegUrenSamen(
        ridder: [
          RidderUren(id: 'r1', datum: dag, minuten: 300, soort: UrenSoort.project, bonId: '1'),
        ],
        app: [
          AppUren(id: 'a1', datum: dag, minuten: 480, verstuurd: true, bonId: '1'),
        ],
      );
      final wacht = uit.where((r) => r.status == UrenStatus.wacht).toList();
      expect(wacht.single.minuten, 180);
      expect(uit.fold<int>(0, (a, r) => a + r.minuten), 480);
    });

    test('verstuurd en nog niet in Ridder wacht op kantoor', () {
      final uit = voegUrenSamen(
        ridder: const [],
        app: [
          AppUren(id: 'a1', datum: dag, minuten: 240, verstuurd: true, bonId: '1'),
        ],
      );
      expect(uit.single.status, UrenStatus.wacht);
      expect(uit.single.minuten, 240);
    });

    test('indirecte Ridder-uren verbruiken geen bonbudget', () {
      final uit = voegUrenSamen(
        ridder: [
          RidderUren(id: 'r1', datum: dag, minuten: 480, soort: UrenSoort.indirect),
        ],
        app: [
          AppUren(id: 'a1', datum: dag, minuten: 60, verstuurd: true, bonId: '1'),
        ],
      );
      expect(uit.firstWhere((r) => r.id == 'a1').status, UrenStatus.wacht);
    });

    test('dubbele app-id telt één keer', () {
      final uit = voegUrenSamen(
        ridder: const [],
        app: [
          AppUren(id: 'a1', datum: dag, minuten: 60, verstuurd: false, bonId: '1'),
          AppUren(id: 'a1', datum: dag, minuten: 60, verstuurd: false, bonId: '1'),
        ],
      );
      expect(uit.length, 1);
    });
  });

  group('PeriodeOverzicht', () {
    test('telt project, indirect en km per dag', () {
      final p = PeriodeOverzicht.van(
        start: DateTime(2026, 10, 26),
        eindExcl: DateTime(2026, 11, 2),
        uren: [
          UrenRegel(id: '1', datum: dag, minuten: 360, soort: UrenSoort.project, status: UrenStatus.concept),
          UrenRegel(id: '2', datum: dag, minuten: 120, soort: UrenSoort.indirect, status: UrenStatus.goedgekeurd),
        ],
        km: [KmRegel(id: 'k', datum: dag, km: 85, verstuurd: false)],
      );
      expect(p.dagen.length, 7);
      expect(p.totaalMinuten, 480);
      expect(p.projectMinuten, 360);
      expect(p.indirectMinuten, 120);
      expect(p.km, 85);
      expect(p.conceptMinuten, 360);
      expect(p.dag(dag)!.status, UrenStatus.concept);
      expect(p.dag(DateTime(2026, 10, 26))!.isLeeg, isTrue);
    });
  });

  group('formaat', () {
    test('weeknummer en titel', () {
      expect(isoWeek(DateTime(2026, 10, 29)), 44);
      expect(isoWeek(DateTime(2026, 1, 1)), 1);
      expect(weekTitel(DateTime(2026, 10, 26)), 'Week 44 · 26 okt – 1 nov 2026');
    });

    test('uren en norm', () {
      expect(urenTekst(450), '7,5');
      expect(urenMetU(480), '8,0 u');
      expect(maandNormMinuten(DateTime(2026, 10, 1)), 22 * 8 * 60);
    });

    test('maandagVan', () {
      expect(maandagVan(DateTime(2026, 11, 1)), DateTime(2026, 10, 26));
    });
  });

  group('Ridder-vertaling', () {
    test('bon en indirect, filter op periode', () {
      final uit = UrenOverzichtService.ridderUitEntries(
        [
          {'id': 1, 'date': '2026-10-27T00:00:00', 'timeemployee': '08:00:00', 'joborder': {'id': 7}},
          {'id': 2, 'date': '2026-10-28T00:00:00', 'timeemployee': '01:30:00', 'joborder': null, 'workactivity': {'description': 'Opleiding'}},
          {'id': 3, 'date': '2026-09-01T00:00:00', 'timeemployee': '08:00:00', 'joborder': {'id': 7}},
        ],
        van: DateTime(2026, 10, 26),
        eindExcl: DateTime(2026, 11, 2),
      );
      expect(uit.length, 2);
      expect(uit[0].bonId, '7');
      expect(uit[0].soort, UrenSoort.project);
      expect(uit[1].soort, UrenSoort.indirect);
      expect(uit[1].minuten, 90);
      expect(uit[1].titel, 'Opleiding');
    });
  });
}
