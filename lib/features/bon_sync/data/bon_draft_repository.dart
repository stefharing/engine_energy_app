import '../models/bon_regel.dart';
import '../models/picking_status.dart';
import '../models/servicebon_sync.dart';

/// Tussentijdse opslag van servicebonnen die nog niet naar Ridder zijn
/// gepubliceerd, gedeeld tussen toestellen en monteurs.
///
/// Ridder blijft de echte administratie; dit is alleen de tussenlaag tot
/// "werk afronden". De Firestore-implementatie staat in
/// [FirestoreBonDraftRepository].
abstract class BonDraftRepository {
  /// Live lijst regels van een bon, oudste eerst. Verwijderde regels
  /// worden weggelaten, tenzij [inclusiefVerwijderd].
  Stream<List<BonRegel>> watchRegels(
    String jobOrderId, {
    bool inclusiefVerwijderd = false,
  });

  /// Eenmalig de regels van een bon ophalen (server, of de offline cache
  /// als er geen verbinding is). Verwijderde regels worden weggelaten,
  /// tenzij [inclusiefVerwijderd].
  Future<List<BonRegel>> haalRegels(
    String jobOrderId, {
    bool inclusiefVerwijderd = false,
  });

  /// Live kop van de bon; `null` zolang er nog niets voor is opgeslagen.
  Stream<ServicebonSync?> watchBon(String jobOrderId);

  /// Maakt een regel aan of werkt hem bij (op basis van [BonRegel.id]).
  /// Werkt ook offline; Firestore synchroniseert later.
  Future<void> bewaarRegel(String jobOrderId, BonRegel regel);

  /// Markeert een regel als verwijderd (zacht verwijderen).
  Future<void> verwijderRegel(String jobOrderId, BonRegel regel);

  /// Probeert het recht te krijgen om de bon naar Ridder te publiceren.
  /// Vereist een verbinding (Firestore-transactie).
  Future<AfrondClaim> claimAfronden(
    String jobOrderId, {
    required int monteurId,
    required String monteurNaam,
  });

  /// Na een geslaagde Ridder-POST: zet de meegestuurde regels op
  /// "verstuurd" en de bon op "afgerond".
  Future<void> bevestigAfgerond(String jobOrderId, Iterable<String> regelIds);

  /// Zet losse regels op "verstuurd" zonder de bonstatus te veranderen —
  /// voor uren en km, die elke monteur apart naar Ridder publiceert.
  Future<void> markeerVerstuurd(String jobOrderId, Iterable<String> regelIds);

  /// Alle (niet-verwijderde) uren-regels van één monteur, over alle bonnen
  /// van de huidige administratie — voor het weekoverzicht op het dashboard.
  Future<List<BonRegel>> haalEigenUrenRegels(int monteurId);

  /// Gedeelde pickstatus van de geplande onderdelen; `null` als er nog
  /// niets is gepickt.
  Future<PickingStatus?> haalPicking(String jobOrderId);
  Stream<PickingStatus?> watchPicking(String jobOrderId);

  /// Past de pickstatus aan. Aantallen gaan als **verschil** ([delta]), zodat
  /// twee monteurs die tegelijk picken elkaars telling niet overschrijven.
  Future<void> wijzigPicking(
    String jobOrderId, {
    Map<String, int> delta = const {},
    Set<String> gepakt = const {},
    bool bevestigd = false,
    required int monteurId,
    required String monteurNaam,
  });

  /// Na een mislukte Ridder-POST: zet de bon terug op "open".
  Future<void> annuleerAfronden(String jobOrderId);
}
