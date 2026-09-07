import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/models/service_interval.dart';

void main() {
  group('parseServiceApiDate', () {
    test('parses a naive UTC string (no Z suffix) as UTC', () {
      final d = parseServiceApiDate('2026-01-15T00:00:00');
      expect(d, isNotNull);
      expect(d!.toUtc().year, 2026);
      expect(d.toUtc().month, 1);
      expect(d.toUtc().day, 15);
    });

    test('returns null for null input', () {
      expect(parseServiceApiDate(null), isNull);
    });
  });

  group('nextMaintenanceDateFrom', () {
    final now = DateTime(2026, 6, 1);

    test('projects a month-based interval forward to the next occurrence', () {
      final intervals = [
        {
          'startdate': '2026-01-01T00:00:00',
          'intervaltype': {'description': 'Maand'},
          'monthinterval': 3,
        },
      ];
      // 2026-01-01, +3 months = 2026-04-01 (before now), +3 = 2026-07-01
      final next = nextMaintenanceDateFrom(intervals, now: now);
      expect(next, DateTime(2026, 7, 1));
    });

    test('projects a day-based (timeinterval) interval forward', () {
      final intervals = [
        {
          'startdate': '2026-05-20T00:00:00',
          'intervaltype': {'description': 'Tijd'},
          'timeinterval': 30,
        },
      ];
      final next = nextMaintenanceDateFrom(intervals, now: now);
      expect(next, DateTime(2026, 6, 19));
    });

    test('keeps a startdate that is already upcoming as-is', () {
      final intervals = [
        {
          'startdate': '2026-08-01T00:00:00',
          'intervaltype': {'description': 'Maand'},
          'monthinterval': 6,
        },
      ];
      final next = nextMaintenanceDateFrom(intervals, now: now);
      expect(next, DateTime(2026, 8, 1));
    });

    test('skips count-based intervals — no calendar date derivable', () {
      final intervals = [
        {
          'startdate': '2026-01-01T00:00:00',
          'intervaltype': {'description': 'Aantal'},
          'countinterval': 500,
        },
      ];
      expect(nextMaintenanceDateFrom(intervals, now: now), isNull);
    });

    test('picks the earliest upcoming date across multiple intervals', () {
      final intervals = [
        {
          'startdate': '2026-01-01T00:00:00',
          'intervaltype': {'description': 'Maand'},
          'monthinterval': 12,
        },
        {
          'startdate': '2026-05-01T00:00:00',
          'intervaltype': {'description': 'Tijd'},
          'timeinterval': 14,
        },
      ];
      // First interval's next occurrence: 2027-01-01.
      // Second: 2026-05-01, +14 repeatedly -> 05-15 -> 05-29 -> 06-12.
      final next = nextMaintenanceDateFrom(intervals, now: now);
      expect(next, DateTime(2026, 6, 12));
    });

    test('returns null for an empty list', () {
      expect(nextMaintenanceDateFrom(const [], now: now), isNull);
    });

    test('ignores an interval with no parseable startdate', () {
      final intervals = [
        {
          'intervaltype': {'description': 'Maand'},
          'monthinterval': 3,
        },
      ];
      expect(nextMaintenanceDateFrom(intervals, now: now), isNull);
    });
  });
}
