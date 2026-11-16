import 'dart:convert';

import 'package:engine_energy_app/features/planning/data/hours_draft_service.dart';
import 'package:engine_energy_app/features/planning/screens/hours_week_screen.dart'
    show hoursDraftKeyForOrder;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      hoursDraftKeyForOrder('42'): jsonEncode({
        'days': {
          '2026-9-28': {
            'cards': [
              {'id': 'a', 'workActivityId': 20, 'minutes': 120},
              {
                'id': 'b',
                'type': 'km',
                'workActivityId': 0,
                'minutes': 0,
                'km': 80,
                'submitted': true,
              },
            ],
          },
          '2026-9-29': {
            'cards': [
              {
                'id': 'c',
                'type': 'km',
                'workActivityId': 0,
                'minutes': 0,
                'km': 45,
              },
            ],
          },
        },
      }),
    });
  });

  test(
    'km cards are totalled per bon and leave the hours total alone',
    () async {
      expect(await HoursDraftService.instance.localTotalKm('42'), 125);
      expect(await HoursDraftService.instance.localTotalHours('42'), 2);
    },
  );

  test('breakdown labels km cards as Kilometers with their distance', () async {
    final days = await HoursDraftService.instance.localDailyBreakdown('42');
    expect(days, hasLength(2));
    final km = days.first.cards.last;
    expect(km.isKm, isTrue);
    expect(km.label, 'Kilometers');
    expect(km.km, 80);
    expect(days.first.cards.first.isKm, isFalse);
    expect(days.last.cards.single.km, 45);
  });
}
