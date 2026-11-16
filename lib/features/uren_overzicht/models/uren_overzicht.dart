/// Project (op een bon) of indirect (zonder bon).
enum UrenSoort { project, indirect }

/// Waar de uren zijn: goedgekeurd (staat in Ridder), wacht op kantoor
/// (verstuurd vanuit de app) of nog niet verstuurd (concept).
enum UrenStatus { goedgekeurd, wacht, concept }

DateTime alleenDatum(DateTime d) => DateTime(d.year, d.month, d.day);

/// Eén urenregel in het overzicht.
class UrenRegel {
  const UrenRegel({
    required this.id,
    required this.datum,
    required this.minuten,
    required this.soort,
    required this.status,
    this.bonId,
    this.titel,
  });

  final String id;
  final DateTime datum;
  final int minuten;
  final UrenSoort soort;
  final UrenStatus status;
  final String? bonId;

  /// Bij een bon: "bonnummer · klant"; bij indirect: de uursoort.
  final String? titel;

  UrenRegel metTitel(String? nieuweTitel) => UrenRegel(
    id: id,
    datum: datum,
    minuten: minuten,
    soort: soort,
    status: status,
    bonId: bonId,
    titel: nieuweTitel,
  );
}

class KmRegel {
  const KmRegel({
    required this.id,
    required this.datum,
    required this.km,
    required this.verstuurd,
    this.bonId,
  });

  final String id;
  final DateTime datum;
  final int km;
  final bool verstuurd;
  final String? bonId;
}

/// Alles wat op één dag is geregistreerd.
class DagOverzicht {
  const DagOverzicht(this.datum, {this.uren = const [], this.kmRegels = const []});

  final DateTime datum;
  final List<UrenRegel> uren;
  final List<KmRegel> kmRegels;

  int _minuten(UrenSoort s) =>
      uren.where((r) => r.soort == s).fold(0, (a, r) => a + r.minuten);

  int get projectMinuten => _minuten(UrenSoort.project);
  int get indirectMinuten => _minuten(UrenSoort.indirect);
  int get totaalMinuten => projectMinuten + indirectMinuten;
  int get km => kmRegels.fold(0, (a, k) => a + k.km);
  bool get isLeeg => totaalMinuten == 0 && km == 0;

  /// De "slechtste" status van de dag: concept gaat voor wacht, wacht gaat
  /// voor goedgekeurd. `null` als er geen uren zijn.
  UrenStatus? get status {
    if (uren.isEmpty) return null;
    if (uren.any((r) => r.status == UrenStatus.concept)) return UrenStatus.concept;
    if (uren.any((r) => r.status == UrenStatus.wacht)) return UrenStatus.wacht;
    return UrenStatus.goedgekeurd;
  }
}

/// De uren van één week of maand, per dag.
class PeriodeOverzicht {
  const PeriodeOverzicht({
    required this.start,
    required this.eindExcl,
    required this.dagen,
    this.ridderBekend = true,
  });

  /// Dagen van [start] tot [eindExcl] met de uren en km uit [uren] en [km].
  factory PeriodeOverzicht.van({
    required DateTime start,
    required DateTime eindExcl,
    required Iterable<UrenRegel> uren,
    required Iterable<KmRegel> km,
    bool ridderBekend = true,
  }) {
    final urenPerDag = <DateTime, List<UrenRegel>>{};
    for (final r in uren) {
      urenPerDag.putIfAbsent(alleenDatum(r.datum), () => []).add(r);
    }
    final kmPerDag = <DateTime, List<KmRegel>>{};
    for (final k in km) {
      kmPerDag.putIfAbsent(alleenDatum(k.datum), () => []).add(k);
    }
    final dagen = <DagOverzicht>[];
    for (
      var d = alleenDatum(start);
      d.isBefore(eindExcl);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      final lijst = [...?urenPerDag[d]]
        ..sort((a, b) {
          if (a.soort != b.soort) return a.soort == UrenSoort.project ? -1 : 1;
          return (a.titel ?? '').compareTo(b.titel ?? '');
        });
      dagen.add(DagOverzicht(d, uren: lijst, kmRegels: [...?kmPerDag[d]]));
    }
    return PeriodeOverzicht(
      start: alleenDatum(start),
      eindExcl: eindExcl,
      dagen: dagen,
      ridderBekend: ridderBekend,
    );
  }

  final DateTime start;
  final DateTime eindExcl;
  final List<DagOverzicht> dagen;

  /// `false` als Ridder niet bereikbaar was: goedgekeurde uren ontbreken dan,
  /// en verstuurde uren staan als "wacht op kantoor".
  final bool ridderBekend;

  int get projectMinuten => dagen.fold(0, (a, d) => a + d.projectMinuten);
  int get indirectMinuten => dagen.fold(0, (a, d) => a + d.indirectMinuten);
  int get totaalMinuten => projectMinuten + indirectMinuten;
  int get km => dagen.fold(0, (a, d) => a + d.km);

  Iterable<UrenRegel> get alleUren => dagen.expand((d) => d.uren);

  List<UrenRegel> get conceptRegels =>
      alleUren.where((r) => r.status == UrenStatus.concept).toList();

  int get conceptMinuten => conceptRegels.fold(0, (a, r) => a + r.minuten);

  DagOverzicht? dag(DateTime d) {
    final dd = alleenDatum(d);
    for (final x in dagen) {
      if (x.datum == dd) return x;
    }
    return null;
  }
}
