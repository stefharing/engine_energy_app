import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/auth_service.dart';
import '../../../core/firebase/firebase_bootstrap.dart';
import '../../bon_sync/data/firestore_bon_draft_repository.dart';
import '../../bon_sync/models/bon_regel.dart';
import '../../planning/data/hours_draft_service.dart' show kmCardType;
import '../models/uren_overzicht.dart';
import 'uren_samenvoegen.dart';

/// Wat de monteur zelf in de app heeft ingevoerd: uren en km, per bon.
class AppRegistraties {
  const AppRegistraties({this.uren = const [], this.km = const []});

  final List<AppUren> uren;
  final List<KmRegel> km;
}

/// Leest de uren en km uit de lokale concepten op dit toestel
/// (`hours_week_draft_<bon>`), aangevuld met Firestore (andere toestellen).
class AppUrenBron {
  AppUrenBron._();
  static final instance = AppUrenBron._();

  static const _conceptPrefix = 'hours_week_draft_';

  Future<AppRegistraties> lees() async {
    final ik = AuthService.instance.currentMechanicId;
    if (ik == null) return const AppRegistraties();
    final lokaal = await _lokaal(ik);
    final firestore = await _firestore(ik);
    return AppRegistraties(
      uren: _uniek<AppUren>([...lokaal.uren, ...firestore.uren], (u) => u.id),
      km: _uniek<KmRegel>([...lokaal.km, ...firestore.km], (k) => k.id),
    );
  }

  static List<T> _uniek<T>(Iterable<T> lijst, String Function(T) id) {
    final gezien = <String>{};
    return [
      for (final x in lijst)
        if (gezien.add(id(x))) x,
    ];
  }

  Future<AppRegistraties> _lokaal(int ik) async {
    final prefs = await SharedPreferences.getInstance();
    final uren = <AppUren>[];
    final km = <KmRegel>[];
    for (final sleutel in prefs.getKeys()) {
      if (!sleutel.startsWith(_conceptPrefix)) continue;
      final bonId = sleutel.substring(_conceptPrefix.length);
      if (bonId == 'indirect' || bonId.isEmpty) continue;
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
            if ((kaart['monteurId'] as num?)?.toInt() != ik) continue;
            final id = kaart['id'] as String;
            final verstuurd = kaart['submitted'] == true;
            if (kaart['type'] == kmCardType) {
              km.add(
                KmRegel(
                  id: id,
                  datum: datum,
                  km: (kaart['km'] as num?)?.toInt() ?? 0,
                  verstuurd: verstuurd,
                  bonId: bonId,
                ),
              );
            } else {
              uren.add(
                AppUren(
                  id: id,
                  datum: datum,
                  minuten: (kaart['minutes'] as num?)?.toInt() ?? 0,
                  verstuurd: verstuurd,
                  bonId: bonId,
                ),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('Urenoverzicht: concept $sleutel overgeslagen: $e');
      }
    }
    return AppRegistraties(uren: uren, km: km);
  }

  /// Lukt Firestore niet (offline, index ontbreekt), dan blijft het lokaal.
  Future<AppRegistraties> _firestore(int ik) async {
    if (!FirebaseBootstrap.isSignedIn) return const AppRegistraties();
    try {
      final regels = await FirestoreBonDraftRepository.instance
          .haalEigenUrenEnKmRegels(ik)
          .timeout(const Duration(seconds: 6));
      final uren = <AppUren>[];
      final km = <KmRegel>[];
      for (final r in regels) {
        final datum = r.regel.datum;
        if (datum == null) continue;
        final verstuurd = r.regel.status == BonRegelStatus.verstuurd;
        if (r.regel.type == BonRegelType.km) {
          km.add(
            KmRegel(
              id: r.regel.id,
              datum: datum,
              km: r.regel.km ?? 0,
              verstuurd: verstuurd,
              bonId: r.bonId,
            ),
          );
        } else {
          uren.add(
            AppUren(
              id: r.regel.id,
              datum: datum,
              minuten: r.regel.minuten ?? 0,
              verstuurd: verstuurd,
              bonId: r.bonId,
            ),
          );
        }
      }
      return AppRegistraties(uren: uren, km: km);
    } catch (e) {
      debugPrint('[Firebase] urenoverzicht niet opgehaald (alleen lokaal): $e');
      return const AppRegistraties();
    }
  }
}
