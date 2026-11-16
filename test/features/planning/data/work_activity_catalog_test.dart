import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/core/api/api_config.dart';
import 'package:engine_energy_app/features/planning/data/work_activity_catalog.dart';

Map<String, dynamic> wa(int id, String code, String desc, {int type = 16}) => {
  'id': id,
  'code': code,
  'description': desc,
  'workactivitytype': {'choicenumber': type},
  'timeregistrationapp': true,
};

void main() {
  test('parseDirecteUren houdt alleen directe uren over (live-response)', () {
    final lijst = WorkActivityCatalog.parseDirecteUren([
      wa(5, '1040', 'Pauze', type: 3),
      wa(20, 'ZSRV-ABR', 'Service Engineer Abroad (Dagtarief)'),
      wa(24, 'SRV-NL', 'Service Engineer NL (Standaard)'),
      wa(27, 'SRV-ABR', 'Service Engineer Abroad (Dagtarief)'),
      wa(28, 'TRAV-H', 'Reisuren (Uurtarief)'),
    ]);
    expect(lijst.map((w) => w.code), ['ZSRV-ABR', 'SRV-NL', 'SRV-ABR', 'TRAV-H']);
  });

  test('oude kaarten zonder code: betekenis van het vroegere vaste id', () {
    expect(WorkActivityCatalog.codeVoorKaart(id: 20), 'SRV-NL');
    expect(WorkActivityCatalog.codeVoorKaart(id: 23), 'SRV-ABR');
    expect(WorkActivityCatalog.codeVoorKaart(id: 24), 'TRAV-H');
    expect(WorkActivityCatalog.codeVoorKaart(id: 21), isNull); // overwerk
    // Een opgeslagen code gaat altijd voor.
    expect(WorkActivityCatalog.codeVoorKaart(code: 'SRV-ABR', id: 20), 'SRV-ABR');
  });

  test('live zonder opgehaalde lijst: juiste live-id\'s, geen Z-codes', () {
    ApiConfig.environment = ApiEnvironment.live;
    final c = WorkActivityCatalog.instance;
    expect(c.idVoorKaart(code: 'SRV-NL'), 24);
    expect(c.idVoorKaart(code: 'SRV-ABR'), 27);
    expect(c.idVoorKaart(id: 20), 24); // oude "Service NL"-kaart
    expect(c.idVoorKaart(id: 23), 27); // oude "Service Abroad"-kaart
    expect(c.idVoorKaart(id: 26), isNull); // machinale bewerkingen: bestaat niet
    expect(c.werkOpties.map((w) => w.code), ['SRV-NL', 'SRV-ABR']);
    expect(c.reistijd?.id, 28);
    expect(c.labelVoorKaart(code: 'TRAV-H'), 'Reistijd');
  });
}
