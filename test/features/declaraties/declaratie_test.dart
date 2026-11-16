import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:engine_energy_app/features/declaraties/data/declaratie_store.dart';
import 'package:engine_energy_app/features/declaraties/models/declaratie.dart';

Declaratie maak(String id, {DateTime? aangemaakt}) => Declaratie(
  id: id,
  datum: DateTime(2026, 10, 20),
  omschrijving: 'Tanken',
  bedrag: 54.3,
  betaalwijze: Betaalwijze.prive,
  bonId: '78',
  bonNummer: '200052.1',
  aangemaaktOp: aangemaakt ?? DateTime(2026, 10, 20, 12),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('json-rondreis behoudt alle velden', () {
    final d = maak('a').copyWith(
      fout: 'Geen verbinding',
      factuurId: 42,
    );
    final terug = Declaratie.fromJson(d.toJson());
    expect(terug.betaalwijze, Betaalwijze.prive);
    expect(terug.bonNummer, '200052.1');
    expect(terug.bedrag, 54.3);
    expect(terug.fout, 'Geen verbinding');
    expect(terug.factuurId, 42);
    expect(terug.isVerstuurd, isFalse);
  });

  test('omschrijving bevat betaalwijze en bonnummer', () {
    final d = maak('a');
    expect(d.regelOmschrijving, 'Tanken · Privérekening · Bon 200052.1');
    expect(d.factuurOmschrijving, 'Tanken · Privérekening · Bon 200052.1');
  });

  test('copyWith wisFout verwijdert de fout, status blijft verder gelijk', () {
    final d = maak('a').copyWith(fout: 'x');
    final klaar = d.copyWith(
      status: DeclaratieStatus.verstuurd,
      wisFout: true,
    );
    expect(klaar.fout, isNull);
    expect(klaar.isVerstuurd, isTrue);
    expect(klaar.omschrijving, 'Tanken');
  });

  test('onbekende betaalwijze valt terug op betaalpas', () {
    expect(Betaalwijze.fromName('iets-anders'), Betaalwijze.betaalpas);
  });

  test('store: bewaren, vervangen, sorteren en per monteur gescheiden', () async {
    final store = DeclaratieStore.instance;
    await store.bewaar(6, maak('oud', aangemaakt: DateTime(2026, 10, 1)));
    await store.bewaar(6, maak('nieuw', aangemaakt: DateTime(2026, 10, 20)));
    await store.bewaar(7, maak('van-ander'));

    var lijst = await store.laad(6);
    expect(lijst.map((d) => d.id), ['nieuw', 'oud']);
    expect(await store.laad(7), hasLength(1));

    // Zelfde id vervangt in plaats van dupliceert.
    await store.bewaar(
      6,
      maak('oud', aangemaakt: DateTime(2026, 10, 1)).copyWith(factuurId: 9),
    );
    lijst = await store.laad(6);
    expect(lijst, hasLength(2));
    expect((await store.vind(6, 'oud'))!.factuurId, 9);

    await store.verwijder(6, 'nieuw');
    expect((await store.laad(6)).map((d) => d.id), ['oud']);
  });

  test('store: tegelijkertijd bewaren verliest niets', () async {
    final store = DeclaratieStore.instance;
    await Future.wait([
      for (var i = 0; i < 10; i++) store.bewaar(6, maak('d$i')),
    ]);
    expect(await store.laad(6), hasLength(10));
  });

  test('store: kapotte opslag geeft lege lijst in plaats van crash', () async {
    SharedPreferences.setMockInitialValues({
      DeclaratieStore.sleutel(6): '{geen json',
    });
    expect(await DeclaratieStore.instance.laad(6), isEmpty);
  });
}
