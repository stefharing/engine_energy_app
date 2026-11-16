import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/auth/auth_service.dart';
import '../../planning/data/declarations_repository.dart';
import '../../planning/data/ridder_error.dart';
import '../models/declaratie.dart';
import 'declaratie_store.dart';

/// Bewaart en verstuurt declaraties. Een declaratie wordt altijd eerst lokaal
/// opgeslagen; versturen (inkoopfactuur in Ridder, leverancier
/// "Diverse crediteuren" + één DIVERS-regel) mag daarna mislukken en later
/// opnieuw.
class DeclaratieService {
  DeclaratieService._();
  static final instance = DeclaratieService._();

  final _store = DeclaratieStore.instance;
  final _bezig = <String>{};

  int? get _monteurId => AuthService.instance.currentMechanicId;
  String get _monteurNaam => AuthService.instance.currentEmployee?.name ?? '';

  Future<List<Declaratie>> laad() async {
    final id = _monteurId;
    return id == null ? [] : _store.laad(id);
  }

  /// Kopieert de foto naar de documentmap van de app (de tijdelijke map van
  /// de camera wordt door het systeem opgeruimd) en geeft het nieuwe pad.
  Future<String> bewaarFoto(File bron, String declaratieId) async {
    final map = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/declaraties',
    );
    await map.create(recursive: true);
    final doel = File('${map.path}/$declaratieId.jpg');
    await bron.copy(doel.path);
    return doel.path;
  }

  Future<void> bewaar(Declaratie d) async {
    final id = _monteurId;
    if (id == null) throw StateError('Je bent niet ingelogd.');
    await _store.bewaar(id, d);
  }

  Future<void> verwijder(Declaratie d) async {
    final id = _monteurId;
    if (id == null) return;
    await _store.verwijder(id, d.id);
    final pad = d.fotoPad;
    if (pad != null) {
      try {
        await File(pad).delete();
      } catch (_) {}
    }
  }

  /// Stuurt één declaratie naar Ridder. Geeft `null` bij succes, anders een
  /// leesbare foutmelding (de declaratie blijft dan "wacht" met die fout).
  Future<String?> verstuur(Declaratie d) async {
    final monteurId = _monteurId;
    if (monteurId == null) return 'Je bent niet ingelogd.';
    if (d.isVerstuurd) return null;
    if (!_bezig.add(d.id)) return 'Wordt al verstuurd.';
    try {
      var huidig = d;
      Future<void> sla(Declaratie n) async {
        huidig = n;
        await _store.bewaar(monteurId, n);
      }

      // Stap 1: factuurkop (hergebruikt bij een nieuwe poging).
      var factuurId = huidig.factuurId;
      if (factuurId == null) {
        final leverancier = await DeclarationsRepository.getOverigSupplierId();
        factuurId = await DeclarationsRepository.maakKop(
          supplierId: leverancier,
          reference: _factuurNummer(huidig),
          date: huidig.datum,
        );
        await sla(huidig.copyWith(factuurId: factuurId));
      }

      // Stap 2: de kostenregel, op de bon als die bekend is.
      if (!huidig.regelGeboekt) {
        await DeclarationsRepository.boekRegel(
          invoiceId: factuurId,
          line: DeclarationLine(
            description: huidig.regelOmschrijving,
            amount: huidig.bedrag,
            jobOrderId: huidig.bonId == null
                ? null
                : int.tryParse(huidig.bonId!),
          ),
        );
        await sla(huidig.copyWith(regelGeboekt: true));
      }

      // Stap 3: de foto van de bon als bijlage.
      final foto = huidig.fotoPad;
      if (foto != null && !huidig.fotoGeupload && await File(foto).exists()) {
        await DeclarationsRepository.uploadFoto(
          invoiceId: factuurId,
          path: foto,
          fileName: 'bon-${huidig.id}.jpg',
        );
        await sla(huidig.copyWith(fotoGeupload: true));
      }

      await sla(
        huidig.copyWith(
          status: DeclaratieStatus.verstuurd,
          verstuurdOp: DateTime.now(),
          wisFout: true,
        ),
      );
      return null;
    } catch (e) {
      final melding = _melding(e);
      // Pak de laatste versie: de factuurkop kan al zijn aangemaakt.
      final huidig = await _store.vind(monteurId, d.id) ?? d;
      await _store.bewaar(monteurId, huidig.copyWith(fout: melding));
      return melding;
    } finally {
      _bezig.remove(d.id);
    }
  }

  /// Extern factuurnummer: moet uniek zijn per leverancier, dus met datum en
  /// een stukje van het declaratie-id, bijv. `DECL-20261029-1a2b3c4d`.
  static String _factuurNummer(Declaratie d) {
    final dag =
        '${d.datum.year}${d.datum.month.toString().padLeft(2, '0')}'
        '${d.datum.day.toString().padLeft(2, '0')}';
    final id = d.id.replaceAll('-', '');
    return 'DECL-$dag-${id.length > 8 ? id.substring(0, 8) : id}';
  }

  /// Probeert alle openstaande declaraties te versturen. Geeft het aantal
  /// dat is gelukt.
  Future<int> verstuurOpenstaande() async {
    var gelukt = 0;
    for (final d in await laad()) {
      if (d.isVerstuurd) continue;
      if (await verstuur(d) == null) gelukt++;
    }
    return gelukt;
  }

  static String _melding(Object e) {
    if (e is DioException &&
        (e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.receiveTimeout)) {
      return 'Geen verbinding met Ridder. Probeer het later opnieuw.';
    }
    return friendlyRidderError(e).replaceFirst('Exception: ', '');
  }
}
