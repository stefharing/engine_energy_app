import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_service.dart';
import '../../planning/data/planning_repository.dart';
import '../../planning/models/job_order.dart';
import '../models/uren_overzicht.dart';
import 'app_uren_bron.dart';
import 'uren_samenvoegen.dart';

/// Bouwt het urenoverzicht voor een week of maand: Ridder (goedgekeurd,
/// inclusief indirect) plus wat in de app is ingevoerd.
class UrenOverzichtService {
  UrenOverzichtService._();
  static final instance = UrenOverzichtService._();

  List<ServiceOrder>? _bonnen;

  /// De bonnen van de ingelogde monteur (voor titels en de bonkeuze).
  Future<List<ServiceOrder>> bonnen({bool vernieuw = false}) async {
    if (_bonnen != null && !vernieuw) return _bonnen!;
    final ik = AuthService.instance.currentMechanicId;
    try {
      final alle = await PlanningRepository.instance.fetchServiceOrders();
      _bonnen = [
        for (final o in alle)
          if (ik == null || o.isAssignedTo(ik)) o,
      ];
    } catch (e) {
      debugPrint('[urenoverzicht] bonnen niet geladen: $e');
      _bonnen ??= const [];
    }
    return _bonnen!;
  }

  Future<PeriodeOverzicht> laad({
    required DateTime start,
    required DateTime eindExcl,
  }) async {
    final ik = AuthService.instance.currentMechanicId;
    if (ik == null) throw StateError('Je bent niet ingelogd.');
    final van = alleenDatum(start);

    final resultaten = await Future.wait([
      _ridder(ik, van, eindExcl),
      AppUrenBron.instance.lees(),
      bonnen(),
    ]);
    final ridder = resultaten[0] as List<RidderUren>?;
    final app = resultaten[1] as AppRegistraties;
    final bonnenLijst = resultaten[2] as List<ServiceOrder>;
    final titels = {
      for (final b in bonnenLijst) b.id: _bonTitel(b),
    };

    bool binnen(DateTime d) {
      final dd = alleenDatum(d);
      return !dd.isBefore(van) && dd.isBefore(eindExcl);
    }

    final uren = voegUrenSamen(
      ridder: ridder ?? const [],
      app: app.uren.where((u) => binnen(u.datum)),
    );
    final metTitel = [
      for (final u in uren)
        u.titel != null || u.bonId == null
            ? u
            : u.metTitel(titels[u.bonId] ?? 'Bon ${u.bonId}'),
    ];
    return PeriodeOverzicht.van(
      start: van,
      eindExcl: eindExcl,
      uren: metTitel,
      km: app.km.where((k) => binnen(k.datum)),
      ridderBekend: ridder != null,
    );
  }

  static String _bonTitel(ServiceOrder o) {
    final klant = o.relationName.trim();
    return klant.isEmpty ? o.orderNumber : '${o.orderNumber} · $klant';
  }

  /// `null` als Ridder niet bereikbaar is.
  Future<List<RidderUren>?> _ridder(
    int ik,
    DateTime van,
    DateTime eindExcl,
  ) async {
    try {
      final entries = await PlanningRepository.instance
          .fetchProjectTimesForEmployee(ik, from: van);
      return ridderUitEntries(entries, van: van, eindExcl: eindExcl);
    } catch (e) {
      debugPrint('[urenoverzicht] Ridder niet bereikbaar: $e');
      return null;
    }
  }

  /// Zet Ridder-projecttijden om naar [RidderUren] binnen de periode.
  @visibleForTesting
  static List<RidderUren> ridderUitEntries(
    Iterable<Map<String, dynamic>> entries, {
    required DateTime van,
    required DateTime eindExcl,
  }) {
    final uit = <RidderUren>[];
    for (final e in entries) {
      final datum = DateTime.tryParse(e['date'] as String? ?? '');
      if (datum == null) continue;
      final dag = alleenDatum(datum);
      if (dag.isBefore(van) || !dag.isBefore(eindExcl)) continue;
      final minuten = parseMinuten(e['timeemployee'] as String? ?? '');
      if (minuten <= 0) continue;
      final jo = e['joborder'];
      final bonId = jo is Map ? '${jo['id']}' : null;
      final w = e['workactivity'];
      final soortNaam = w is Map
          ? ((w['description'] ?? w['name'] ?? w['code']) as Object?)
          : null;
      uit.add(
        RidderUren(
          id: 'ridder-${e['id']}',
          datum: dag,
          minuten: minuten,
          soort: bonId == null ? UrenSoort.indirect : UrenSoort.project,
          bonId: bonId,
          titel: bonId == null ? soortNaam?.toString() : null,
        ),
      );
    }
    return uit;
  }

  /// "HH:MM:SS" → minuten.
  @visibleForTesting
  static int parseMinuten(String t) {
    final p = t.split(':');
    if (p.length < 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }
}
