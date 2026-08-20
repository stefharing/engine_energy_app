import 'service_remote_format.dart';

/// A single `hours[]` line to be POSTed as part of a Service Remote job
/// order submission. Kept in **minutes** in memory (easy for UI math); the
/// tick conversion required by the API happens only in [toJson], the
/// serialization boundary — see [minutesToTicks].
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

  /// Worked duration in minutes. Always equal to [timeEmployee] — see
  /// [minutesBetween].
  final int totalTime;
  final int timeEmployee;
  final int workActivityId;
  final bool mainEngineer;

  /// A fresh GUID per line, distinct from the job order's own top-level
  /// `uniqueId` on the submission body.
  final String uniqueId;
  final String? memo;

  Map<String, dynamic> toJson() => {
    'id': id,
    'dateChanged': formatServiceRemoteUtc(DateTime.now()),
    'delete': delete,
    'recordTag': null,
    'jobOrderId': jobOrderId,
    'employeeId': employeeId,
    'start': formatServiceRemoteUtc(start),
    'end': formatServiceRemoteUtc(end),
    'totalTime': minutesToTicks(totalTime),
    'timeEmployee': minutesToTicks(timeEmployee),
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
