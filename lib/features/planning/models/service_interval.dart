// The API returns naive datetime strings in UTC (no Z suffix) — mirrors the
// parsing helper in job_order.dart's ServiceOrder.fromJson.
DateTime? parseServiceApiDate(dynamic val) {
  if (val == null) return null;
  final s = val as String;
  final normalized = (s.contains('+') || s.toUpperCase().contains('Z'))
      ? s
      : '${s}Z';
  return DateTime.tryParse(normalized)?.toLocal();
}

/// Picks the soonest upcoming maintenance date across a service object's
/// configured `serviceintervals` records, projecting each interval's
/// `startdate` forward by its period until it lands on/after [now].
/// Count-based intervals (usage/operating-hours, tracked via
/// `countinterval`) can't be projected onto a calendar date, so they're
/// skipped. The exact shape/values of `intervaltype` are unverified against
/// the real Ridder iQ environment — see the PR summary for details.
DateTime? nextMaintenanceDateFrom(
  List<Map<String, dynamic>> intervals, {
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  DateTime? earliest;
  for (final interval in intervals) {
    final startRaw = parseServiceApiDate(interval['startdate']);
    if (startRaw == null) continue;
    // Only the calendar date matters here (never a time-of-day), and
    // normalizing to local midnight up front keeps the day-based branch's
    // repeated `.add(Duration(days: ...))` from drifting by whatever
    // sub-day offset `.toLocal()` introduced when parsing a naive UTC
    // timestamp (see the Ridder API date/DST note elsewhere in this app).
    final start = DateTime(startRaw.year, startRaw.month, startRaw.day);

    final typeJson = interval['intervaltype'];
    final typeLabel = typeJson is Map
        ? ((typeJson['description'] ?? typeJson['code'])?.toString() ?? '')
        : (typeJson?.toString() ?? '');
    final typeLower = typeLabel.toLowerCase();

    DateTime Function(DateTime)? step;
    if (typeLower.contains('maand') || typeLower.contains('month')) {
      final months = (interval['monthinterval'] as num?)?.toInt();
      if (months != null && months > 0) {
        step = (d) => DateTime(d.year, d.month + months, d.day);
      }
    } else if (typeLower.contains('tijd') ||
        typeLower.contains('time') ||
        typeLower.contains('dag') ||
        typeLower.contains('day')) {
      final days = (interval['timeinterval'] as num?)?.toInt();
      if (days != null && days > 0) {
        step = (d) => d.add(Duration(days: days));
      }
    }
    if (step == null) continue;

    var next = start;
    var guard = 0;
    while (next.isBefore(today) && guard < 1000) {
      final advanced = step(next);
      if (!advanced.isAfter(next)) break;
      next = advanced;
      guard++;
    }
    if (earliest == null || next.isBefore(earliest)) earliest = next;
  }
  return earliest;
}
