import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/auth_service.dart';
import '../models/hours_entry.dart';
import '../models/job_order.dart';
import '../models/scanned_extra.dart';
import '../screens/hours_week_screen.dart' show hoursDraftKeyForOrder;
import 'planning_repository.dart';
import 'service_remote_job_order_repository.dart';

/// A single hour card as shown in the "Uren geregistreerd" breakdown —
/// its Uursoort label, duration and (optional) memo, exactly as entered
/// in `HoursWeekScreen`.
class HoursCardBreakdown {
  final String label;
  final int minutes;
  final String? memo;
  const HoursCardBreakdown({
    required this.label,
    required this.minutes,
    this.memo,
  });

  double get hours => minutes / 60;
}

/// One day's worth of [HoursCardBreakdown]s, oldest first.
class HoursDayBreakdown {
  final DateTime date;
  final List<HoursCardBreakdown> cards;
  const HoursDayBreakdown({required this.date, required this.cards});

  int get totalMinutes => cards.fold(0, (sum, c) => sum + c.minutes);
}

String _labelForActivity(int workActivityId) {
  if (workActivityId == workActivityIdTravel) return 'Reistijd';
  return workActivityOptions
      .firstWhere(
        (o) => o.id == workActivityId,
        orElse: () => const WorkActivityOption(-1, 'Overig'),
      )
      .label;
}

/// Submits a bon's locally-drafted (not-yet-submitted) hours — the same
/// cards a technician enters via `HoursWeekScreen`'s "+" button — without
/// opening that screen, namely from `BonDetailScreen`'s publish button.
/// Reads and writes the exact same SharedPreferences draft `HoursWeekScreen`
/// does (see [hoursDraftKeyForOrder]), so the two stay in sync: cards
/// published here show up locked/sent if that screen is opened afterwards.
class HoursDraftService {
  HoursDraftService._();
  static final instance = HoursDraftService._();

  static const _uuid = Uuid();

  Future<Map<String, dynamic>> _readDraftDays(String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(hoursDraftKeyForOrder(orderId));
    if (raw == null) return {};
    final draft = jsonDecode(raw) as Map<String, dynamic>;
    return (draft['days'] as Map<String, dynamic>?) ?? {};
  }

  /// Total hours in [orderId]'s local draft — every card, whether or not
  /// it's been submitted to Ridder yet. This is what [BonDetailScreen]
  /// shows as "Uren & km" registered so far.
  Future<double> localTotalHours(String orderId) async {
    final days = await _readDraftDays(orderId);
    var minutes = 0;
    for (final dayEntry in days.values) {
      final cards = (dayEntry as Map)['cards'] as List<dynamic>? ?? const [];
      for (final c in cards) {
        minutes += (c as Map)['minutes'] as int;
      }
    }
    return minutes / 60;
  }

  /// Per-day breakdown of [orderId]'s local draft — every card, with its
  /// Uursoort label and memo, grouped by day and sorted oldest first. This
  /// is what [WorkCompletionScreen] shows instead of a single combined
  /// total, so the technician can double-check exactly what was booked
  /// (and why) before publishing.
  Future<List<HoursDayBreakdown>> localDailyBreakdown(String orderId) async {
    final days = await _readDraftDays(orderId);
    final result = <HoursDayBreakdown>[];
    for (final dayEntry in days.entries) {
      final cards =
          (dayEntry.value as Map)['cards'] as List<dynamic>? ?? const [];
      if (cards.isEmpty) continue;
      final dateParts = dayEntry.key.split('-').map(int.parse).toList();
      result.add(
        HoursDayBreakdown(
          date: DateTime(dateParts[0], dateParts[1], dateParts[2]),
          cards: cards.map((c) {
            final map = c as Map;
            return HoursCardBreakdown(
              label: _labelForActivity(map['workActivityId'] as int),
              minutes: map['minutes'] as int,
              memo: (map['memo'] as String?)?.trim().isEmpty ?? true
                  ? null
                  : map['memo'] as String?,
            );
          }).toList(),
        ),
      );
    }
    result.sort((a, b) => a.date.compareTo(b.date));
    return result;
  }

  /// Publishes pending hour cards and extra-material drafts in one Service
  /// Remote job-order submission. Both drafts are marked sent only after the
  /// POST succeeds.
  Future<void> submitPendingHours(ServiceOrder order) async {
    final mechanicId = AuthService.instance.currentMechanicId;
    if (mechanicId == null) {
      throw const JobOrderSubmissionLoginFailed('Not logged in.');
    }
    final days = await _readDraftDays(order.id);
    final prefs = await SharedPreferences.getInstance();
    final extrasRaw = prefs.getString('extra_scanned_${order.id}') ?? '[]';
    final extras = (jsonDecode(extrasRaw) as List<dynamic>)
        .map(
          (value) =>
              ScannedExtra.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList();
    final pendingExtras = extras
        .where((extra) => extra.needsPublication)
        .toList();

    final entries = <HoursEntry>[];
    final updatedDays = <String, dynamic>{};
    for (final dayEntry in days.entries) {
      final dayMap = Map<String, dynamic>.from(dayEntry.value as Map);
      final cards = ((dayMap['cards'] as List<dynamic>?) ?? const [])
          .map((c) => Map<String, dynamic>.from(c as Map))
          .toList();
      final dateParts = dayEntry.key.split('-').map(int.parse).toList();
      var cursor = DateTime(dateParts[0], dateParts[1], dateParts[2], 8);
      final updatedCards = <Map<String, dynamic>>[];
      for (final card in cards) {
        final alreadySubmitted = card['submitted'] as bool? ?? false;
        final minutes = card['minutes'] as int;
        if (!alreadySubmitted) {
          final end = cursor.add(Duration(minutes: minutes));
          entries.add(
            HoursEntry(
              jobOrderId: int.parse(order.id),
              employeeId: mechanicId,
              start: cursor,
              end: end,
              totalTime: minutes,
              timeEmployee: minutes,
              workActivityId: card['workActivityId'] as int,
              uniqueId: _uuid.v4(),
              memo: card['memo'] as String?,
            ),
          );
          cursor = end;
        }
        updatedCards.add({...card, 'submitted': true});
      }
      updatedDays[dayEntry.key] = {'cards': updatedCards};
    }
    if (entries.isEmpty && pendingExtras.isEmpty) return;

    await ServiceRemoteJobOrderRepository.instance.submitHoursForJobOrder(
      jobOrderId: int.parse(order.id),
      employeeId: mechanicId,
      hours: entries,
      extras: pendingExtras,
    );

    if (days.isNotEmpty) {
      await prefs.setString(
        hoursDraftKeyForOrder(order.id),
        jsonEncode({'days': updatedDays}),
      );
    }
    if (pendingExtras.isNotEmpty) {
      final updatedExtras = extras
          .map(
            (extra) => pendingExtras.contains(extra)
                ? extra.copyWith(syncedQuantity: extra.scannedCount)
                : extra,
          )
          .toList();
      await prefs.setString(
        'extra_scanned_${order.id}',
        jsonEncode(updatedExtras.map((extra) => extra.toJson()).toList()),
      );
    }
  }
}
