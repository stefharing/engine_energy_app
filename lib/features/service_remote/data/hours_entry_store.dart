import 'package:uuid/uuid.dart';

import '../models/hours_entry.dart';

/// Whether [entry] is the existing local entry for the same job order +
/// employee + calendar day as ([jobOrderId], [employeeId], [date]) — i.e.
/// "does saving this reuse [entry]'s uniqueId instead of creating a new
/// entry". Match key is jobOrderId + employeeId + calendar date of `start`,
/// deliberately ignoring time-of-day and `end`, so any number of edits
/// within the same day land on the same registration instead of creating
/// duplicates in Ridder.
///
/// [entry.start] and [date] are compared as given (both local `DateTime`s
/// from the picker/store — never parsed from a UTC API string here), so
/// there's no UTC/local conversion in this comparison to get wrong.
bool isSameDayEntry(
  HoursEntry entry, {
  required int jobOrderId,
  required int employeeId,
  required DateTime date,
}) {
  if (entry.jobOrderId != jobOrderId) return false;
  if (entry.employeeId != employeeId) return false;
  final entryDate = entry.start;
  return entryDate.year == date.year &&
      entryDate.month == date.month &&
      entryDate.day == date.day;
}

/// In-memory store of locally-entered [HoursEntry] objects, keyed by job
/// order. Lives for the app process (mirrors the `JobOrderRepository`/
/// `AuthService` singleton pattern), so entries survive navigating away
/// from and back to a job order detail screen within a session. Nothing
/// here is submitted to the API — that's phase 5.
class HoursEntryStore {
  HoursEntryStore._();
  static final HoursEntryStore instance = HoursEntryStore._();

  final Map<int, List<HoursEntry>> _byJobOrder = {};
  final Uuid _uuid = const Uuid();

  List<HoursEntry> entriesFor(int jobOrderId) =>
      List.unmodifiable(_byJobOrder[jobOrderId] ?? const []);

  /// Call after a successful `submitJobOrder` for [jobOrderId]: the local
  /// entries have been sent to Ridder, so they're removed rather than left
  /// around as still-editable drafts (which would let a later "add hours"
  /// action for the same day silently re-edit already-submitted data).
  void markSubmitted(int jobOrderId) {
    _byJobOrder.remove(jobOrderId);
  }

  /// Adds a new hours entry, or — if one already exists for the same job
  /// order + employee + calendar day of [start] (see [isSameDayEntry]) —
  /// updates that entry in place, reusing its `uniqueId`. A fresh
  /// `uniqueId` is only generated the first time a given day is entered.
  HoursEntry upsert({
    required int jobOrderId,
    required int employeeId,
    required DateTime start,
    required DateTime end,
    required int workActivityId,
    String? memo,
  }) {
    final entries = _byJobOrder.putIfAbsent(jobOrderId, () => []);
    final index = entries.indexWhere(
      (e) => isSameDayEntry(
        e,
        jobOrderId: jobOrderId,
        employeeId: employeeId,
        date: start,
      ),
    );
    final minutes = minutesBetween(start, end);
    final entry = HoursEntry(
      jobOrderId: jobOrderId,
      employeeId: employeeId,
      start: start,
      end: end,
      totalTime: minutes,
      timeEmployee: minutes,
      workActivityId: workActivityId,
      uniqueId: index == -1 ? _uuid.v4() : entries[index].uniqueId,
      memo: memo,
    );

    if (index == -1) {
      entries.add(entry);
    } else {
      entries[index] = entry;
    }
    entries.sort((a, b) => a.start.compareTo(b.start));
    return entry;
  }
}
