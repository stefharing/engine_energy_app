import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/auth_service.dart';
import '../../../core/firebase/firebase_bootstrap.dart';
import '../../bon_sync/data/bon_draft_repository.dart';
import '../../bon_sync/data/firestore_bon_draft_repository.dart';
import '../../bon_sync/models/bon_regel.dart';
import '../models/scanned_extra.dart';

/// Eén plek voor de extra (niet door kantoor geplande) artikelen van een
/// bon, zodat [PartsListScreen], [UsedMaterialsScreen], [BonDetailScreen]
/// en het afronden allemaal hetzelfde zien.
///
/// **Gedeeld (Firebase ingelogd):** elk artikel is een eigen regel in
/// Firestore (`servicebonnen/{bon}/regels`), zichtbaar voor alle monteurs op
/// de bon en bestand tegen crashes en een ander toestel. Oude lokale
/// concepten worden bij het eerste gebruik éénmalig overgezet.
///
/// **Lokaal (Firebase niet beschikbaar):** zoals voorheen in
/// SharedPreferences onder `extra_scanned_<orderId>`, alleen op dit toestel.
///
/// Schermen luisteren via [watch] en passen artikelen aan met [voegToe],
/// [bewaar] en [verwijder] — nooit door de hele lijst te overschrijven,
/// anders zou je de artikelen van een collega kunnen wissen.
class ExtrasDraftService {
  ExtrasDraftService._({BonDraftRepository? repository})
    : _repoOverride = repository;

  static final instance = ExtrasDraftService._();

  static const _uuid = Uuid();

  final BonDraftRepository? _repoOverride;
  BonDraftRepository get _repo =>
      _repoOverride ?? FirestoreBonDraftRepository.instance;

  /// Laatst bekende regels per bon, om bij aanpassen de originele regel
  /// (aanmaakdatum, monteur) te behouden.
  final _regelCache = <String, Map<String, BonRegel>>{};

  /// Wijzigingsmeldingen voor de lokale (niet-gedeelde) modus.
  final _lokaal = <String, StreamController<List<ScannedExtra>>>{};

  static String lokaleSleutel(String orderId) => 'extra_scanned_$orderId';
  static String _gemigreerdSleutel(String orderId) =>
      'extra_scanned_gemigreerd_$orderId';

  /// Worden artikelen gedeeld via Firestore, of alleen lokaal bewaard?
  bool get isGedeeld => FirebaseBootstrap.isSignedIn;

  /// Hoort [extra] bij de monteur die nu is ingelogd? Alleen die regels
  /// worden opgehoogd bij opnieuw scannen van hetzelfde artikel.
  bool isVanMij(ScannedExtra extra) =>
      extra.monteurId == null ||
      extra.monteurId == AuthService.instance.currentMechanicId;

  // ---------------------------------------------------------------- lezen

  /// Live lijst artikelen van de bon (van alle monteurs), oudste eerst.
  Stream<List<ScannedExtra>> watch(String orderId) async* {
    if (!isGedeeld) {
      yield await _leesLokaal(orderId);
      yield* _lokaleController(orderId).stream;
      return;
    }
    await migreer(orderId);
    yield* _repo
        .watchRegels(orderId)
        .map((regels) => _naarExtras(orderId, regels));
  }

  /// Eenmalig de huidige artikelen ophalen.
  Future<List<ScannedExtra>> load(String orderId) async {
    if (!isGedeeld) return _leesLokaal(orderId);
    await migreer(orderId);
    return _naarExtras(orderId, await _repo.haalRegels(orderId));
  }

  List<ScannedExtra> _naarExtras(String orderId, List<BonRegel> regels) {
    final artikelen = regels
        .where((r) => r.type == BonRegelType.artikel && !r.verwijderd)
        .toList();
    _regelCache[orderId] = {for (final r in artikelen) r.id: r};
    return artikelen.map((r) => r.toScannedExtra()).toList();
  }

  // ------------------------------------------------------------ schrijven

  /// Voegt een nieuw artikel toe (als regel van de ingelogde monteur).
  Future<ScannedExtra> voegToe(
    String orderId,
    Map<String, dynamic> item,
    int aantal,
  ) async {
    final ik = _ik();
    final extra = ScannedExtra(
      item: item,
      scannedCount: aantal,
      regelId: _uuid.v4(),
      monteurId: ik.id,
      monteurNaam: ik.naam,
    );
    if (!isGedeeld) {
      debugPrint(
        '[Firebase] artikel alleen LOKAAL opgeslagen '
        '(Firebase gestart: ${FirebaseBootstrap.isReady}, '
        'ingelogd: ${FirebaseBootstrap.isSignedIn})',
      );
      final lijst = await _leesLokaal(orderId);
      await _schrijfLokaal(orderId, [...lijst, extra]);
      return extra;
    }
    final regel = BonRegel.artikel(
      id: extra.regelId!,
      monteurId: ik.id,
      monteurNaam: ik.naam,
      item: item,
      aantal: aantal,
    );
    (_regelCache[orderId] ??= {})[regel.id] = regel;
    await _repo.bewaarRegel(orderId, regel);
    return extra;
  }

  /// Slaat een gewijzigd aantal van een bestaand artikel op.
  Future<void> bewaar(String orderId, ScannedExtra extra) async {
    if (!isGedeeld) {
      final lijst = await _leesLokaal(orderId);
      await _schrijfLokaal(orderId, [
        for (final e in lijst) e.regelId == extra.regelId ? extra : e,
      ]);
      return;
    }
    final origineel = _regelCache[orderId]?[extra.regelId];
    final regel = origineel != null
        ? origineel.copyWith(aantal: extra.scannedCount)
        : _nieuweRegelVoor(extra);
    (_regelCache[orderId] ??= {})[regel.id] = regel;
    await _repo.bewaarRegel(orderId, regel);
  }

  /// Verwijdert een artikel (voor iedereen op de bon).
  Future<void> verwijder(String orderId, ScannedExtra extra) async {
    if (!isGedeeld) {
      final lijst = await _leesLokaal(orderId);
      await _schrijfLokaal(orderId, [
        for (final e in lijst)
          if (e.regelId != extra.regelId) e,
      ]);
      return;
    }
    final origineel =
        _regelCache[orderId]?[extra.regelId] ?? _nieuweRegelVoor(extra);
    _regelCache[orderId]?.remove(origineel.id);
    await _repo.verwijderRegel(orderId, origineel);
  }

  BonRegel _nieuweRegelVoor(ScannedExtra extra) {
    final ik = _ik();
    return BonRegel.artikel(
      id: extra.regelId ?? _uuid.v4(),
      monteurId: extra.monteurId ?? ik.id,
      monteurNaam: extra.monteurNaam ?? ik.naam,
      item: extra.item,
      aantal: extra.scannedCount,
    );
  }

  // ------------------------------------------------------------ migratie

  /// Zet lokale, nog niet gepubliceerde artikelen van vóór Firestore over
  /// naar de gedeelde opslag. Idempotent: elke regel krijgt een vast id en
  /// wordt onthouden, zodat hij nooit twee keer wordt overgezet. De lokale
  /// gegevens blijven staan (niets gaat verloren).
  Future<void> migreer(String orderId) async {
    if (!isGedeeld) return;
    final ik = AuthService.instance.currentEmployee;
    if (ik == null) return;
    final prefs = await SharedPreferences.getInstance();
    final lokaal = await _leesLokaal(orderId); // geeft elke regel een id
    final gedaan =
        (prefs.getStringList(_gemigreerdSleutel(orderId)) ?? const [])
            .toSet();
    final teDoen = lokaal.where(
      (e) =>
          e.ridderId == null &&
          e.needsPublication &&
          !gedaan.contains(e.regelId),
    );
    for (final e in teDoen) {
      try {
        await _repo.bewaarRegel(
          orderId,
          BonRegel.artikel(
            id: e.regelId!,
            monteurId: e.monteurId ?? ik.id,
            monteurNaam: e.monteurNaam ?? ik.name,
            item: e.item,
            aantal: e.scannedCount,
          ),
        );
        gedaan.add(e.regelId!);
      } catch (err) {
        debugPrint('Artikel ${e.regelId} niet overgezet: $err');
      }
    }
    await prefs.setStringList(_gemigreerdSleutel(orderId), gedaan.toList());
  }

  // --------------------------------------------------------------- lokaal

  Future<List<ScannedExtra>> _leesLokaal(String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(lokaleSleutel(orderId)) ?? '[]';
    final lijst = (jsonDecode(raw) as List)
        .map((v) => ScannedExtra.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    // Oude concepten hebben nog geen id; geef ze er één en bewaar dat, zodat
    // het id stabiel blijft (nodig voor bewerken en de migratie).
    if (lijst.any((e) => e.regelId == null)) {
      final metId = [
        for (final e in lijst)
          e.regelId == null ? e.copyWith(regelId: _uuid.v4()) : e,
      ];
      await prefs.setString(
        lokaleSleutel(orderId),
        jsonEncode(metId.map((e) => e.toJson()).toList()),
      );
      return metId;
    }
    return lijst;
  }

  Future<void> _schrijfLokaal(String orderId, List<ScannedExtra> lijst) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      lokaleSleutel(orderId),
      jsonEncode(lijst.map((e) => e.toJson()).toList()),
    );
    _lokaleController(orderId).add(lijst);
  }

  /// Markeert lokale artikelen als gepubliceerd (alleen lokale modus).
  Future<void> markeerLokaalGepubliceerd(
    String orderId,
    Iterable<ScannedExtra> gepubliceerd,
  ) async {
    final ids = gepubliceerd.map((e) => e.regelId).toSet();
    final lijst = await _leesLokaal(orderId);
    await _schrijfLokaal(orderId, [
      for (final e in lijst)
        ids.contains(e.regelId) ? e.copyWith(syncedQuantity: e.scannedCount) : e,
    ]);
  }

  StreamController<List<ScannedExtra>> _lokaleController(String orderId) =>
      _lokaal.putIfAbsent(orderId, StreamController.broadcast);

  ({int id, String naam}) _ik() {
    final e = AuthService.instance.currentEmployee;
    if (e == null) {
      throw StateError('Geen monteur ingelogd.');
    }
    return (id: e.id, naam: e.name);
  }
}
