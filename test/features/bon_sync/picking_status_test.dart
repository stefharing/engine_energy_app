import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/bon_sync/models/picking_status.dart';

void main() {
  test('PickingStatus.fromMap leest aantallen, gepakt en bevestigd', () {
    final s = PickingStatus.fromMap({
      'aantallen': {'101': 2, '102': 0, '103': -1, '104': 3.0},
      'gepakt': {'101': true, '102': false},
      'bevestigd': true,
      'bijgewerktDoorNaam': 'Lex de Bruijn',
    });
    // 0 en negatief (na terugdraaien door een collega) tellen niet mee.
    expect(s.aantallen, {'101': 2, '104': 3});
    expect(s.gepakt, {'101'});
    expect(s.bevestigd, isTrue);
    expect(s.bijgewerktDoor, 'Lex de Bruijn');
  });

  test('PickingStatus.fromMap met leeg document', () {
    final s = PickingStatus.fromMap({});
    expect(s.aantallen, isEmpty);
    expect(s.gepakt, isEmpty);
    expect(s.bevestigd, isFalse);
  });
}
