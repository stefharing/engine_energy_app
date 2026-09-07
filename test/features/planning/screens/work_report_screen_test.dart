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
  serviceObjectDescription: '',
  serviceType: '',
  location: '',
  relationName: '',
);

const _draftKey = 'work_report_draft_79';

/// The "Rapport opslaan" primary button is a GestureDetector (not a
/// CupertinoButton) so its background can animate between the
/// disabled/enabled colors — this finds it by its label text.
Finder _primaryButton(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(GestureDetector));

/// Taps an Overzicht row by its section title, opening that section's own
/// full-screen page.
Future<void> _openRow(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

/// Taps a section page's nav-bar back button, returning to Overzicht.
Future<void> _goBack(WidgetTester tester) async {
  await tester.tap(find.byType(CupertinoNavigationBarBackButton));
  await tester.pumpAndSettle();
}

/// Fills in the four required text/finding sections via the Overzicht hub
/// (open the row, type, go back), leaving "Foto's & documenten" — the
/// fifth required section — untouched.
Future<void> _fillRequiredTextSections(WidgetTester tester) async {
  await _openRow(tester, 'Werkomschrijving');
  await tester.enterText(
    find.byKey(const Key('workDescriptionField')),
    'Pomp vervangen',
  );
  await tester.pump();
  await _goBack(tester);

  await _openRow(tester, 'Beginsituatie');
  await tester.enterText(
    find.byKey(const Key('startingSituationField')),
    'Pomp lekte',
  );
  await tester.pump();
  await _goBack(tester);

  await _openRow(tester, 'Bevindingen');
  await tester.enterText(
    find.byKey(const Key('findingField_0')),
    'Pakking versleten',
  );
  await tester.pump();
  await _goBack(tester);

  await _openRow(tester, 'Aanbevelingen');
  await tester.enterText(
    find.byKey(const Key('recommendationsField')),
    'Jaarlijks controleren',
  );
  await tester.pump();
  await _goBack(tester);
}

void main() {
  testWidgets('typing into a field debounce-saves it to SharedPreferences', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const CupertinoApp(home: WorkReportScreen(order: _order)),
    );
    // Let the async _loadDraft() (SharedPreferences.getInstance() + the
    // resulting setState) complete before interacting.
    await tester.pump();
    await tester.pump();

    await _openRow(tester, 'Werkomschrijving');
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
  });

  testWidgets('an existing draft is restored into the fields on open', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      _draftKey: jsonEncode({
        'workDescription': 'Eerder ingevoerde tekst',
        'startingSituation': '',
        'findings': <dynamic>[],
        'recommendations': '',
        'photoPaths': <String>[],
        'documents': <dynamic>[],
        'status': 'draft',
      }),
    });

    await tester.pumpWidget(
      const CupertinoApp(home: WorkReportScreen(order: _order)),
    );
    await tester.pump();
    await tester.pump();

    await _openRow(tester, 'Werkomschrijving');

    final field = tester.widget<CupertinoTextField>(
      find.byKey(const Key('workDescriptionField')),
    );
    expect(field.controller!.text, 'Eerder ingevoerde tekst');
  });

  testWidgets(
    'tapping an Overzicht row opens that section, and the back button '
    'returns to Overzicht',
    (tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        const CupertinoApp(home: WorkReportScreen(order: _order)),
      );
      await tester.pump();
      await tester.pump();

      // On Overzicht: the section title only appears once, as a row.
      expect(find.text('Werkomschrijving'), findsOneWidget);
      expect(find.byKey(const Key('workDescriptionField')), findsNothing);

      await _openRow(tester, 'Werkomschrijving');

      expect(find.byKey(const Key('workDescriptionField')), findsOneWidget);
      expect(find.text('Rapport opslaan'), findsNothing);

      await _goBack(tester);

      expect(find.byKey(const Key('workDescriptionField')), findsNothing);
      expect(find.text('Rapport opslaan'), findsOneWidget);
    },
  );

  testWidgets(
    'a blank finding does not satisfy the Bevindingen section, so it stays '
    "incomplete in the overview's ring",
    (tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        const CupertinoApp(home: WorkReportScreen(order: _order)),
      );
      await tester.pump();
      await tester.pump();

      await _openRow(tester, 'Bevindingen');
      // One blank finding is seeded by default — leave it empty.
      expect(find.byKey(const Key('findingField_0')), findsOneWidget);
      await _goBack(tester);

      expect(find.text('0 van 5 onderdelen compleet'), findsOneWidget);
    },
  );

  testWidgets(
    "Foto's & documenten only counts as complete once an attachment exists",
    (tester) async {
      // Seed a document — attaching one via the UI depends on the native
      // file/image pickers, which aren't available in widget tests.
      SharedPreferences.setMockInitialValues({
        _draftKey: jsonEncode({
          'workDescription': '',
          'startingSituation': '',
          'findings': <dynamic>[],
          'recommendations': '',
          'photoPaths': <String>[],
          'documents': [
            {'path': 'dummy/doc.pdf', 'fileName': 'test.pdf'},
          ],
          'status': 'draft',
        }),
      });

      await tester.pumpWidget(
        const CupertinoApp(home: WorkReportScreen(order: _order)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('1 van 5 onderdelen compleet'), findsOneWidget);

      await _openRow(tester, "Foto's & documenten");
      expect(find.text('test.pdf'), findsOneWidget);
    },
  );

  testWidgets('Rapport opslaan stays disabled until every section (including '
      'attachments) is complete, then saves and closes the screen', (
    tester,
  ) async {
    // Seed a document up front so "Foto's & documenten" is already
    // satisfied without depending on the native file/image pickers.
    SharedPreferences.setMockInitialValues({
      _draftKey: jsonEncode({
        'workDescription': '',
        'startingSituation': '',
        'findings': <dynamic>[],
        'recommendations': '',
        'photoPaths': <String>[],
        'documents': [
          {'path': 'dummy/doc.pdf', 'fileName': 'test.pdf'},
        ],
        'status': 'draft',
      }),
    });

    await tester.pumpWidget(
      CupertinoApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () => Navigator.of(context).push(
              CupertinoPageRoute<void>(
                builder: (_) => const WorkReportScreen(order: _order),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<GestureDetector>(_primaryButton('Rapport opslaan').first)
          .onTap,
      isNull,
    );

    await _fillRequiredTextSections(tester);

    expect(find.text('5 van 5 onderdelen compleet'), findsOneWidget);
    final saveButton = _primaryButton('Rapport opslaan');
    expect(tester.widget<GestureDetector>(saveButton.first).onTap, isNotNull);

    await tester.tap(saveButton.first);
    await tester.pumpAndSettle();

    expect(find.text('Rapport opgeslagen'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // Confirming the dialog pops the report screen too.
    expect(find.text('Overzicht'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets("the Android/system back gesture on a section page returns to "
      'Overzicht instead of closing the report screen', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const CupertinoApp(home: WorkReportScreen(order: _order)),
    );
    await tester.pump();
    await tester.pump();

    await _openRow(tester, 'Werkomschrijving');
    expect(find.byKey(const Key('workDescriptionField')), findsOneWidget);

    final dynamic widgetsAppState = tester.state(find.byType(WidgetsApp));
    await widgetsAppState.didPopRoute();
    await tester.pumpAndSettle();

    // Back on Overzicht — the report screen itself is still open.
    expect(find.text('Rapport opslaan'), findsOneWidget);
    expect(find.byKey(const Key('workDescriptionField')), findsNothing);
  });
}
