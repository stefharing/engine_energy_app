import '../../planning/models/scanned_extra.dart';

/// Wat voor regel een [BonRegel] is.
enum BonRegelType { artikel, uren, km }

/// Of een regel al in een geslaagde Ridder-publicatie zat.
enum BonRegelStatus { concept, verstuurd }

/// Eén tussentijds opgeslagen regel van een servicebon — een gebruikt
/// artikel, een urenkaart of een km-registratie — zoals die in Firestore
/// staat onder `servicebonnen/{bonId}/regels/{id}`.
///
/// Elke regel is een eigen document dat alleen door de monteur die hem
/// aanmaakte wordt aangepast. Zo kunnen twee monteurs tegelijk aan
/// dezelfde bon werken zonder elkaars wijzigingen te overschrijven.
///
/// Het [id] wordt op het toestel gemaakt (uuid). Een regel die offline
/// wordt aangemaakt en later nogmaals wordt opgeslagen, blijft daardoor
/// hetzelfde document.
///
/// Verwijderen gebeurt "zacht" via [verwijderd], zodat andere toestellen
/// (en hun offline cache) het ook meekrijgen.
///
/// Dit model is bewust vrij van Firestore-imports, zodat het zonder
/// Firebase te testen is. Datums gaan er als [DateTime] in; [fromMap]
/// accepteert daarnaast Firestore `Timestamp`s (alles met `toDate()`).
class BonRegel {
  const BonRegel._({
    required this.id,
    required this.type,
    required this.monteurId,
    required this.monteurNaam,
    required this.aangemaaktOp,
    required this.bijgewerktOp,
    this.verwijderd = false,
    this.status = BonRegelStatus.concept,
    this.verstuurdOp,
    this.item,
    this.aantal,
    this.datum,
    this.workActivityId,
    this.workActivityCode,
    this.minuten,
    this.memo,
    this.km,
  });

  /// Een gebruikt artikel. [item] is het ruwe `/itemmanagement/items`
  /// catalogusrecord (net als bij [ScannedExtra]); `item['id'] == null`
  /// betekent een handmatig ingevoerd artikel.
  factory BonRegel.artikel({
    required String id,
    required int monteurId,
    required String monteurNaam,
    required Map<String, dynamic> item,
    required int aantal,
    DateTime? nu,
  }) {
    final t = nu ?? DateTime.now();
    return BonRegel._(
      id: id,
      type: BonRegelType.artikel,
      monteurId: monteurId,
      monteurNaam: monteurNaam,
      aangemaaktOp: t,
      bijgewerktOp: t,
      item: item,
      aantal: aantal,
    );
  }

  /// Een urenkaart zoals ingevoerd in `HoursWeekScreen`.
  factory BonRegel.uren({
    required String id,
    required int monteurId,
    required String monteurNaam,
    required DateTime datum,
    required int workActivityId,
    String? workActivityCode,
    required int minuten,
    String? memo,
    DateTime? nu,
  }) {
    final t = nu ?? DateTime.now();
    return BonRegel._(
      id: id,
      type: BonRegelType.uren,
      monteurId: monteurId,
      monteurNaam: monteurNaam,
      aangemaaktOp: t,
      bijgewerktOp: t,
      datum: _alleenDatum(datum),
      workActivityId: workActivityId,
      workActivityCode: workActivityCode,
      minuten: minuten,
      memo: memo,
    );
  }

  /// Gereden kilometers op een dag.
  factory BonRegel.km({
    required String id,
    required int monteurId,
    required String monteurNaam,
    required DateTime datum,
    required int km,
    DateTime? nu,
  }) {
    final t = nu ?? DateTime.now();
    return BonRegel._(
      id: id,
      type: BonRegelType.km,
      monteurId: monteurId,
      monteurNaam: monteurNaam,
      aangemaaktOp: t,
      bijgewerktOp: t,
      datum: _alleenDatum(datum),
      km: km,
    );
  }

  final String id;
  final BonRegelType type;
  final int monteurId;
  final String monteurNaam;
  final DateTime aangemaaktOp;
  final DateTime bijgewerktOp;
  final bool verwijderd;
  final BonRegelStatus status;
  final DateTime? verstuurdOp;

  // artikel
  final Map<String, dynamic>? item;
  final int? aantal;

  // uren + km
  final DateTime? datum;

  // uren
  final int? workActivityId;

  /// Ridder-code van de uursoort (bijv. `SRV-NL`); leidend boven
  /// [workActivityId], omdat id's per administratie verschillen.
  final String? workActivityCode;
  final int? minuten;
  final String? memo;

  // km
  final int? km;

  bool get isConcept => status == BonRegelStatus.concept;

  /// Hoort deze regel in de volgende Ridder-publicatie?
  bool get moetGepubliceerd => isConcept && !verwijderd;

  /// Een aangepaste kopie; [bijgewerktOp] wordt automatisch ververst.
  BonRegel copyWith({
    int? aantal,
    int? minuten,
    int? workActivityId,
    String? workActivityCode,
    String? memo,
    int? km,
    DateTime? datum,
    bool? verwijderd,
    BonRegelStatus? status,
    DateTime? verstuurdOp,
    DateTime? nu,
  }) => BonRegel._(
    id: id,
    type: type,
    monteurId: monteurId,
    monteurNaam: monteurNaam,
    aangemaaktOp: aangemaaktOp,
    bijgewerktOp: nu ?? DateTime.now(),
    verwijderd: verwijderd ?? this.verwijderd,
    status: status ?? this.status,
    verstuurdOp: verstuurdOp ?? this.verstuurdOp,
    item: item,
    aantal: aantal ?? this.aantal,
    datum: datum != null ? _alleenDatum(datum) : this.datum,
    workActivityId: workActivityId ?? this.workActivityId,
    workActivityCode: workActivityCode ?? this.workActivityCode,
    minuten: minuten ?? this.minuten,
    memo: memo ?? this.memo,
    km: km ?? this.km,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'type': type.name,
    'monteurId': monteurId,
    'monteurNaam': monteurNaam,
    'aangemaaktOp': aangemaaktOp,
    'bijgewerktOp': bijgewerktOp,
    'verwijderd': verwijderd,
    'status': status.name,
    if (verstuurdOp != null) 'verstuurdOp': verstuurdOp,
    if (item != null) 'item': item,
    if (aantal != null) 'aantal': aantal,
    if (datum != null) 'datum': _datumString(datum!),
    if (workActivityId != null) 'workActivityId': workActivityId,
    if (workActivityCode != null) 'workActivityCode': workActivityCode,
    if (minuten != null) 'minuten': minuten,
    if (memo != null) 'memo': memo,
    if (km != null) 'km': km,
  };

  factory BonRegel.fromMap(Map<String, dynamic> m) => BonRegel._(
    id: m['id'] as String,
    type: BonRegelType.values.byName(m['type'] as String),
    monteurId: (m['monteurId'] as num).toInt(),
    monteurNaam: m['monteurNaam'] as String? ?? '',
    aangemaaktOp: _leesTijd(m['aangemaaktOp']) ?? DateTime.now(),
    bijgewerktOp: _leesTijd(m['bijgewerktOp']) ?? DateTime.now(),
    verwijderd: m['verwijderd'] as bool? ?? false,
    status: BonRegelStatus.values.byName(
      m['status'] as String? ?? BonRegelStatus.concept.name,
    ),
    verstuurdOp: _leesTijd(m['verstuurdOp']),
    item: (m['item'] as Map?)?.cast<String, dynamic>(),
    aantal: (m['aantal'] as num?)?.toInt(),
    datum: m['datum'] == null ? null : DateTime.parse(m['datum'] as String),
    workActivityId: (m['workActivityId'] as num?)?.toInt(),
    workActivityCode: m['workActivityCode'] as String?,
    minuten: (m['minuten'] as num?)?.toInt(),
    memo: m['memo'] as String?,
    km: (m['km'] as num?)?.toInt(),
  );

  /// Brug naar de bestaande artikelschermen, die met [ScannedExtra] werken.
  /// Alleen geldig voor [BonRegelType.artikel].
  ScannedExtra toScannedExtra() {
    assert(type == BonRegelType.artikel, 'toScannedExtra op een $type-regel');
    return ScannedExtra(
      item: item ?? const {},
      scannedCount: aantal ?? 0,
      syncedQuantity: status == BonRegelStatus.verstuurd ? aantal : null,
      regelId: id,
      monteurId: monteurId,
      monteurNaam: monteurNaam,
    );
  }

  static DateTime _alleenDatum(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Datums (zonder tijd) als `yyyy-MM-dd`, zodat tijdzones er niet mee
  /// kunnen schuiven.
  static String _datumString(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static DateTime? _leesTijd(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    // Firestore Timestamp (en alles wat er op lijkt).
    try {
      return (v as dynamic).toDate() as DateTime;
    } catch (_) {
      return null;
    }
  }
}
