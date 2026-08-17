/// A single local `hours[]` entry, matching the exact shape phase 5 needs to
/// POST back as part of the full job order — so its [toJson] can be dropped
/// straight into that array without transformation.
///
/// Pricing fields ([pricePerHour] through [totalPriceIncVAT]) always stay 0:
/// Ridder computes them server-side on processing, this app never sets them.
class HoursEntry {
  const HoursEntry({
    this.id = 0,
    this.delete = false,
    required this.jobOrderId,
    required this.employeeId,
    required this.start,
    required this.end,
    required this.totalTime,
    required this.timeEmployee,
    required this.workActivityId,
    this.mainEngineer = true,
    required this.uniqueId,
    this.memo,
  });

  final int id;
  final bool delete;
  final int jobOrderId;
  final int employeeId;
  final DateTime start;
  final DateTime end;

  /// Worked duration in minutes. Always equal to [timeEmployee] — see class
  /// doc on [HoursEntry] and [minutesBetween].
  final int totalTime;
  final int timeEmployee;
  final int workActivityId;
  final bool mainEngineer;

  /// Stable per (job order + employee + calendar day) identity. Must be
  /// reused, not regenerated, when editing an existing day's entry — see
  /// [isSameDayEntry] / `HoursEntryStore.upsert`.
  final String uniqueId;
  final String? memo;

  HoursEntry copyWith({
    DateTime? start,
    DateTime? end,
    int? totalTime,
    int? timeEmployee,
    int? workActivityId,
    String? memo,
  }) => HoursEntry(
    id: id,
    delete: delete,
    jobOrderId: jobOrderId,
    employeeId: employeeId,
    start: start ?? this.start,
    end: end ?? this.end,
    totalTime: totalTime ?? this.totalTime,
    timeEmployee: timeEmployee ?? this.timeEmployee,
    workActivityId: workActivityId ?? this.workActivityId,
    mainEngineer: mainEngineer,
    uniqueId: uniqueId,
    memo: memo ?? this.memo,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'delete': delete,
    'jobOrderId': jobOrderId,
    'employeeId': employeeId,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
    'totalTime': totalTime,
    'timeEmployee': timeEmployee,
    'workActivityId': workActivityId,
    'mainEngineer': mainEngineer,
    'uniqueId': uniqueId,
    'pricePerHour': 0,
    'contractDiscount': 0,
    'discount': 0,
    'totalPrice': 0,
    'vatPercentage': 0,
    'vatAmount': 0,
    'totalPriceIncVAT': 0,
    'memo': memo,
  };
}

/// Worked duration in whole minutes between [start] and [end]. Pure and
/// independently testable — no rounding beyond truncating to whole minutes.
int minutesBetween(DateTime start, DateTime end) =>
    end.difference(start).inMinutes;
