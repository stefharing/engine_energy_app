/// Status van een servicebon in de tussenopslag (Firestore), los van Ridder.
enum ServicebonSyncStatus {
  /// Monteurs kunnen regels toevoegen/aanpassen.
  open,

  /// Eén monteur is de bon aan het publiceren naar Ridder.
  bezigMetAfronden,

  /// In Ridder gepubliceerd; regels zijn niet meer aan te passen.
  afgerond;

  String get firestoreWaarde => switch (this) {
    ServicebonSyncStatus.open => 'open',
    ServicebonSyncStatus.bezigMetAfronden => 'bezig_met_afronden',
    ServicebonSyncStatus.afgerond => 'afgerond',
  };

  static ServicebonSyncStatus vanFirestore(Object? v) => switch (v) {
    'bezig_met_afronden' => ServicebonSyncStatus.bezigMetAfronden,
    'afgerond' => ServicebonSyncStatus.afgerond,
    _ => ServicebonSyncStatus.open,
  };
}

/// De kop van een servicebon in Firestore (`servicebonnen/{bonId}`).
class ServicebonSync {
  const ServicebonSync({
    required this.jobOrderId,
    required this.status,
    this.monteurIds = const [],
    this.afrondenDoorId,
    this.afrondenDoorNaam,
    this.afrondenGestartOp,
    this.afgerondOp,
  });

  final String jobOrderId;
  final ServicebonSyncStatus status;

  /// Monteurs die ooit een regel op deze bon hebben gezet.
  final List<int> monteurIds;

  final int? afrondenDoorId;
  final String? afrondenDoorNaam;
  final DateTime? afrondenGestartOp;
  final DateTime? afgerondOp;

  bool get isOpen => status == ServicebonSyncStatus.open;
}

/// Uitkomst van [BonDraftRepository.claimAfronden].
sealed class AfrondClaim {
  const AfrondClaim();
}

/// Jij mag publiceren; de bon staat nu op "bezig met afronden".
class AfrondClaimGelukt extends AfrondClaim {
  const AfrondClaimGelukt();
}

/// Een andere monteur is net bezig met afronden.
class AfrondClaimBezet extends AfrondClaim {
  const AfrondClaimBezet({required this.doorNaam, required this.sinds});
  final String doorNaam;
  final DateTime? sinds;
}

/// De bon is al afgerond (door jou of een collega).
class AfrondClaimAlAfgerond extends AfrondClaim {
  const AfrondClaimAlAfgerond();
}
