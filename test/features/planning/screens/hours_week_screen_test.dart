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

/// Het scherm start bij het openen een netwerkaanroep met `.timeout(...)`
/// (o.a. het ophalen van de uursoorten, 10 s). In een test komt het antwoord
/// niet binnen de nep-klok terug, dus staat die timer nog open als de test
/// eindigt en faalt de check "A Timer is still pending". Scherm weghalen en
/// de nep-klok voorbij de langste timeout laten lopen ruimt dat op.
Future<void> laatTimeoutsAflopen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 15));
}

void main() {
  testWidgets('renders with no bon selected (indirect hours), no layout exceptions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    setNarrowPhoneSurface(tester);

    await tester.pumpWidget(const CupertinoApp(home: HoursWeekScreen()));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    // Zonder bon opent het scherm in "Indirecte uren" (uren zonder bon).
    expect(find.text('Indirecte uren'), findsWidgets);
    expect(find.text('Nog geen uren of Kilometers toegevoegd'), findsWidgets);

    await laatTimeoutsAflopen(tester);
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

    await laatTimeoutsAflopen(tester);
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
