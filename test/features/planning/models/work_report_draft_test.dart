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

  group('Finding', () {
    test('round-trips through toJson/fromJson', () {
      const finding = Finding(
        id: 'f1',
        text: 'Slijtage aan de as',
        severity: FindingSeverity.urgent,
      );

      final restored = Finding.fromJson(finding.toJson());

      expect(restored.id, finding.id);
      expect(restored.text, finding.text);
      expect(restored.severity, FindingSeverity.urgent);
    });

    test('fromJson defaults an unknown/missing severity to laag', () {
      final restored = Finding.fromJson({'id': 'f1', 'text': 'x'});
      expect(restored.severity, FindingSeverity.laag);
    });

    test('copyWith only overrides the given fields', () {
      const finding = Finding(id: 'f1', text: 'origineel');
      final updated = finding.copyWith(severity: FindingSeverity.aandacht);

      expect(updated.id, 'f1');
      expect(updated.text, 'origineel');
      expect(updated.severity, FindingSeverity.aandacht);
    });
  });

  group('WorkReportDraft', () {
    test('round-trips the text fields, findings, status and attachments', () {
      const draft = WorkReportDraft(
        workDescription: 'Pomp vervangen',
        startingSituation: 'Pomp lekte bij aankomst',
        findings: [
          Finding(
            id: 'f1',
            text: 'Slijtage aan de as',
            severity: FindingSeverity.aandacht,
          ),
        ],
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
        status: WorkReportStatus.saved,
      );

      final restored = WorkReportDraft.fromJson(draft.toJson());

      expect(restored.workDescription, draft.workDescription);
      expect(restored.startingSituation, draft.startingSituation);
      expect(restored.findings, hasLength(1));
      expect(restored.findings.first.text, 'Slijtage aan de as');
      expect(restored.findings.first.severity, FindingSeverity.aandacht);
      expect(restored.recommendations, draft.recommendations);
      expect(restored.photoPaths, draft.photoPaths);
      expect(restored.documents, hasLength(1));
      expect(restored.documents.first.path, draft.documents.first.path);
      expect(restored.documents.first.fileName, draft.documents.first.fileName);
      expect(restored.status, WorkReportStatus.saved);
    });

    test('fromJson defaults missing fields on an empty/partial map', () {
      final restored = WorkReportDraft.fromJson(const {});

      expect(restored.workDescription, '');
      expect(restored.startingSituation, '');
      expect(restored.findings, isEmpty);
      expect(restored.recommendations, '');
      expect(restored.photoPaths, isEmpty);
      expect(restored.documents, isEmpty);
      expect(restored.status, WorkReportStatus.draft);
    });

    test('fromJson treats an old-format `findings` string (pre-severity draft) '
        'as absent rather than throwing', () {
      final restored = WorkReportDraft.fromJson({
        'workDescription': 'Pomp vervangen',
        'findings': 'Slijtage aan de as',
      });

      expect(restored.workDescription, 'Pomp vervangen');
      expect(restored.findings, isEmpty);
    });

    test('copyWith only overrides the given fields', () {
      const draft = WorkReportDraft(workDescription: 'origineel');
      final updated = draft.copyWith(
        findings: const [Finding(id: 'f1', text: 'nieuwe bevinding')],
      );

      expect(updated.workDescription, 'origineel');
      expect(updated.findings.single.text, 'nieuwe bevinding');
    });

    test(
      'toJson survives a real jsonEncode/jsonDecode round trip (drafts are stored as JSON strings)',
      () {
        // Mirrors how WorkReportScreen actually persists the draft: via
        // jsonEncode(draft.toJson()) into SharedPreferences, and
        // jsonDecode(...) back out.
        const draft = WorkReportDraft(
          workDescription: 'Test "met quotes" en\nnieuwe regel',
          findings: [Finding(id: 'f1', text: 'Bevinding "met quotes"')],
          documents: [
            WorkReportDocumentRef(path: '/a/b.pdf', fileName: 'b.pdf'),
          ],
        );

        final encoded = jsonEncode(draft.toJson());
        final decoded = jsonDecode(encoded) as Map<String, dynamic>;
        final restored = WorkReportDraft.fromJson(decoded);

        expect(restored.workDescription, draft.workDescription);
        expect(restored.findings.single.text, 'Bevinding "met quotes"');
        expect(restored.documents.single.fileName, 'b.pdf');
      },
    );
  });
}
