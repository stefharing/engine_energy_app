import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/models/work_report_draft.dart';

void main() {
  group('WorkReportDocumentRef', () {
    test('round-trips through toJson/fromJson', () {
      const ref = WorkReportDocumentRef(
        path: '/app/docs/work_reports/79/documents/abc-123.pdf',
        fileName: 'Bevestiging_relatie.pdf',
      );

      final restored = WorkReportDocumentRef.fromJson(ref.toJson());

      expect(restored.path, ref.path);
      expect(restored.fileName, ref.fileName);
    });
  });

  group('WorkReportDraft', () {
    test('round-trips all four text fields and attachments', () {
      const draft = WorkReportDraft(
        workDescription: 'Pomp vervangen',
        startingSituation: 'Pomp lekte bij aankomst',
        findings: 'Slijtage aan de as',
        recommendations: 'Jaarlijks onderhoud aanbevolen',
        photoPaths: [
          '/app/docs/work_reports/79/photos/a.jpg',
          '/app/docs/work_reports/79/photos/b.jpg',
        ],
        documents: [
          WorkReportDocumentRef(
            path: '/app/docs/work_reports/79/documents/c.pdf',
            fileName: 'Garantiebewijs.pdf',
          ),
        ],
      );

      final restored = WorkReportDraft.fromJson(draft.toJson());

      expect(restored.workDescription, draft.workDescription);
      expect(restored.startingSituation, draft.startingSituation);
      expect(restored.findings, draft.findings);
      expect(restored.recommendations, draft.recommendations);
      expect(restored.photoPaths, draft.photoPaths);
      expect(restored.documents, hasLength(1));
      expect(restored.documents.first.path, draft.documents.first.path);
      expect(
        restored.documents.first.fileName,
        draft.documents.first.fileName,
      );
    });

    test('fromJson defaults missing fields on an empty/partial map', () {
      final restored = WorkReportDraft.fromJson(const {});

      expect(restored.workDescription, '');
      expect(restored.startingSituation, '');
      expect(restored.findings, '');
      expect(restored.recommendations, '');
      expect(restored.photoPaths, isEmpty);
      expect(restored.documents, isEmpty);
    });

    test('copyWith only overrides the given fields', () {
      const draft = WorkReportDraft(workDescription: 'origineel');
      final updated = draft.copyWith(findings: 'nieuwe bevinding');

      expect(updated.workDescription, 'origineel');
      expect(updated.findings, 'nieuwe bevinding');
    });

    test(
      'toJson survives a real jsonEncode/jsonDecode round trip (drafts are stored as JSON strings)',
      () {
        // Mirrors how WorkReportScreen actually persists the draft: via
        // jsonEncode(draft.toJson()) into SharedPreferences, and
        // jsonDecode(...) back out.
        const draft = WorkReportDraft(
          workDescription: 'Test "met quotes" en\nnieuwe regel',
          documents: [
            WorkReportDocumentRef(path: '/a/b.pdf', fileName: 'b.pdf'),
          ],
        );

        final encoded = jsonEncode(draft.toJson());
        final decoded = jsonDecode(encoded) as Map<String, dynamic>;
        final restored = WorkReportDraft.fromJson(decoded);

        expect(restored.workDescription, draft.workDescription);
        expect(restored.documents.single.fileName, 'b.pdf');
      },
    );
  });
}
