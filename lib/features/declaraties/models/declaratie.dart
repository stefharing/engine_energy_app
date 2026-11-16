/// Hoe de monteur de gedeclareerde kosten heeft betaald. Bepaalt later hoe
/// de declaratie wordt afgehandeld (privé = terug te betalen aan de
/// monteur, via Nmbrs). Het label gaat mee in de omschrijving naar Ridder.
enum Betaalwijze {
  betaalpas('Betaalpas EE'),
  creditcard('Creditcard'),
  prive('Privérekening');

  const Betaalwijze(this.label);
  final String label;

  static Betaalwijze fromName(String? name) => values.firstWhere(
    (b) => b.name == name,
    orElse: () => Betaalwijze.betaalpas,
  );
}

enum DeclaratieStatus { wacht, verstuurd }

/// Eén declaratie (bonnetje) van een monteur. Wordt eerst lokaal bewaard en
/// daarna naar Ridder gestuurd als inkoopfactuur, zodat er onderweg (slecht
/// bereik) niets verloren gaat.
class Declaratie {
  final String id;
  final DateTime datum;
  final String omschrijving;
  final double bedrag;
  final Betaalwijze betaalwijze;

  /// Optionele koppeling aan een servicebon (id + bonnummer).
  final String? bonId;
  final String? bonNummer;

  /// Pad naar de foto van de bon, in de documentmap van de app.
  final String? fotoPad;
  final DateTime aangemaaktOp;
  final DeclaratieStatus status;

  /// Laatste foutmelding bij het versturen; `null` als er geen is.
  final String? fout;

  /// Id van de inkoopfactuur in Ridder zodra de kop is aangemaakt. Bij een
  /// nieuwe poging wordt die hergebruikt, zodat er geen dubbele facturen
  /// ontstaan.
  final int? factuurId;
  final DateTime? verstuurdOp;

  /// Voortgang van het versturen, zodat een nieuwe poging niets dubbel doet:
  /// de kostenregel staat al op de factuur / de foto is al geüpload.
  final bool regelGeboekt;
  final bool fotoGeupload;

  const Declaratie({
    required this.id,
    required this.datum,
    required this.omschrijving,
    required this.bedrag,
    required this.betaalwijze,
    required this.aangemaaktOp,
    this.bonId,
    this.bonNummer,
    this.fotoPad,
    this.status = DeclaratieStatus.wacht,
    this.fout,
    this.factuurId,
    this.verstuurdOp,
    this.regelGeboekt = false,
    this.fotoGeupload = false,
  });

  bool get isVerstuurd => status == DeclaratieStatus.verstuurd;

  /// Omschrijving van de inkoopfactuur (kop) in Ridder.
  String get factuurOmschrijving =>
      '$omschrijving · ${betaalwijze.label}'
      '${bonNummer != null ? ' · Bon $bonNummer' : ''}';

  /// Omschrijving van de DIVERS-regel: bevat de betaalwijze, zodat die in
  /// Ridder zichtbaar is.
  String get regelOmschrijving =>
      '$omschrijving · ${betaalwijze.label}'
      '${bonNummer != null ? ' · Bon $bonNummer' : ''}';

  Declaratie copyWith({
    DeclaratieStatus? status,
    String? fout,
    bool wisFout = false,
    int? factuurId,
    DateTime? verstuurdOp,
    bool? regelGeboekt,
    bool? fotoGeupload,
  }) => Declaratie(
    id: id,
    datum: datum,
    omschrijving: omschrijving,
    bedrag: bedrag,
    betaalwijze: betaalwijze,
    aangemaaktOp: aangemaaktOp,
    bonId: bonId,
    bonNummer: bonNummer,
    fotoPad: fotoPad,
    status: status ?? this.status,
    fout: wisFout ? null : (fout ?? this.fout),
    factuurId: factuurId ?? this.factuurId,
    verstuurdOp: verstuurdOp ?? this.verstuurdOp,
    regelGeboekt: regelGeboekt ?? this.regelGeboekt,
    fotoGeupload: fotoGeupload ?? this.fotoGeupload,
  );

  factory Declaratie.fromJson(Map<String, dynamic> j) => Declaratie(
    id: j['id'] as String,
    datum: DateTime.parse(j['datum'] as String),
    omschrijving: j['omschrijving'] as String? ?? '',
    bedrag: (j['bedrag'] as num?)?.toDouble() ?? 0,
    betaalwijze: Betaalwijze.fromName(j['betaalwijze'] as String?),
    bonId: j['bonId'] as String?,
    bonNummer: j['bonNummer'] as String?,
    fotoPad: j['fotoPad'] as String?,
    aangemaaktOp: DateTime.parse(j['aangemaaktOp'] as String),
    status: j['status'] == 'verstuurd'
        ? DeclaratieStatus.verstuurd
        : DeclaratieStatus.wacht,
    fout: j['fout'] as String?,
    factuurId: (j['factuurId'] as num?)?.toInt(),
    verstuurdOp: j['verstuurdOp'] == null
        ? null
        : DateTime.parse(j['verstuurdOp'] as String),
    regelGeboekt: j['regelGeboekt'] as bool? ?? false,
    fotoGeupload: j['fotoGeupload'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'datum': datum.toIso8601String(),
    'omschrijving': omschrijving,
    'bedrag': bedrag,
    'betaalwijze': betaalwijze.name,
    if (bonId != null) 'bonId': bonId,
    if (bonNummer != null) 'bonNummer': bonNummer,
    if (fotoPad != null) 'fotoPad': fotoPad,
    'aangemaaktOp': aangemaaktOp.toIso8601String(),
    'status': status.name,
    if (fout != null) 'fout': fout,
    if (factuurId != null) 'factuurId': factuurId,
    if (verstuurdOp != null) 'verstuurdOp': verstuurdOp!.toIso8601String(),
    if (regelGeboekt) 'regelGeboekt': true,
    if (fotoGeupload) 'fotoGeupload': true,
  };
}
