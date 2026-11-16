import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:engine_energy_app/features/planning/data/extras_draft_service.dart';
import 'package:engine_energy_app/features/planning/models/scanned_extra.dart';

/// In tests draait Firebase niet, dus de service werkt in lokale modus —
/// precies het gedrag van vóór Firestore, plus stabiele regel-ids.
void main() {
  const orderId = '79';

  setUp(() {
    SharedPreferences.setMockInitialValues({
      ExtrasDraftService.lokaleSleutel(orderId): jsonEncode([
        {
          'item': {'id': 1, 'code': 'A'},
          'scannedCount': 2,
        },
        {
          'item': {'id': 2, 'code': 'B'},
          'scannedCount': 1,
        },
      ]),
    });
  });

  test('ScannedExtra json-rondreis met regel-id en monteur', () {
    const e = ScannedExtra(
      item: {'id': 1, 'code': 'A'},
      scannedCount: 3,
      regelId: 'r1',
      monteurId: 6,
      monteurNaam: 'Jan',
    );
    final terug = ScannedExtra.fromJson(e.toJson());
    expect(terug.regelId, 'r1');
    expect(terug.monteurId, 6);
    expect(terug.monteurNaam, 'Jan');
    expect(terug.copyWith(scannedCount: 4).regelId, 'r1');
  });

  test('lokale modus: oude concepten krijgen een vast id', () async {
    final service = ExtrasDraftService.instance;
    expect(service.isGedeeld, isFalse);
    final eerste = await service.load(orderId);
    final tweede = await service.load(orderId);
    expect(eerste.map((e) => e.regelId), everyElement(isNotNull));
    expect(tweede.map((e) => e.regelId), eerste.map((e) => e.regelId));
  });

  test('lokale modus: bewaren en verwijderen op regel-id', () async {
    final service = ExtrasDraftService.instance;
    final lijst = await service.load(orderId);
    await service.bewaar(orderId, lijst.first.copyWith(scannedCount: 5));
    await service.verwijder(orderId, lijst.last);
    final na = await service.load(orderId);
    expect(na, hasLength(1));
    expect(na.single.code, 'A');
    expect(na.single.scannedCount, 5);
  });

  test('lokale modus: markeren als gepubliceerd', () async {
    final service = ExtrasDraftService.instance;
    final lijst = await service.load(orderId);
    await service.markeerLokaalGepubliceerd(orderId, [lijst.first]);
    final na = await service.load(orderId);
    expect(na.first.needsPublication, isFalse);
    expect(na.last.needsPublication, isTrue);
  });
}
