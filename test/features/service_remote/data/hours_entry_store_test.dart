import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/service_remote/data/hours_entry_store.dart';
import 'package:engine_energy_app/features/service_remote/models/hours_entry.dart';

void main() {
  group('isSameDayEntry', () {
    HoursEntry entryAt(DateTime start, {int jobOrderId = 1, int employeeId = 6}) =>
        HoursEntry(
          jobOrderId: jobOrderId,
          employeeId: employeeId,
          start: start,
          end: start.add(const Duration(hours: 1)),
          totalTime: 60,
          timeEmployee: 60,
          workActivityId: 23,
          uniqueId: 'x',
        );

    test('matches same job order + employee + calendar day', () {
      final entry = entryAt(DateTime(2026, 8, 5, 8, 0));
      expect(
        isSameDayEntry(
          entry,
          jobOrderId: 1,
          employeeId: 6,
          date: DateTime(2026, 8, 5, 17, 45),
        ),
        isTrue,
      );
    });

    test('does not match a different calendar day, even close in time', () {
      // 23:30 on the 5th vs 00:30 on the 6th — less than an hour apart in
      // wall-clock time, but different calendar days.
      final entry = entryAt(DateTime(2026, 8, 5, 23, 30));
      expect(
        isSameDayEntry(
          entry,
          jobOrderId: 1,
          employeeId: 6,
          date: DateTime(2026, 8, 6, 0, 30),
        ),
        isFalse,
      );
    });

    test('does not match a different employee on the same day', () {
      final entry = entryAt(DateTime(2026, 8, 5, 8, 0), employeeId: 6);
      expect(
        isSameDayEntry(
          entry,
          jobOrderId: 1,
          employeeId: 7,
          date: DateTime(2026, 8, 5, 8, 0),
        ),
        isFalse,
      );
    });

    test('does not match a different job order on the same day', () {
      final entry = entryAt(DateTime(2026, 8, 5, 8, 0), jobOrderId: 1);
      expect(
        isSameDayEntry(
          entry,
          jobOrderId: 2,
          employeeId: 6,
          date: DateTime(2026, 8, 5, 8, 0),
        ),
        isFalse,
      );
    });
  });

  group('HoursEntryStore.upsert', () {
    test('a second save the same day reuses the uniqueId, not a duplicate', () {
      final store = HoursEntryStore.instance;
      final jobOrderId = DateTime.now().microsecondsSinceEpoch; // unique per test

      final first = store.upsert(
        jobOrderId: jobOrderId,
        employeeId: 6,
        start: DateTime(2026, 8, 5, 8, 0),
        end: DateTime(2026, 8, 5, 16, 0),
        workActivityId: 23,
      );

      final second = store.upsert(
        jobOrderId: jobOrderId,
        employeeId: 6,
        start: DateTime(2026, 8, 5, 9, 0),
        end: DateTime(2026, 8, 5, 17, 0),
        workActivityId: 20,
        memo: 'aangepast',
      );

      expect(store.entriesFor(jobOrderId), hasLength(1));
      expect(second.uniqueId, first.uniqueId);
      expect(second.workActivityId, 20);
      expect(second.memo, 'aangepast');
    });

    test('a different day for the same job order + employee is a new entry', () {
      final store = HoursEntryStore.instance;
      final jobOrderId = DateTime.now().microsecondsSinceEpoch + 1;

      final day1 = store.upsert(
        jobOrderId: jobOrderId,
        employeeId: 6,
        start: DateTime(2026, 8, 5, 8, 0),
        end: DateTime(2026, 8, 5, 16, 0),
        workActivityId: 23,
      );
      final day2 = store.upsert(
        jobOrderId: jobOrderId,
        employeeId: 6,
        start: DateTime(2026, 8, 6, 8, 0),
        end: DateTime(2026, 8, 6, 16, 0),
        workActivityId: 23,
      );

      expect(store.entriesFor(jobOrderId), hasLength(2));
      expect(day1.uniqueId, isNot(day2.uniqueId));
    });

    test('computes totalTime/timeEmployee in minutes from start/end', () {
      final store = HoursEntryStore.instance;
      final jobOrderId = DateTime.now().microsecondsSinceEpoch + 2;

      final entry = store.upsert(
        jobOrderId: jobOrderId,
        employeeId: 6,
        start: DateTime(2026, 8, 5, 8, 0),
        end: DateTime(2026, 8, 5, 16, 30),
        workActivityId: 23,
      );

      expect(entry.totalTime, 8 * 60 + 30);
      expect(entry.timeEmployee, entry.totalTime);
    });
  });

  group('HoursEntryStore.markSubmitted', () {
    test('clears entries only for the submitted job order', () {
      final store = HoursEntryStore.instance;
      final submittedJobOrderId = DateTime.now().microsecondsSinceEpoch + 3;
      final otherJobOrderId = DateTime.now().microsecondsSinceEpoch + 4;

      store.upsert(
        jobOrderId: submittedJobOrderId,
        employeeId: 6,
        start: DateTime(2026, 8, 5, 8, 0),
        end: DateTime(2026, 8, 5, 16, 0),
        workActivityId: 23,
      );
      store.upsert(
        jobOrderId: otherJobOrderId,
        employeeId: 6,
        start: DateTime(2026, 8, 5, 8, 0),
        end: DateTime(2026, 8, 5, 16, 0),
        workActivityId: 23,
      );

      store.markSubmitted(submittedJobOrderId);

      expect(store.entriesFor(submittedJobOrderId), isEmpty);
      expect(store.entriesFor(otherJobOrderId), hasLength(1));
    });
  });
}
