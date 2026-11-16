import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/auth_service.dart';
import '../../../core/firebase/firebase_bootstrap.dart';
import '../../bon_sync/data/bon_draft_repository.dart';
import '../../bon_sync/data/firestore_bon_draft_repository.dart';
import '../../bon_sync/models/bon_regel.dart';
import '../screens/hours_week_screen.dart' show hoursDraftKeyForOrder;
import 'hours_draft_service.dart' show kmCardType;

/// Spiegelt het lokale urenconcept van een bon (de uren- en km-kaarten uit
/// `HoursWeekScreen`, opgeslagen onder [hoursDraftKeyForOrder]) naar de
/// gedeelde tussenopslag in Firestore.
///
/// Uren zijn **per monteur**: Ridder boekt ze op de eigen afspraak van de
/// monteur, dus iedereen publiceert zijn eigen uren. Deze service haalt en
/// schrijft daarom alleen regels van de ingelogde monteur — collega's zien
/// elkaars uren niet in de app. Wel overleven de uren zo een crash, en zie
/// je ze terug als je op een ander toestel inlogt.
///
/// Het lokale concept blijft het werkformaat van de schermen; deze service:
/// * [haalOp]: voegt de Firestore-versie samen met het lokale concept
///   (vóór tonen of publiceren);
/// * [stuurDoor]: zet lokale wijzigingen door naar Firestore (na opslaan);
/// * [markeerVerstuurd]: na een geslaagde publicatie.
///
/// Zonder Firebase (niet gestart of niet ingelogd) doet alles niets en
/// werkt de app zoals voorheen, alleen lokaal.
class HoursSyncService {
  HoursSyncService._({BonDraftRepository? repository})
    : _repoOverride = repository;

  static final instance = HoursSyncService._();

  final BonDraftRepository? _repoOverride;
  BonDraftRepository get _repo =>
      _repoOverride ?? FirestoreBonDraftRepository.instance;

  /// Laatst bekende eigen (niet-verwijderde) regels per bon.
  final _cache = <String, Map<String, BonRegel>>{};

  /// Kaarten die ooit in Firestore zijn gezien. Verdwijnt zo'n kaart daar,
  /// dan is hij op een ander toestel verwijderd — niet "nog niet geüpload".
  static String _gezienSleutel(String orderId) => 'hours_synced_ids_$orderId';

  /// Of er naar Firestore gesynchroniseerd kan worden. Was het anonieme
  /// inloggen bij het starten nog niet gelukt (bijv. geen bereik), dan
  /// wordt het hier alsnog geprobeerd — anders bleef synchroniseren de hele
  /// sessie stilzwijgend uit.
  Future<bool> _klaar() async {
    if (AuthService.instance.currentEmployee == null) return false;
    if (FirebaseBootstrap.isSignedIn) return true;
    try {
      await FirebaseBootstrap.ensureSignedIn().timeout(
        const Duration(seconds: 5),
      );
      return true;
    } catch (e) {
      debugPrint('[Firebase] uren niet gesynchroniseerd, niet ingelogd: $e');
      return false;
    }
  }

  // ------------------------------------------------------------- ophalen

  /// Haalt de eigen uren/km van deze bon uit Firestore en voegt ze samen
  /// met het lokale concept, dat daarna is bijgewerkt. Lokale kaarten die
  /// nog nooit in Firestore stonden, worden alsnog doorgestuurd.
  ///
  /// Mislukt ophalen (geen verbinding, niets in de cache), dan blijft het
  /// lokale concept ongewijzigd.
  Future<void> haalOp(String orderId) async {
    if (!await _klaar()) return;
    final ik = AuthService.instance.currentEmployee!.id;

    final List<BonRegel> regels;
    try {
      regels = await _repo
          .haalRegels(orderId, inclusiefVerwijderd: true)
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('[Firebase] uren van bon $orderId niet opgehaald: $e');
      return;
    }
    final mijn = regels.where(
      (r) => r.type != BonRegelType.artikel && r.monteurId == ik,
    );
    final inFirestore = <String, BonRegel>{};
    final verwijderd = <String>{};
    for (final r in mijn) {
      if (r.verwijderd) {
        verwijderd.add(r.id);
      } else {
        inFirestore[r.id] = r;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final lokaal = _leesKaarten(prefs, orderId);
    // Kaarten van anderen op dit toestel blijven ongemoeid in het concept.
    final vreemd = _leesKaarten(prefs, orderId, eigen: false);
    final gezien =
        (prefs.getStringList(_gezienSleutel(orderId)) ?? const []).toSet();

    final samengevoegd = <String, List<Map<String, dynamic>>>{};
    void voegToe(String dag, Map<String, dynamic> kaart) =>
        (samengevoegd[dag] ??= []).add(kaart);

    // 1. Firestore is leidend voor alles wat daar staat…
    final lokaalPerId = {for (final k in lokaal) k.kaart['id'] as String: k};
    for (final r in inFirestore.values) {
      final kaart = _kaartVan(r);
      // …behalve dat een lokaal al verstuurde kaart verstuurd blijft (als
      // het markeren in Firestore nog onderweg is, niet opnieuw publiceren).
      if (lokaalPerId[r.id]?.kaart['submitted'] == true) {
        kaart['submitted'] = true;
      }
      voegToe(_dagSleutel(r.datum!), kaart);
    }
    // 2. …plus lokale kaarten die Firestore nog niet kent.
    for (final k in lokaal) {
      final id = k.kaart['id'] as String;
      if (inFirestore.containsKey(id)) continue;
      if (verwijderd.contains(id)) continue; // elders verwijderd
      if (gezien.contains(id)) continue; // stond er, nu weg: elders verwijderd
      voegToe(k.dag, k.kaart);
    }

    for (final k in vreemd) {
      voegToe(k.dag, k.kaart);
    }
    await prefs.setString(
      hoursDraftKeyForOrder(orderId),
      jsonEncode({
        'days': {
          for (final e in samengevoegd.entries) e.key: {'cards': e.value},
        },
      }),
    );
    await prefs.setStringList(
      _gezienSleutel(orderId),
      {...gezien, ...inFirestore.keys}.toList(),
    );
    _cache[orderId] = Map.of(inFirestore);

    await stuurDoor(orderId);
  }

  // -------------------------------------------------------------- opslaan

  /// Zet het lokale concept door naar Firestore: nieuwe en gewijzigde
  /// kaarten opslaan, lokaal verwijderde kaarten als verwijderd markeren.
  /// Werkt ook offline (Firestore zet het in de wachtrij).
  Future<void> stuurDoor(String orderId) async {
    if (!await _klaar()) return;
    final ik = AuthService.instance.currentEmployee!;
    final prefs = await SharedPreferences.getInstance();
    final lokaal = _leesKaarten(prefs, orderId);
    final cache = _cache[orderId] ??= {};

    try {
      final lokaleIds = <String>{};
      for (final k in lokaal) {
        final id = k.kaart['id'] as String;
        lokaleIds.add(id);
        if (k.kaart['submitted'] == true) continue;
        final gewenst = _regelVan(k, ik.id, ik.name, cache[id]);
        if (_zelfde(cache[id], gewenst)) continue;
        cache[id] = gewenst;
        await _repo.bewaarRegel(orderId, gewenst);
        debugPrint(
          '[Firebase] uren bon $orderId: kaart $id doorgestuurd '
          '(${gewenst.minuten} min, ${gewenst.datum})',
        );
      }
      final weg = cache.values
          .where((r) => r.isConcept && !lokaleIds.contains(r.id))
          .toList();
      for (final r in weg) {
        cache.remove(r.id);
        await _repo.verwijderRegel(orderId, r);
        debugPrint('[Firebase] uren bon $orderId: kaart ${r.id} verwijderd');
      }
    } catch (e) {
      debugPrint('[Firebase] uren van bon $orderId niet doorgestuurd: $e');
    }
  }

  /// Na een geslaagde Ridder-publicatie: markeert de meegestuurde kaarten
  /// ook in Firestore als verstuurd. Mag het afronden niet laten mislukken.
  Future<void> markeerVerstuurd(String orderId, Iterable<String> ids) async {
    if (!await _klaar()) return;
    final cache = _cache[orderId];
    if (cache == null) return;
    // Alleen regels die in Firestore bestaan; een update op een
    // onbekend document zou de hele batch laten mislukken.
    final lijst = ids.where(cache.containsKey).toList();
    if (lijst.isEmpty) return;
    for (final id in lijst) {
      cache[id] = cache[id]!.copyWith(status: BonRegelStatus.verstuurd);
    }
    try {
      await _repo
          .markeerVerstuurd(orderId, lijst)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      // Offline: staat in de wachtrij. De lokale 'submitted'-vlag voorkomt
      // intussen dubbel publiceren (zie haalOp).
      debugPrint('[Firebase] uren van bon $orderId niet als verstuurd '
          'gemarkeerd: $e');
    }
  }

  // ------------------------------------------------------------- omzetten

  static String _dagSleutel(DateTime d) => '${d.year}-${d.month}-${d.day}';

  static DateTime _dagVan(String sleutel) {
    final p = sleutel.split('-').map(int.parse).toList();
    return DateTime(p[0], p[1], p[2]);
  }

  /// Een kaart in het formaat van `_HourCard.toDraftJson`.
  static Map<String, dynamic> _kaartVan(BonRegel r) => {
    'id': r.id,
    if (r.type == BonRegelType.km) 'type': kmCardType,
    'workActivityId': r.workActivityId ?? 0,
    if (r.workActivityCode != null) 'workActivityCode': r.workActivityCode,
    'minutes': r.type == BonRegelType.km ? 0 : (r.minuten ?? 0),
    if (r.type == BonRegelType.km) 'km': r.km ?? 0,
    'memo': r.memo,
    'submitted': r.status == BonRegelStatus.verstuurd,
    'monteurId': r.monteurId,
  };

  static BonRegel _regelVan(
    _Kaart k,
    int monteurId,
    String monteurNaam,
    BonRegel? bestaand,
  ) {
    final kaart = k.kaart;
    final isKm = kaart['type'] == kmCardType;
    final datum = _dagVan(k.dag);
    if (bestaand != null) {
      return bestaand.copyWith(
        datum: datum,
        minuten: isKm ? null : kaart['minutes'] as int,
        workActivityId: isKm ? null : kaart['workActivityId'] as int,
        workActivityCode: isKm ? null : kaart['workActivityCode'] as String?,
        km: isKm ? kaart['km'] as int : null,
        // Leeg ('' i.p.v. null), zodat een gewiste memo ook in Firestore
        // gewist wordt — copyWith(memo: null) laat de oude staan.
        memo: (kaart['memo'] as String?) ?? '',
      );
    }
    final id = kaart['id'] as String;
    return isKm
        ? BonRegel.km(
            id: id,
            monteurId: monteurId,
            monteurNaam: monteurNaam,
            datum: datum,
            km: kaart['km'] as int,
          ).copyWith(memo: kaart['memo'] as String?)
        : BonRegel.uren(
            id: id,
            monteurId: monteurId,
            monteurNaam: monteurNaam,
            datum: datum,
            workActivityId: kaart['workActivityId'] as int,
            workActivityCode: kaart['workActivityCode'] as String?,
            minuten: kaart['minutes'] as int,
            memo: kaart['memo'] as String?,
          );
  }

  static bool _zelfde(BonRegel? a, BonRegel b) =>
      a != null &&
      !a.verwijderd &&
      a.datum == b.datum &&
      a.minuten == b.minuten &&
      a.workActivityId == b.workActivityId &&
      a.workActivityCode == b.workActivityCode &&
      a.km == b.km &&
      (a.memo ?? '') == (b.memo ?? '');

  static List<_Kaart> _leesKaarten(
    SharedPreferences prefs,
    String orderId, {
    bool eigen = true,
  }) {
    final raw = prefs.getString(hoursDraftKeyForOrder(orderId));
    if (raw == null) return const [];
    final draft = jsonDecode(raw) as Map<String, dynamic>;
    final days = (draft['days'] as Map<String, dynamic>?) ?? const {};
    // Het lokale concept van een bon kan kaarten van meerdere medewerkers op
    // dit toestel bevatten. Alleen de eigen kaarten (met eigenaar) gaan naar
    // Firestore, anders worden uren van een ander als de mijne opgeslagen.
    final ik = AuthService.instance.currentMechanicId;
    return [
      for (final dag in days.entries)
        for (final c in ((dag.value as Map)['cards'] as List?) ?? const [])
          if (((c as Map)['monteurId'] == ik && ik != null) == eigen)
            _Kaart(dag.key, Map<String, dynamic>.from(c)),
    ];
  }
}

class _Kaart {
  const _Kaart(this.dag, this.kaart);
  final String dag;
  final Map<String, dynamic> kaart;
}
