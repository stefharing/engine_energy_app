/// A picked part that wasn't on the office-planned list. Keeps the raw
/// `/itemmanagement/items` catalog record so it can be turned into a real
/// job order line (`item.id`) when confirmed. Shared between
/// [PartsListScreen] (extras picked alongside the office-planned parts) and
/// [UsedMaterialsScreen] (extras registered on their own) — both persist
/// to the same `extra_scanned_<orderId>` SharedPreferences key, so a
/// technician sees the same list from either screen.
///
/// [syncedQuantity] tracks whether (and at what quantity) this extra was
/// included in a successfully published Service Remote job order.
/// [ridderId] is retained only for legacy drafts created by the former v2
/// direct-registration flow; those must not be published a second time.
///
/// [item]`['id']` is `null` for a manually typed-in article ("Artikel
/// aanmaken" — no catalog match, just a name): Ridder's extra-part endpoint
/// is published as a `detailMisc` line when the job order is completed.
class ScannedExtra {
  final Map<String, dynamic> item;
  final int scannedCount;
  final int? ridderId;
  final int? syncedQuantity;

  const ScannedExtra({
    required this.item,
    required this.scannedCount,
    this.ridderId,
    this.syncedQuantity,
  });

  bool get isManual => item['id'] == null;
  String get code => item['code'] as String? ?? '';
  String get description => (item['description'] as String?)?.isNotEmpty == true
      ? item['description'] as String
      : (item['recordtag'] as String? ?? 'Onbekend artikel');
  int get itemId => item['id'] as int;
  int? get unitId =>
      (item['itemunit'] as Map<String, dynamic>?)?['id'] as int?;
  int get sawingCode =>
      (item['defaultsawingcode'] as Map<String, dynamic>?)?['choicenumber']
          as int? ??
      1;
  bool get needsPublication =>
      ridderId == null && syncedQuantity != scannedCount;

  ScannedExtra copyWith({
    int? scannedCount,
    int? ridderId,
    int? syncedQuantity,
  }) => ScannedExtra(
    item: item,
    scannedCount: scannedCount ?? this.scannedCount,
    ridderId: ridderId ?? this.ridderId,
    syncedQuantity: syncedQuantity ?? this.syncedQuantity,
  );

  factory ScannedExtra.fromJson(Map<String, dynamic> j) => ScannedExtra(
    item: (j['item'] as Map).cast<String, dynamic>(),
    scannedCount: (j['scannedCount'] as num?)?.toInt() ?? 1,
    ridderId: (j['ridderId'] as num?)?.toInt(),
    syncedQuantity: (j['syncedQuantity'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'item': item,
    'scannedCount': scannedCount,
    if (ridderId != null) 'ridderId': ridderId,
    if (syncedQuantity != null) 'syncedQuantity': syncedQuantity,
  };
}
