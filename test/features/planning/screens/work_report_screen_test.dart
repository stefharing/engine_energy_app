import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:engine_energy_app/features/planning/models/job_order.dart';
import 'package:engine_energy_app/features/planning/screens/work_report_screen.dart';

const _order = ServiceOrder(
  id: '79',
  recordTag: 'B-0079',
  orderNumber: 'B-0079',
  description: 'Testbon',
  startDate: null,
  endTime: null,
  deliveryDate: null,
  workflowState: 'Nieuw',
  mechanic: null,
  serviceObjectTag: '',
  serviceType: '',
  location: '',
  relationName: '',
);

const _draftKey = 'work_report_draft_79';

void main() {
  testWidgets(
    'typing into a field debounce-saves it to SharedPreferences',
    (tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        const CupertinoApp(home: WorkReportScreen(order: _order)),
      );
      // Let the async _loadDraft() (SharedPreferences.getInstance() + the
      // resulting setState) complete before interacting.
      await tester.pump();
      await tester.pump();

      await tester.enterText(
        find.byKey(const Key('workDescriptionField')),
        'Pomp vervangen',
      );

      // Immediately after typing, nothing should be persisted yet — the
      // save is debounced.
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_draftKey), isNull);

      // Past the 500ms debounce window, the draft should be saved.
      await tester.pump(const Duration(milliseconds: 600));

      prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftKey);
      expect(raw, isNotNull);
      final saved = jsonDecode(raw!) as Map<String, dynamic>;
      expect(saved['workDescription'], 'Pomp vervangen');
    },
  );

  testWidgets('an existing draft is restored into the fields on open', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      _draftKey: jsonEncode({
        'workDescription': 'Eerder ingevoerde tekst',
        'startingSituation': '',
        'findings': '',
        'recommendations': '',
        'photoPaths': <String>[],
        'documents': <dynamic>[],
      }),
    });

    await tester.pumpWidget(
      const CupertinoApp(home: WorkReportScreen(order: _order)),
    );
    await tester.pump();
    await tester.pump();

    final field = tester.widget<CupertinoTextField>(
      find.byKey(const Key('workDescriptionField')),
    );
    expect(field.controller!.text, 'Eerder ingevoerde tekst');
  });
}
