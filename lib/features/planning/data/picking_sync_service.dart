import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/auth_service.dart';
import '../../../core/firebase/firebase_bootstrap.dart';
import '../../bon_sync/data/bon_draft_repository.dart';
import '../../bon_sync/data/firestore_bon_draft_repository.dart';
import '../../bon_sync/models/picking_status.dart';

/// Deelt de pickstatus van de geplande onderdelen van een bon tussen alle
/// monteurs op die bon, via Firestore (`servicebonnen/{bon}/picking/status`).
///
/// De schermen blijven met de bestaande lokale sleutels werken:
/// * `scanned_counts_<orderId>` — gepickt aantal per onderdeel;
/// * `part_taken_<orderId>_<partId>` — onderdeel meegenomen;
/// * `parts_confirmed_<orderId>` — picken bevestigd.
///
/// Deze service houdt die in sync met Firestore:
/// * [haalOp] zet de gedeelde stand in de lokale sleutels (vóór tonen);
/// * [stuurDoor] zet lokale wijzigingen door — aantallen als verschil, zodat
///   twee monteurs die tegelijk picken elkaars telling niet overschrijven;
/// * [watch] geeft live updates als een collega pickt.
///
/// Zonder Firebase doet alles niets en werkt de app zoals voorheen.
class PickingSyncService {
  PickingSyncService._({BonDraftRepository? repository})
    : _repoOverride = repository;

  static final instance = PickingSyncService._();

  final BonDraftRepository? _repoOverride;
  BonDraftRepository get _repo =>
      _repoOverride ?? FirestoreBonDraftRepository.instance;

  /// Laatst bekende gedeelde stand per bon; basis voor de verschillen.
  final _cache = <String, PickingStatus>{};

  static String countsKey(String orderId) => 'scanned_counts_$orderId';
  static String takenKey(String orderId, String partId) =>
      'part_taken_${orderId}_$partId';
  static String confirmedKey(String orderId) => 'parts_confirmed_$orderId';

  bool get isGedeeld =>
      FirebaseBootstrap.isSignedIn &&
      AuthService.instance.currentEmployee != null;

  /// Haalt de gedeelde pickstatus op en zet die in de lokale sleutels.
  /// Lokale pickgegevens die Firestore nog niet kent (bijv. van vóór
  /// Firebase) worden daarna alsnog doorgestuurd.
  Future<void> haalOp(String orderId) async {
    if (!isGedeeld) return;
    final PickingStatus? gedeeld;
    try {
      gedeeld = await _repo
          .haalPicking(orderId)
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('[Firebase] pickstatus bon $orderId niet opgehaald: $e');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (gedeeld != null) {
      await _schrijfLokaal(prefs, orderId, gedeeld);
      _cache[orderId] = gedeeld;
    } else {
      // Nog niets gedeeld: alles wat lokaal staat is nieuw.
      _cache[orderId] = const PickingStatus();
    }
    await stuurDoor(orderId);
  }

  /// Zet lokale wijzigingen (na opslaan in de lokale sleutels) door.
  Future<void> stuurDoor(String orderId) async {
    if (!isGedeeld) return;
    final ik = AuthService.instance.currentEmployee!;
    final prefs = await SharedPreferences.getInstance();
    final basis = _cache[orderId];
    if (basis == null) {
      // Nog nooit opgehaald: eerst de gedeelde stand kennen, anders zouden
      // de verschillen niet kloppen. haalOp roept stuurDoor zelf weer aan.
      await haalOp(orderId);
      return;
    }
    final lokaal = _leesLokaal(prefs, orderId);

    final delta = <String, int>{};
    for (final id in {...lokaal.aantallen.keys, ...basis.aantallen.keys}) {
      final d = (lokaal.aantallen[id] ?? 0) - (basis.aantallen[id] ?? 0);
      if (d != 0) delta[id] = d;
    }
    final nieuwGepakt = lokaal.gepakt.difference(basis.gepakt);
    final nieuwBevestigd = lokaal.bevestigd && !basis.bevestigd;
    if (delta.isEmpty && nieuwGepakt.isEmpty && !nieuwBevestigd) return;

    _cache[orderId] = PickingStatus(
      aantallen: lokaal.aantallen,
      gepakt: {...basis.gepakt, ...lokaal.gepakt},
      bevestigd: basis.bevestigd || lokaal.bevestigd,
    );
    try {
      await _repo.wijzigPicking(
        orderId,
        delta: delta,
        gepakt: nieuwGepakt,
        bevestigd: nieuwBevestigd,
        monteurId: ik.id,
        monteurNaam: ik.name,
      );
    } catch (e) {
      debugPrint('[Firebase] pickstatus bon $orderId niet doorgestuurd: $e');
    }
  }

  /// Live pickstatus (inclusief wat collega's picken). Houdt ook de lokale
  /// sleutels bij, zodat andere schermen dezelfde stand zien.
  Stream<PickingStatus> watch(String orderId) {
    if (!isGedeeld) return const Stream.empty();
    return _repo.watchPicking(orderId).where((s) => s != null).asyncMap((
      s,
    ) async {
      final status = s!;
      _cache[orderId] = status;
      await _schrijfLokaal(
        await SharedPreferences.getInstance(),
        orderId,
        status,
      );
      return status;
    });
  }

  // --------------------------------------------------------------- lokaal

  PickingStatus _leesLokaal(SharedPreferences prefs, String orderId) {
    final raw = prefs.getString(countsKey(orderId)) ?? '{}';
    final aantallen = (jsonDecode(raw) as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, (v as num).toInt()),
    )..removeWhere((_, v) => v <= 0);
    final prefix = 'part_taken_${orderId}_';
    final gepakt = {
      for (final k in prefs.getKeys())
        if (k.startsWith(prefix) && (prefs.getBool(k) ?? false))
          k.substring(prefix.length),
    };
    return PickingStatus(
      aantallen: aantallen,
      gepakt: gepakt,
      bevestigd: prefs.getBool(confirmedKey(orderId)) ?? false,
    );
  }

  Future<void> _schrijfLokaal(
    SharedPreferences prefs,
    String orderId,
    PickingStatus status,
  ) async {
    await prefs.setString(countsKey(orderId), jsonEncode(status.aantallen));
    for (final id in status.gepakt) {
      await prefs.setBool(takenKey(orderId, id), true);
    }
    if (status.bevestigd) {
      await prefs.setBool(confirmedKey(orderId), true);
    }
  }
}
