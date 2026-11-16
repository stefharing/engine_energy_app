import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/bon_sync/models/bon_regel.dart';
import 'package:engine_energy_app/features/bon_sync/models/servicebon_sync.dart';

/// Lijkt op een Firestore `Timestamp`: alleen `toDate()`.
class _NepTimestamp {
  _NepTimestamp(this._d);
  final DateTime _d;
  DateTime toDate() => _d;
}

void main() {
  final nu = DateTime(2026, 9, 28, 10, 30);

  group('BonRegel', () {
    test('artikel: toMap/fromMap rondreis', () {
      final r = BonRegel.artikel(
        id: 'a1',
        monteurId: 6,
        monteurNaam: 'Jan',
        item: {'id': 12, 'code': 'FLT-01', 'description': 'Oliefilter'},
        aantal: 2,
        nu: nu,
      );
      final terug = BonRegel.fromMap(r.toMap());
      expect(terug.id, 'a1');
      expect(terug.type, BonRegelType.artikel);
      expect(terug.monteurId, 6);
      expect(terug.item!['code'], 'FLT-01');
      expect(terug.aantal, 2);
      expect(terug.status, BonRegelStatus.concept);
      expect(terug.moetGepubliceerd, isTrue);
    });

    test('uren: datum zonder tijd, als yyyy-MM-dd opgeslagen', () {
      final r = BonRegel.uren(
        id: 'u1',
        monteurId: 6,
        monteurNaam: 'Jan',
        datum: DateTime(2026, 9, 3, 17, 45),
        workActivityId: 20,
        minuten: 90,
        memo: 'Pomp vervangen',
        nu: nu,
      );
      final m = r.toMap();
      expect(m['datum'], '2026-09-03');
      final terug = BonRegel.fromMap(m);
      expect(terug.datum, DateTime(2026, 9, 3));
      expect(terug.minuten, 90);
      expect(terug.workActivityId, 20);
      expect(terug.memo, 'Pomp vervangen');
    });

    test('km: rondreis', () {
      final r = BonRegel.km(
        id: 'k1',
        monteurId: 7,
        monteurNaam: 'Piet',
        datum: DateTime(2026, 9, 3),
        km: 42,
        nu: nu,
      );
      final terug = BonRegel.fromMap(r.toMap());
      expect(terug.type, BonRegelType.km);
      expect(terug.km, 42);
      expect(terug.item, isNull);
    });

    test('fromMap leest Firestore-achtige timestamps', () {
      final m = BonRegel.km(
        id: 'k2',
        monteurId: 7,
        monteurNaam: 'Piet',
        datum: nu,
        km: 1,
        nu: nu,
      ).toMap();
      m['aangemaaktOp'] = _NepTimestamp(nu);
      m['bijgewerktOp'] = _NepTimestamp(nu);
      m['verstuurdOp'] = _NepTimestamp(nu);
      final terug = BonRegel.fromMap(m);
      expect(terug.aangemaaktOp, nu);
      expect(terug.verstuurdOp, nu);
    });

    test('verwijderde of verstuurde regels hoeven niet gepubliceerd', () {
      final r = BonRegel.artikel(
        id: 'a2',
        monteurId: 6,
        monteurNaam: 'Jan',
        item: {'id': 1},
        aantal: 1,
        nu: nu,
      );
      expect(r.copyWith(verwijderd: true).moetGepubliceerd, isFalse);
      expect(
        r.copyWith(status: BonRegelStatus.verstuurd).moetGepubliceerd,
        isFalse,
      );
    });

    test('copyWith behoudt id, type en monteur', () {
      final r = BonRegel.artikel(
        id: 'a3',
        monteurId: 6,
        monteurNaam: 'Jan',
        item: {'id': 1},
        aantal: 1,
        nu: nu,
      );
      final later = nu.add(const Duration(minutes: 5));
      final c = r.copyWith(aantal: 3, nu: later);
      expect(c.id, 'a3');
      expect(c.monteurId, 6);
      expect(c.aantal, 3);
      expect(c.aangemaaktOp, nu);
      expect(c.bijgewerktOp, later);
    });

    test('toScannedExtra: verstuurde regel telt als gesynchroniseerd', () {
      final r = BonRegel.artikel(
        id: 'a4',
        monteurId: 6,
        monteurNaam: 'Jan',
        item: {'id': 5, 'code': 'X'},
        aantal: 4,
        nu: nu,
      );
      expect(r.toScannedExtra().needsPublication, isTrue);
      final verstuurd = r
          .copyWith(status: BonRegelStatus.verstuurd)
          .toScannedExtra();
      expect(verstuurd.scannedCount, 4);
      expect(verstuurd.needsPublication, isFalse);
    });

    test('toScannedExtra neemt regel-id en monteur mee', () {
      final extra = BonRegel.artikel(
        id: 'a5',
        monteurId: 7,
        monteurNaam: 'Piet',
        item: {'id': 5, 'code': 'X'},
        aantal: 1,
        nu: nu,
      ).toScannedExtra();
      expect(extra.regelId, 'a5');
      expect(extra.monteurId, 7);
      expect(extra.monteurNaam, 'Piet');
    });
  });

  group('ServicebonSyncStatus', () {
    test('Firestore-waarden heen en terug', () {
      for (final s in ServicebonSyncStatus.values) {
        expect(ServicebonSyncStatus.vanFirestore(s.firestoreWaarde), s);
      }
      expect(ServicebonSyncStatus.vanFirestore(null), ServicebonSyncStatus.open);
    });
  });
}
