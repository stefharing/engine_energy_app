import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/api/api_config.dart';
import '../../../core/firebase/firebase_bootstrap.dart';
import '../models/bon_regel.dart';
import '../models/picking_status.dart';
import '../models/servicebon_sync.dart';
import 'bon_draft_repository.dart';

/// Firestore-structuur:
///
/// ```
/// servicebonnen/{administratie}_{jobOrderId}
///   jobOrderId, administratie, status, monteurIds, bijgewerktOp,
///   afrondenDoorId, afrondenDoorNaam, afrondenGestartOp, afgerondOp
///   regels/{regelId}   → zie BonRegel.toMap()
/// ```
///
/// De bon-id bevat de Ridder-administratie, zodat een tweede administratie
/// later niet botst op dezelfde job order-nummers.
class FirestoreBonDraftRepository implements BonDraftRepository {
  FirestoreBonDraftRepository({FirebaseFirestore? firestore})
    : _dbOverride = firestore;

  static final instance = FirestoreBonDraftRepository();

  /// Na deze tijd mag een andere monteur een blijven hangende
  /// "bezig met afronden" overnemen (bijv. als de app crashte).
  static const claimVerloopt = Duration(minutes: 10);

  final FirebaseFirestore? _dbOverride;

  // Lui opgehaald: zonder gestarte Firebase mag alleen al het aanmaken van
  // deze repository niet crashen (bijv. in tests of de lokale modus).
  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;

  static String bonDocId(String jobOrderId) =>
      '${ApiConfig.administrationId}_$jobOrderId';

  DocumentReference<Map<String, dynamic>> _bon(String jobOrderId) =>
      _db.collection('servicebonnen').doc(bonDocId(jobOrderId));

  CollectionReference<Map<String, dynamic>> _regels(String jobOrderId) =>
      _bon(jobOrderId).collection('regels');

  @override
  Stream<List<BonRegel>> watchRegels(
    String jobOrderId, {
    bool inclusiefVerwijderd = false,
  }) {
    return _regels(jobOrderId).orderBy('aangemaaktOp').snapshots().map(
      (snap) => snap.docs
          .map((d) => BonRegel.fromMap(d.data()))
          .where((r) => inclusiefVerwijderd || !r.verwijderd)
          .toList(),
    );
  }

  @override
  Future<List<BonRegel>> haalRegels(
    String jobOrderId, {
    bool inclusiefVerwijderd = false,
  }) async {
    final snap = await _regels(jobOrderId).orderBy('aangemaaktOp').get();
    return snap.docs
        .map((d) => BonRegel.fromMap(d.data()))
        .where((r) => inclusiefVerwijderd || !r.verwijderd)
        .toList();
  }

  @override
  Stream<ServicebonSync?> watchBon(String jobOrderId) {
    return _bon(jobOrderId).snapshots().map((snap) {
      final d = snap.data();
      if (d == null) return null;
      return ServicebonSync(
        jobOrderId: jobOrderId,
        status: ServicebonSyncStatus.vanFirestore(d['status']),
        monteurIds: ((d['monteurIds'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        afrondenDoorId: (d['afrondenDoorId'] as num?)?.toInt(),
        afrondenDoorNaam: d['afrondenDoorNaam'] as String?,
        afrondenGestartOp: (d['afrondenGestartOp'] as Timestamp?)?.toDate(),
        afgerondOp: (d['afgerondOp'] as Timestamp?)?.toDate(),
      );
    });
  }

  @override
  Future<void> bewaarRegel(String jobOrderId, BonRegel regel) async {
    await FirebaseBootstrap.ensureSignedIn();
    final batch = _db.batch();
    // Kop aanmaken/bijwerken zonder de status aan te raken (merge).
    batch.set(_bon(jobOrderId), {
      'jobOrderId': jobOrderId,
      'administratie': ApiConfig.administrationId,
      'monteurIds': FieldValue.arrayUnion([regel.monteurId]),
      'bijgewerktOp': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    batch.set(_regels(jobOrderId).doc(regel.id), regel.toMap());
    debugPrint(
      '[Firebase] bonregel ${regel.id} opslaan in '
      'servicebonnen/${bonDocId(jobOrderId)}',
    );
    // Niet awaiten op de server: offline zou dit blijven hangen tot er
    // weer verbinding is. De lokale cache is direct bijgewerkt.
    unawaited(
      batch.commit().catchError((Object e) {
        debugPrint('[Firebase] bonregel ${regel.id} NIET opgeslagen: $e');
      }),
    );
  }

  @override
  Future<void> verwijderRegel(String jobOrderId, BonRegel regel) =>
      bewaarRegel(jobOrderId, regel.copyWith(verwijderd: true));

  @override
  Future<AfrondClaim> claimAfronden(
    String jobOrderId, {
    required int monteurId,
    required String monteurNaam,
  }) async {
    await FirebaseBootstrap.ensureSignedIn();
    return _db.runTransaction<AfrondClaim>((tx) async {
      final snap = await tx.get(_bon(jobOrderId));
      final d = snap.data() ?? const <String, dynamic>{};
      final status = ServicebonSyncStatus.vanFirestore(d['status']);

      if (status == ServicebonSyncStatus.afgerond) {
        return const AfrondClaimAlAfgerond();
      }
      if (status == ServicebonSyncStatus.bezigMetAfronden) {
        final sinds = (d['afrondenGestartOp'] as Timestamp?)?.toDate();
        final doorId = (d['afrondenDoorId'] as num?)?.toInt();
        final verlopen =
            sinds == null || DateTime.now().difference(sinds) > claimVerloopt;
        if (!verlopen && doorId != monteurId) {
          return AfrondClaimBezet(
            doorNaam: d['afrondenDoorNaam'] as String? ?? 'een collega',
            sinds: sinds,
          );
        }
      }

      tx.set(_bon(jobOrderId), {
        'jobOrderId': jobOrderId,
        'administratie': ApiConfig.administrationId,
        'status': ServicebonSyncStatus.bezigMetAfronden.firestoreWaarde,
        'afrondenDoorId': monteurId,
        'afrondenDoorNaam': monteurNaam,
        'afrondenGestartOp': FieldValue.serverTimestamp(),
        'bijgewerktOp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return const AfrondClaimGelukt();
    });
  }

  @override
  Future<void> bevestigAfgerond(
    String jobOrderId,
    Iterable<String> regelIds,
  ) async {
    await FirebaseBootstrap.ensureSignedIn();
    final nu = FieldValue.serverTimestamp();
    final ids = regelIds.toList();
    // Firestore staat max. 500 schrijfacties per batch toe; de kop telt mee.
    for (var i = 0; i < ids.length || i == 0; i += 450) {
      final batch = _db.batch();
      for (final id in ids.skip(i).take(450)) {
        batch.update(_regels(jobOrderId).doc(id), {
          'status': BonRegelStatus.verstuurd.name,
          'verstuurdOp': nu,
          'bijgewerktOp': nu,
        });
      }
      if (i + 450 >= ids.length) {
        batch.update(_bon(jobOrderId), {
          'status': ServicebonSyncStatus.afgerond.firestoreWaarde,
          'afgerondOp': nu,
          'bijgewerktOp': nu,
        });
      }
      await batch.commit();
    }
  }

  @override
  Future<void> markeerVerstuurd(
    String jobOrderId,
    Iterable<String> regelIds,
  ) async {
    await FirebaseBootstrap.ensureSignedIn();
    final ids = regelIds.toList();
    for (var i = 0; i < ids.length; i += 450) {
      final batch = _db.batch();
      for (final id in ids.skip(i).take(450)) {
        batch.update(_regels(jobOrderId).doc(id), {
          'status': BonRegelStatus.verstuurd.name,
          'verstuurdOp': FieldValue.serverTimestamp(),
          'bijgewerktOp': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    }
  }

  @override
  Future<List<BonRegel>> haalEigenUrenRegels(int monteurId) async {
    // Collection-group query over alle `regels` van alle bonnen. Vereist in
    // Firestore een single-field index (collection group) op `monteurId`;
    // zonder die index geeft Firestore een fout met een link om hem aan te
    // maken.
    final snap = await _db
        .collectionGroup('regels')
        .where('monteurId', isEqualTo: monteurId)
        .get();
    final prefix = '${ApiConfig.administrationId}_';
    return snap.docs
        .where((d) => d.reference.parent.parent?.id.startsWith(prefix) ?? false)
        .map((d) => BonRegel.fromMap(d.data()))
        .where((r) => r.type == BonRegelType.uren && !r.verwijderd)
        .toList();
  }

  /// Alle uren- en km-regels van [monteurId] over alle bonnen, met het
  /// Ridder-id van de bon erbij (zonder administratie-prefix). Voor het
  /// urenoverzicht op het hoofdscherm; gebruikt dezelfde index als
  /// [haalEigenUrenRegels].
  Future<List<({String bonId, BonRegel regel})>> haalEigenUrenEnKmRegels(
    int monteurId,
  ) async {
    final snap = await _db
        .collectionGroup('regels')
        .where('monteurId', isEqualTo: monteurId)
        .get();
    final prefix = '${ApiConfig.administrationId}_';
    final uit = <({String bonId, BonRegel regel})>[];
    for (final d in snap.docs) {
      final bon = d.reference.parent.parent?.id;
      if (bon == null || !bon.startsWith(prefix)) continue;
      final regel = BonRegel.fromMap(d.data());
      if (regel.verwijderd) continue;
      if (regel.type != BonRegelType.uren && regel.type != BonRegelType.km) {
        continue;
      }
      uit.add((bonId: bon.substring(prefix.length), regel: regel));
    }
    return uit;
  }

  DocumentReference<Map<String, dynamic>> _picking(String jobOrderId) =>
      _bon(jobOrderId).collection('picking').doc('status');

  @override
  Future<PickingStatus?> haalPicking(String jobOrderId) async {
    final snap = await _picking(jobOrderId).get();
    final d = snap.data();
    return d == null ? null : PickingStatus.fromMap(d);
  }

  @override
  Stream<PickingStatus?> watchPicking(String jobOrderId) =>
      _picking(jobOrderId).snapshots().map((snap) {
        final d = snap.data();
        return d == null ? null : PickingStatus.fromMap(d);
      });

  @override
  Future<void> wijzigPicking(
    String jobOrderId, {
    Map<String, int> delta = const {},
    Set<String> gepakt = const {},
    bool bevestigd = false,
    required int monteurId,
    required String monteurNaam,
  }) async {
    final aantallen = {
      for (final e in delta.entries)
        if (e.value != 0) e.key: FieldValue.increment(e.value),
    };
    if (aantallen.isEmpty && gepakt.isEmpty && !bevestigd) return;
    await FirebaseBootstrap.ensureSignedIn();
    final batch = _db.batch();
    batch.set(_bon(jobOrderId), {
      'jobOrderId': jobOrderId,
      'administratie': ApiConfig.administrationId,
      'monteurIds': FieldValue.arrayUnion([monteurId]),
      'bijgewerktOp': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    batch.set(_picking(jobOrderId), {
      if (aantallen.isNotEmpty) 'aantallen': aantallen,
      if (gepakt.isNotEmpty) 'gepakt': {for (final id in gepakt) id: true},
      if (bevestigd) 'bevestigd': true,
      'bijgewerktDoorId': monteurId,
      'bijgewerktDoorNaam': monteurNaam,
      'bijgewerktOp': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    // Niet wachten op de server (offline zou blijven hangen); de lokale
    // cache is direct bijgewerkt.
    unawaited(
      batch.commit().catchError((Object e) {
        debugPrint('[Firebase] pickstatus bon $jobOrderId NIET opgeslagen: $e');
      }),
    );
  }

  @override
  Future<void> annuleerAfronden(String jobOrderId) async {
    await FirebaseBootstrap.ensureSignedIn();
    await _bon(jobOrderId).update({
      'status': ServicebonSyncStatus.open.firestoreWaarde,
      'afrondenDoorId': FieldValue.delete(),
      'afrondenDoorNaam': FieldValue.delete(),
      'afrondenGestartOp': FieldValue.delete(),
      'bijgewerktOp': FieldValue.serverTimestamp(),
    });
  }
}
