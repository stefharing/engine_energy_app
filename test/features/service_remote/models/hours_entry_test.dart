import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/service_remote/models/hours_entry.dart';

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

  test('toJson always includes the fixed zero pricing fields', () {
    final entry = HoursEntry(
      jobOrderId: 59,
      employeeId: 6,
      start: DateTime(2026, 8, 5, 8, 0),
      end: DateTime(2026, 8, 5, 16, 0),
      totalTime: 480,
      timeEmployee: 480,
      workActivityId: 23,
      uniqueId: 'abc-123',
    );

    final json = entry.toJson();

    expect(json['id'], 0);
    expect(json['delete'], false);
    expect(json['uniqueId'], 'abc-123');
    expect(json['totalTime'], 480);
    expect(json['timeEmployee'], 480);
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
}
