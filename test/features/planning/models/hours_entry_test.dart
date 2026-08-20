import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/models/hours_entry.dart';

void main() {
  group('minutesBetween', () {
    test('computes whole minutes for a plain range', () {
      final start = DateTime(2026, 8, 5, 8, 0);
      final end = DateTime(2026, 8, 5, 16, 30);
      expect(minutesBetween(start, end), 8 * 60 + 30);
    });

    test('handles a range crossing midnight', () {
      final start = DateTime(2026, 8, 5, 22, 0);
      final end = DateTime(2026, 8, 6, 1, 0);
      expect(minutesBetween(start, end), 3 * 60);
    });

    test('is zero for an identical start and end', () {
      final t = DateTime(2026, 8, 5, 9, 0);
      expect(minutesBetween(t, t), 0);
    });
  });

  group('HoursEntry.toJson', () {
    HoursEntry entry({int totalTime = 60}) => HoursEntry(
      jobOrderId: 79,
      employeeId: 6,
      start: DateTime.utc(2026, 8, 22, 8, 0),
      end: DateTime.utc(2026, 8, 22, 9, 0),
      totalTime: totalTime,
      timeEmployee: totalTime,
      workActivityId: 20,
      uniqueId: 'abc-123',
    );

    test('converts minutes to ticks — confirmed 1 hour = 36,000,000,000', () {
      final json = entry(totalTime: 60).toJson();
      expect(json['totalTime'], 36000000000);
      expect(json['timeEmployee'], 36000000000);
    });

    test('converts a partial-hour minute value to ticks correctly', () {
      final json = entry(totalTime: 90).toJson();
      expect(json['totalTime'], 90 * 600000000);
    });

    test('formats start/end as Z-suffixed UTC with no milliseconds', () {
      final json = entry().toJson();
      expect(json['start'], '2026-08-22T08:00:00Z');
      expect(json['end'], '2026-08-22T09:00:00Z');
    });

    test('includes dateChanged and recordTag:null (confirmed shape)', () {
      final json = entry().toJson();
      expect(json['dateChanged'], isNotNull);
      expect(json.containsKey('recordTag'), isTrue);
      expect(json['recordTag'], isNull);
    });

    test('always includes the fixed zero pricing fields', () {
      final json = entry().toJson();
      expect(json['id'], 0);
      expect(json['delete'], false);
      expect(json['uniqueId'], 'abc-123');
      for (final key in [
        'pricePerHour',
        'contractDiscount',
        'discount',
        'totalPrice',
        'vatPercentage',
        'vatAmount',
        'totalPriceIncVAT',
      ]) {
        expect(json[key], 0, reason: '$key must stay 0');
      }
    });
  });
}
