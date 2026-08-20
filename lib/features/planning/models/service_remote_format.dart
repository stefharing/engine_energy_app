// Shared, low-level formatting/unit-conversion helpers for values going
// into a `POST /ServiceRemote/JobOrder/{id}` body. Kept in one place so
// every writer (job order submission builder, hours line model) uses the
// exact same rules — confirmed against a live curl session, see the
// project's architecture notes for job order 79.

/// Ticks (.NET's 100-nanosecond time unit) per whole minute — the unit
/// `hours[].totalTime`/`timeEmployee` are stored in. Sending plain minutes
/// (or seconds) is silently accepted but ignored server-side.
const ticksPerMinute = 600000000;

int minutesToTicks(int minutes) => minutes * ticksPerMinute;

/// Formats [dt] the way the Service Remote API expects: whole-second UTC,
/// `Z`-suffixed, no milliseconds (e.g. `"2026-08-22T09:00:00Z"`). Dart's
/// default `DateTime.toIso8601String()` includes milliseconds, which the
/// confirmed-working request bodies never contain — so this is a dedicated
/// formatter rather than a call to that method.
String formatServiceRemoteUtc(DateTime dt) {
  final u = dt.toUtc();
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${p2(u.month)}-${p2(u.day)}'
      'T${p2(u.hour)}:${p2(u.minute)}:${p2(u.second)}Z';
}

/// Sentinel value the Service Remote API accepts for non-nullable `DateTime`
/// fields that have no real value (e.g. an object's warranty/build dates
/// when none are recorded).
const serviceRemoteSentinelDateTime = '1900-01-01T00:00:00Z';
