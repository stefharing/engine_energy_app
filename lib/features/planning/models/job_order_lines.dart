// Typed wrappers around the line items embedded in a Service Remote job
// order (`hours`, `detailItems`). The job order has no separate
// "registration" object — these arrays *are* the registration, and the only
// way to mutate them is GET the whole job order, edit the array locally,
// and POST the whole job order back.
//
// None of the field names below have been verified against a real
// `GET /ServiceRemote/JobOrder/{id}` response yet. Every uncertain field is
// marked with `// TODO: verifiëren tegen echte GET-response`. Each wrapper
// keeps the full raw JSON (`raw`) alongside the typed accessors, so that:
//   - fields we don't know about (or don't touch) survive a GET → POST
//     round-trip unchanged;
//   - once the real schema is confirmed, only the key constants below need
//     to change — not every call site.

/// Central place for the JSON key names used inside a single `hours` line
/// (the array that actually holds worked duration — see class doc below on
/// why this isn't the `employees` array).
///
/// Sourced from the Swagger/OpenAPI schema for the "ECI Service Remote" API
/// (retrieved 2026-08-05), which lists the full `hours` line model as:
/// ```
/// { id: int32, dateChanged: date-time, delete: bool, recordTag: string,
///   jobOrderId: int32, employeeId: int32, start: date-time, end: date-time,
///   totalTime: int64, timeEmployee: int64, workActivityId: int32,
///   mainEngineer: bool, uniqueId: uuid, pricePerHour: number,
///   contractDiscount: number, discount: number, totalPrice: number,
///   vatPercentage: number, vatAmount: number, totalPriceIncVAT: number,
///   memo: string }
/// ```
/// No field is marked `required` in the spec, and there's no enum/unit
/// documented for `totalTime`/`timeEmployee` (int64 — ticks? seconds?
/// minutes? unconfirmed) or for what distinguishes them from each other.
/// Every *pricing* field (`pricePerHour` through `totalPriceIncVAT`) reads
/// as computed by the server from `workActivityId`/duration — this app must
/// not invent values for those; only re-GET to read them back.
///
/// TODO: verifiëren tegen een echte GET-response waarin een monteur al
/// daadwerkelijk uren heeft ingevuld — met name: welke van `totalTime`/
/// `timeEmployee` de "duur die de monteur invult" is, in welke eenheid, en
/// hoe die zich verhoudt tot `start`/`end` (zijn dat de begin/eindtijd van
/// het werk op die dag, of iets anders).
class HoursLineKeys {
  static const id = 'id';
  static const jobOrderId = 'jobOrderId';
  static const employeeId = 'employeeId';

  // Confirmed key names + type (date-time) by the schema. Only the date
  // component of `start` is used for day-matching — see
  // isSameDayAndEmployee in job_order_service.dart. Whether `end` must also
  // be set (and to what) for a plain "X hours on day Y" entry is NOT
  // confirmed.
  static const start = 'start';
  static const end = 'end';

  // NOT CONFIRMED — key names are right per the schema, but unit and which
  // of the two represents "the" worked duration is a guess.
  // TODO: verifiëren tegen echte GET-response met ingevulde uren.
  static const totalTime = 'totalTime';
  static const timeEmployee = 'timeEmployee';

  // Confirmed key name/type. Reused from the existing v2
  // `/hours/projecttimes` flow's `workActivityIdWork` constant
  // (planning_repository.dart) as a plausible default, but NOT confirmed
  // that ids mean the same thing on this separate /v1 ServiceRemote API.
  // TODO: verifiëren.
  static const workActivityId = 'workActivityId';

  static const memo = 'memo';

  // Reserved but intentionally left empty for now — see class doc on
  // [JobOrderHoursLine.km]. No km/mileage field exists anywhere on the
  // schema (checked `hours`, `employees`, `detailItems`, `detailMisc`,
  // `wip`) — this stays a placeholder for a future, separately-designed
  // flow, not a real API field.
  static const km = 'km';
}

/// Central place for the JSON key names used inside a single `detailItems`
/// (material) line.
///
/// Confirmed against the same real response as [HoursLineKeys] — a
/// `detailItems` entry looks like:
/// ```
/// {"id": 106, "dateChanged": "...", "description": "MOLDED TUBING",
///  "quantity": 2.0, "itemId": 77683, "warehouseId": 2, "jobOrderId": 61,
///  "deliveryMethod": 1, "registrationPath": 5, "isTravelDetail": false}
/// ```
/// `itemId`/`warehouseId`/`jobOrderId` are all flat int ids — no nested
/// `{'id': ...}` refs. There is no `memo` field on this line (unlike the
/// unrelated `/production/joborderdetailsitem` v2 endpoint used elsewhere
/// in this app), so it's dropped here rather than guessed.
class DetailItemLineKeys {
  static const id = 'id';
  static const description = 'description';
  static const quantity = 'quantity';
  static const itemId = 'itemId';
  static const warehouseId = 'warehouseId';
  static const jobOrderId = 'jobOrderId';

  // Confirmed present with values 1/5 respectively on every existing line
  // in the sample, matching the same defaults the v2
  // `/production/joborderdetailsitem` flow already uses (see
  // planning_repository.dart `_extraPartPayload`: deliverymethod
  // choicenumber 1, registrationpath choicenumber 5). Reused here as
  // defaults for new lines, but not yet confirmed these mean the same
  // thing / are valid choices on the ServiceRemote endpoint.
  // TODO: verifiëren.
  static const deliveryMethod = 'deliveryMethod';
  static const registrationPath = 'registrationPath';

  static const isTravelDetail = 'isTravelDetail';
}

/// One line of the `hours` array on a job order (the "uren line" from the
/// product's point of view).
///
/// This is deliberately NOT the `employees` array also present on the job
/// order — that one only links a day to an employee/appointment
/// (`jobOrder`, `employee`, `date`, `appointmentActionId`) and has no
/// duration field at all. `hours` is where actual worked time — and the
/// server-computed pricing that comes with it — lives.
///
/// [duration] is UNCONFIRMED — see [HoursLineKeys.totalTime]/
/// [HoursLineKeys.timeEmployee]. Both keys are written with the same guessed
/// value so the flow is wired up, but neither the key nor the unit is
/// verified yet; the pricing fields ([pricePerHour] etc.) are read-only —
/// this app never sets them.
///
/// [km] is a reserved field/place for kilometers — no such field exists in
/// the confirmed schema at all. Left `null`/unpopulated until a km flow is
/// designed and the API is (re-)checked for where it would go.
class JobOrderHoursLine {
  final int? id;
  final int? employeeId;
  final int? jobOrderId;
  final DateTime? start;
  final DateTime? end;
  final int? workActivityId;
  final Duration? duration;
  final String? memo;
  final double? km;

  /// Server-computed pricing fields, read-only — never set by this app.
  /// Exposed for display only; present when read back from a GET/synced
  /// state, absent on a freshly-built local line before the round trip.
  final num? pricePerHour;
  final num? totalPrice;
  final num? totalPriceIncVAT;

  /// The original JSON for this line, including any fields not modeled
  /// above. Preserved so a GET → POST round trip doesn't silently drop
  /// server-managed or as-yet-unmapped fields.
  final Map<String, dynamic> raw;

  const JobOrderHoursLine({
    this.id,
    this.employeeId,
    this.jobOrderId,
    this.start,
    this.end,
    this.workActivityId,
    this.duration,
    this.memo,
    this.km,
    this.pricePerHour,
    this.totalPrice,
    this.totalPriceIncVAT,
    this.raw = const {},
  });

  factory JobOrderHoursLine.fromJson(Map<String, dynamic> json) {
    return JobOrderHoursLine(
      id: json[HoursLineKeys.id] as int?,
      employeeId: json[HoursLineKeys.employeeId] as int?,
      jobOrderId: json[HoursLineKeys.jobOrderId] as int?,
      start: _tryParseDate(json[HoursLineKeys.start]),
      end: _tryParseDate(json[HoursLineKeys.end]),
      workActivityId: json[HoursLineKeys.workActivityId] as int?,
      duration: _tryParseDuration(json[HoursLineKeys.totalTime]),
      memo: json[HoursLineKeys.memo] as String?,
      km: (json[HoursLineKeys.km] as num?)?.toDouble(),
      pricePerHour: json['pricePerHour'] as num?,
      totalPrice: json['totalPrice'] as num?,
      totalPriceIncVAT: json['totalPriceIncVAT'] as num?,
      raw: json,
    );
  }

  /// Merges the typed fields back on top of [raw], so unknown fields from
  /// the original GET survive. Pricing fields are intentionally NEVER
  /// written here — they come from [raw] only, i.e. only survive if this
  /// line originated from a GET. `km` is only included if it was already
  /// set (see class doc) — we never invent a value for it.
  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    if (id != null) json[HoursLineKeys.id] = id;
    if (employeeId != null) json[HoursLineKeys.employeeId] = employeeId;
    if (jobOrderId != null) json[HoursLineKeys.jobOrderId] = jobOrderId;
    if (start != null) {
      json[HoursLineKeys.start] = start!.toUtc().toIso8601String();
    }
    if (end != null) {
      json[HoursLineKeys.end] = end!.toUtc().toIso8601String();
    }
    if (workActivityId != null) {
      json[HoursLineKeys.workActivityId] = workActivityId;
    }
    if (duration != null) {
      // TODO: verifiëren — zelfde (nog niet bevestigde) waarde naar beide
      // velden totdat duidelijk is waarin ze verschillen.
      final formatted = _formatDuration(duration!);
      json[HoursLineKeys.totalTime] = formatted;
      json[HoursLineKeys.timeEmployee] = formatted;
    }
    if (memo != null) json[HoursLineKeys.memo] = memo;
    if (km != null) json[HoursLineKeys.km] = km;
    return json;
  }

  JobOrderHoursLine copyWith({
    int? id,
    int? employeeId,
    int? jobOrderId,
    DateTime? start,
    DateTime? end,
    int? workActivityId,
    Duration? duration,
    String? memo,
    double? km,
  }) => JobOrderHoursLine(
    id: id ?? this.id,
    employeeId: employeeId ?? this.employeeId,
    jobOrderId: jobOrderId ?? this.jobOrderId,
    start: start ?? this.start,
    end: end ?? this.end,
    workActivityId: workActivityId ?? this.workActivityId,
    duration: duration ?? this.duration,
    memo: memo ?? this.memo,
    km: km ?? this.km,
    pricePerHour: pricePerHour,
    totalPrice: totalPrice,
    totalPriceIncVAT: totalPriceIncVAT,
    raw: raw,
  );
}

/// One line of `detailItems` (material) on a job order.
class JobOrderDetailItemLine {
  final int? id;
  final String? description;
  final double? quantity;
  final int? itemId;
  final int? warehouseId;
  final int? jobOrderId;
  final int? deliveryMethod;
  final int? registrationPath;
  final bool? isTravelDetail;

  /// The original JSON for this line, preserved for the same reason as
  /// [JobOrderHoursLine.raw].
  final Map<String, dynamic> raw;

  const JobOrderDetailItemLine({
    this.id,
    this.description,
    this.quantity,
    this.itemId,
    this.warehouseId,
    this.jobOrderId,
    this.deliveryMethod,
    this.registrationPath,
    this.isTravelDetail,
    this.raw = const {},
  });

  /// Builds a new (not-yet-posted) material line for a picked part. Mirrors
  /// the `deliveryMethod`/`registrationPath`/`isTravelDetail` defaults every
  /// existing line in the confirmed sample response used.
  factory JobOrderDetailItemLine.newPart({
    required int itemId,
    required int warehouseId,
    required int jobOrderId,
    required double quantity,
    String? description,
  }) => JobOrderDetailItemLine(
    itemId: itemId,
    warehouseId: warehouseId,
    jobOrderId: jobOrderId,
    quantity: quantity,
    description: description,
    deliveryMethod: 1,
    registrationPath: 5,
    isTravelDetail: false,
  );

  factory JobOrderDetailItemLine.fromJson(Map<String, dynamic> json) {
    return JobOrderDetailItemLine(
      id: json[DetailItemLineKeys.id] as int?,
      description: json[DetailItemLineKeys.description] as String?,
      quantity: (json[DetailItemLineKeys.quantity] as num?)?.toDouble(),
      itemId: json[DetailItemLineKeys.itemId] as int?,
      warehouseId: json[DetailItemLineKeys.warehouseId] as int?,
      jobOrderId: json[DetailItemLineKeys.jobOrderId] as int?,
      deliveryMethod: json[DetailItemLineKeys.deliveryMethod] as int?,
      registrationPath: json[DetailItemLineKeys.registrationPath] as int?,
      isTravelDetail: json[DetailItemLineKeys.isTravelDetail] as bool?,
      raw: json,
    );
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    if (id != null) json[DetailItemLineKeys.id] = id;
    if (description != null) {
      json[DetailItemLineKeys.description] = description;
    }
    if (quantity != null) json[DetailItemLineKeys.quantity] = quantity;
    if (itemId != null) json[DetailItemLineKeys.itemId] = itemId;
    if (warehouseId != null) {
      json[DetailItemLineKeys.warehouseId] = warehouseId;
    }
    if (jobOrderId != null) json[DetailItemLineKeys.jobOrderId] = jobOrderId;
    if (deliveryMethod != null) {
      json[DetailItemLineKeys.deliveryMethod] = deliveryMethod;
    }
    if (registrationPath != null) {
      json[DetailItemLineKeys.registrationPath] = registrationPath;
    }
    if (isTravelDetail != null) {
      json[DetailItemLineKeys.isTravelDetail] = isTravelDetail;
    }
    return json;
  }
}

// ─── Small local parsing helpers ────────────────────────────────────────
// Confirmed: dates on job order lines are full ISO-8601 timestamps with an
// explicit offset (e.g. "2026-08-07T01:00:00+00:00"), unlike job_order.dart's
// `_parseIsoDate` which has to work around the general v2 API returning
// naive UTC strings. `DateTime.parse` handles the explicit-offset format
// directly, so no workaround is needed here.

DateTime? _tryParseDate(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value as String)?.toLocal();
}

// `totalTime`/`timeEmployee` are documented as `int64` (not a duration
// string), so unlike the v2 API's "HH:mm:ss" convention
// (planning_repository.dart `_formatDuration`), these are plain integers.
// NOT CONFIRMED: which unit — guessing whole minutes below. Swap this
// parsing/formatting pair once a real filled-in example is available; call
// sites don't need to change.

Duration? _tryParseDuration(dynamic value) {
  if (value == null) return null;
  return Duration(minutes: (value as num).round());
}

int _formatDuration(Duration d) => d.inMinutes;
