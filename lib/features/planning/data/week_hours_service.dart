import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/auth_service.dart';
import '../../../core/firebase/firebase_bootstrap.dart';
import '../../bon_sync/data/firestore_bon_draft_repository.dart';
import '../../bon_sync/models/bon_regel.dart';
import 'hours_draft_service.dart' show kmCardType;

/// Eén urenkaart zoals die voor het weekoverzicht telt.
@immutable
class WeekUrenKaart {
  const WeekUrenKaart({
    required this.id,
    required this.datum,
    required this.minuten,
    required this.verstuurd,
  });

  final String id;
  final DateTime datum;
  final int minuten;

  /// Al naar Ridder gestuurd via "Werk afronden".
  final bool verstuurd;
}

/// De uren van de monteur in één week, opgesplitst naar status.
///
/// Goedgekeurde uren komen uit Ridder (projecttijden, na verwerking door
/// kantoor). App-uren zijn alles wat de monteur in de app heeft ingevoerd.
/// Die twee overlappen: verstuurde app-uren worden na goedkeuring ook
/// projecttijden. Omdat ze niet één-op-één te koppelen zijn, rekent het
/// overzicht zo:
/// * **goedgekeurd** — wat Ridder heeft;
/// * **wacht op kantoor** — verstuurde app-uren die (nog) niet in de
///   goedgekeurde uren kunnen zitten: `max(0, verstuurd − goedgekeurd)`;
/// * **nog niet verstuurd** — concept-uren in de app.
class WeekUren {
  const WeekUren({
    this.goedgekeurd = 0,
    this.verstuurd = 0,
    this.concept = 0,
    this.indirect = 0,
    this.goedgekeurdBekend = true,
  });

  final double goedgekeurd;

  /// Indirecte uren (zonder bon) uit Ridder. Staan los van de bon-uren en
  /// doen dus niet mee in de vergelijking [wachtOpKantoor].
  final double indirect;
  final double verstuurd;
  final double concept;

  /// `false` als Ridder niet bereikbaar was (dan is [goedgekeurd] 0).
  final bool goedgekeurdBekend;

  double get wachtOpKantoor => math.max(0, verstuurd - goedgekeurd);
  double get totaal => goedgekeurd + wachtOpKantoor + concept + indirect;
}

/// Verzamelt de in de app ingevoerde uren van de ingelogde monteur voor een
/// week: uit de lokale urenconcepten van alle bonnen op dit toestel, aangevuld
/// met wat er in Firestore staat (uren van een ander toestel).
class WeekHoursService {
  WeekHoursService._();
  static final instance = WeekHoursService._();

  static const _conceptPrefix = 'hours_week_draft_';

  /// Maandag 00:00 van de week waarin [d] valt.
  static DateTime maandagVan(DateTime d) =>
      DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

  /// Telt [kaarten] die in de week vanaf [maandag] vallen op, in uren.
  /// Dubbele ids tellen één keer (de eerste wint).
  static ({double verstuurd, double concept}) tel(
    Iterable<WeekUrenKaart> kaarten,
    DateTime maandag,
  ) {
    final start = maandagVan(maandag);
    final eind = start.add(const Duration(days: 7));
    final gezien = <String>{};
    var verstuurd = 0;
    var concept = 0;
    for (final k in kaarten) {
      if (!gezien.add(k.id)) continue;
      final dag = DateTime(k.datum.year, k.datum.month, k.datum.day);
      if (dag.isBefore(start) || !dag.isBefore(eind)) continue;
      if (k.verstuurd) {
        verstuurd += k.minuten;
      } else {
        concept += k.minuten;
      }
    }
    return (verstuurd: verstuurd / 60, concept: concept / 60);
  }

  /// De app-uren van deze monteur in de week van [maandag].
  Future<({double verstuurd, double concept})> appUren(DateTime maandag) async {
    final lokaal = await _lokaleKaarten();
    final firestore = await _firestoreKaarten();
    final uit = tel([...lokaal, ...firestore], maandag);
    debugPrint(
      '[weekuren] medewerker ${AuthService.instance.currentMechanicId}: '
      'lokaal ${lokaal.length} kaarten, firestore ${firestore.length} '
      'kaarten -> verstuurd ${uit.verstuurd}u, concept ${uit.concept}u',
    );
    return tel([...lokaal, ...firestore], maandag);
  }

  Future<List<WeekUrenKaart>> _lokaleKaarten() async {
    final prefs = await SharedPreferences.getInstance();
    final ik = AuthService.instance.currentMechanicId;
    final result = <WeekUrenKaart>[];
    for (final sleutel in prefs.getKeys()) {
      if (!sleutel.startsWith(_conceptPrefix)) continue;
      if (sleutel == '${_conceptPrefix}indirect') continue;
      try {
        final raw = prefs.getString(sleutel);
        if (raw == null) continue;
        final days =
            ((jsonDecode(raw) as Map<String, dynamic>)['days'] as Map?) ??
            const {};
        for (final dag in days.entries) {
          final p = (dag.key as String).split('-').map(int.parse).toList();
          final datum = DateTime(p[0], p[1], p[2]);
          for (final c in ((dag.value as Map)['cards'] as List?) ?? const []) {
            final kaart = c as Map;
            if (kaart['type'] == kmCardType) continue;

            final eigenaar = (kaart['monteurId'] as num?)?.toInt();
            if (ik == null || eigenaar != ik) continue;
            result.add(
              WeekUrenKaart(
                id: kaart['id'] as String,
                datum: datum,
                minuten: (kaart['minutes'] as num).toInt(),
                verstuurd: kaart['submitted'] == true,
              ),
            );
          }
        }
      } catch (e) {
        debugPrint('Weekuren: concept $sleutel overgeslagen: $e');
      }
    }
    return result;
  }

  /// Uren uit Firestore (bijv. ingevoerd op een ander toestel). Lukt dat
  /// niet — geen verbinding, of de index ontbreekt nog — dan alleen lokaal.
  Future<List<WeekUrenKaart>> _firestoreKaarten() async {
    final ik = AuthService.instance.currentMechanicId;
    if (ik == null || !FirebaseBootstrap.isSignedIn) return const [];
    try {
      final regels = await FirestoreBonDraftRepository.instance
          .haalEigenUrenRegels(ik)
          .timeout(const Duration(seconds: 6));
      return [
        for (final r in regels)
          if (r.datum != null)
            WeekUrenKaart(
              id: r.id,
              datum: r.datum!,
              minuten: r.minuten ?? 0,
              verstuurd: r.status == BonRegelStatus.verstuurd,
            ),
      ];
    } catch (e) {
      debugPrint('[Firebase] weekuren niet opgehaald (alleen lokaal): $e');
      return const [];
    }
  }
}
