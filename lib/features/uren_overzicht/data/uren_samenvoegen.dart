import '../models/uren_overzicht.dart';

/// Een urenregel uit Ridder (`/hours/projecttimes`): de waarheid voor wat
/// kantoor heeft verwerkt.
class RidderUren {
  const RidderUren({
    required this.id,
    required this.datum,
    required this.minuten,
    required this.soort,
    this.bonId,
    this.titel,
  });

  final String id;
  final DateTime datum;
  final int minuten;
  final UrenSoort soort;
  final String? bonId;
  final String? titel;
}

/// Een urenkaart uit de app (lokaal of Firestore); altijd op een bon.
class AppUren {
  const AppUren({
    required this.id,
    required this.datum,
    required this.minuten,
    required this.verstuurd,
    required this.bonId,
  });

  final String id;
  final DateTime datum;
  final int minuten;
  final bool verstuurd;
  final String bonId;
}

String _sleutel(String bonId, DateTime d) => '$bonId|${d.year}-${d.month}-${d.day}';

/// Voegt Ridder-uren en app-uren samen tot één lijst zonder dubbel tellen.
///
/// * Alles uit Ridder is **goedgekeurd** (indirecte uren komen alleen daar
///   vandaan).
/// * App-concepten zijn **concept**.
/// * Verstuurde app-uren worden ook projecttijden in Ridder zodra kantoor ze
///   verwerkt, maar zijn niet één-op-één te koppelen. Daarom per bon en dag:
///   wat Ridder daarvan al heeft, telt als verwerkt en staat al bij de
///   Ridder-regels; alleen het verschil blijft over als **wacht op kantoor**.
List<UrenRegel> voegUrenSamen({
  required Iterable<RidderUren> ridder,
  required Iterable<AppUren> app,
}) {
  final uit = <UrenRegel>[];
  final budget = <String, int>{};

  for (final r in ridder) {
    if (r.minuten <= 0) continue;
    final d = alleenDatum(r.datum);
    uit.add(
      UrenRegel(
        id: r.id,
        datum: d,
        minuten: r.minuten,
        soort: r.soort,
        status: UrenStatus.goedgekeurd,
        bonId: r.bonId,
        titel: r.titel,
      ),
    );
    if (r.soort == UrenSoort.project && r.bonId != null) {
      final k = _sleutel(r.bonId!, d);
      budget[k] = (budget[k] ?? 0) + r.minuten;
    }
  }

  final gezien = <String>{};
  final verstuurd = <AppUren>[];
  for (final a in app) {
    if (a.minuten <= 0 || !gezien.add(a.id)) continue;
    if (a.verstuurd) {
      verstuurd.add(a);
    } else {
      uit.add(
        UrenRegel(
          id: a.id,
          datum: alleenDatum(a.datum),
          minuten: a.minuten,
          soort: UrenSoort.project,
          status: UrenStatus.concept,
          bonId: a.bonId,
        ),
      );
    }
  }

  verstuurd.sort((x, y) {
    final c = x.datum.compareTo(y.datum);
    return c != 0 ? c : x.id.compareTo(y.id);
  });
  for (final a in verstuurd) {
    final d = alleenDatum(a.datum);
    final k = _sleutel(a.bonId, d);
    final over = budget[k] ?? 0;
    final gedekt = over >= a.minuten ? a.minuten : over;
    budget[k] = over - gedekt;
    final rest = a.minuten - gedekt;
    if (rest <= 0) continue;
    uit.add(
      UrenRegel(
        id: a.id,
        datum: d,
        minuten: rest,
        soort: UrenSoort.project,
        status: UrenStatus.wacht,
        bonId: a.bonId,
      ),
    );
  }
  return uit;
}
