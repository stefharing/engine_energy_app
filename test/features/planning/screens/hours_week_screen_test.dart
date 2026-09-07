import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:engine_energy_app/features/planning/models/job_order.dart';
import 'package:engine_energy_app/features/planning/screens/hours_week_screen.dart';

final _order = ServiceOrder(
  id: '79',
  recordTag: 'B-0079',
  orderNumber: 'B-0079',
  description: 'Testbon voor overflow-check met een best lange omschrijving',
  startDate: DateTime.now(),
  endTime: DateTime.now().add(const Duration(days: 1)),
  deliveryDate: null,
  workflowState: 'Nieuw',
  mechanic: null,
  serviceObjectTag: '',
  serviceObjectDescription: '',
  serviceType: '',
  location: '',
  relationName: '',
);

void setNarrowPhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('renders with no bon selected, no layout exceptions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    setNarrowPhoneSurface(tester);

    await tester.pumpWidget(const CupertinoApp(home: HoursWeekScreen()));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Selecteer een bon'), findsOneWidget);
    expect(find.text('Geen bon geselecteerd'), findsOneWidget);
  });

  testWidgets('renders with an initial bon selected, no layout exceptions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    setNarrowPhoneSurface(tester);

    await tester.pumpWidget(
      CupertinoApp(home: HoursWeekScreen(initialOrder: _order)),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text(_order.description), findsOneWidget);
  });

  testWidgets('swiping through the 29-day range does not overflow', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    setNarrowPhoneSurface(tester);

    await tester.pumpWidget(
      CupertinoApp(home: HoursWeekScreen(initialOrder: _order)),
    );
    await tester.pump();
    await tester.pump();

    for (var i = 0; i < 6; i++) {
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    for (var i = 0; i < 8; i++) {
      await tester.fling(find.byType(PageView), const Offset(300, 0), 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('tapping a day chip near the end of the range works', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    setNarrowPhoneSurface(tester);

    await tester.pumpWidget(
      CupertinoApp(home: HoursWeekScreen(initialOrder: _order)),
    );
    await tester.pump();
    await tester.pump();

    final chips = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_DayTabChip');
    expect(chips, findsNWidgets(29));

    await tester.tap(chips.last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
