import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/work_report_storage.dart';
import '../models/job_order.dart';
import '../models/work_report_draft.dart';

/// Capture-only work-report screen for a bon: four free-text fields plus
/// photo/document attachments, persisted as a local draft (same
/// SharedPreferences-backed pattern as `hours_week_screen.dart`). No PDF
/// generation and no submission to Ridder — that's a deliberately separate
/// future task, once the right API endpoint is confirmed.
class WorkReportScreen extends StatefulWidget {
  final ServiceOrder order;

  const WorkReportScreen({super.key, required this.order});

  @override
  State<WorkReportScreen> createState() => _WorkReportScreenState();
}

class _WorkReportScreenState extends State<WorkReportScreen> {
  late final TextEditingController _workDescriptionCtrl;
  late final TextEditingController _startingSituationCtrl;
  late final TextEditingController _findingsCtrl;
  late final TextEditingController _recommendationsCtrl;

  List<String> _photoPaths = [];
  List<WorkReportDocumentRef> _documents = [];

  bool _loading = true;
  Timer? _draftSaveTimer;

  String get _draftKey => 'work_report_draft_${widget.order.id}';

  @override
  void initState() {
    super.initState();
    _workDescriptionCtrl = TextEditingController()
      ..addListener(_scheduleDraftSave);
    _startingSituationCtrl = TextEditingController()
      ..addListener(_scheduleDraftSave);
    _findingsCtrl = TextEditingController()..addListener(_scheduleDraftSave);
    _recommendationsCtrl = TextEditingController()
      ..addListener(_scheduleDraftSave);
    _loadDraft();
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    _workDescriptionCtrl.dispose();
    _startingSituationCtrl.dispose();
    _findingsCtrl.dispose();
    _recommendationsCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftKey);
    if (raw != null) {
      final draft = WorkReportDraft.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      _workDescriptionCtrl.text = draft.workDescription;
      _startingSituationCtrl.text = draft.startingSituation;
      _findingsCtrl.text = draft.findings;
      _recommendationsCtrl.text = draft.recommendations;
      _photoPaths = List.of(draft.photoPaths);
      _documents = List.of(draft.documents);
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Debounced auto-save — same pattern as `HoursWeekScreen`'s draft
  /// autosave, duplicated here rather than shared: it's four lines tied
  /// directly to this screen's own save method, not worth abstracting.
  void _scheduleDraftSave() {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 500), _saveDraft);
  }

  Future<void> _saveDraft() async {
    final draft = WorkReportDraft(
      workDescription: _workDescriptionCtrl.text,
      startingSituation: _startingSituationCtrl.text,
      findings: _findingsCtrl.text,
      recommendations: _recommendationsCtrl.text,
      photoPaths: _photoPaths,
      documents: _documents,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftKey, jsonEncode(draft.toJson()));
  }

  Future<void> _addPhoto() async {
    final source = await showCupertinoModalPopup<ImageSource>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Foto toevoegen'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop(ImageSource.camera),
            child: const Text('Maak foto'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop(ImageSource.gallery),
            child: const Text('Kies uit bibliotheek'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
    if (source == null) return;

    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
    );
    if (picked == null) return;

    // Copy into a stable, app-owned directory — the picker's own path may
    // be a temp/cache path the OS can clear at any time.
    final storedPath = await WorkReportStorage.copyPhoto(
      widget.order.id,
      picked.path,
    );
    if (!mounted) return;
    setState(() => _photoPaths = [..._photoPaths, storedPath]);
    _scheduleDraftSave();
  }

  Future<void> _removePhoto(String path) async {
    setState(() => _photoPaths = _photoPaths.where((p) => p != path).toList());
    _scheduleDraftSave();
    await WorkReportStorage.delete(path);
  }

  Future<void> _addDocument() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null) return;

    final newDocs = <WorkReportDocumentRef>[];
    for (final file in result.files) {
      final path = file.path;
      if (path == null) continue;
      final storedPath = await WorkReportStorage.copyDocument(
        widget.order.id,
        path,
      );
      newDocs.add(WorkReportDocumentRef(path: storedPath, fileName: file.name));
    }
    if (newDocs.isEmpty || !mounted) return;
    setState(() => _documents = [..._documents, ...newDocs]);
    _scheduleDraftSave();
  }

  Future<void> _removeDocument(WorkReportDocumentRef doc) async {
    setState(
      () => _documents = _documents.where((d) => d.path != doc.path).toList(),
    );
    _scheduleDraftSave();
    await WorkReportStorage.delete(doc.path);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.systemBackground,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.label,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: const Text(
          'Rapport',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Klaar'),
        ),
      ),
      child: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => FocusScope.of(context).unfocus(),
              child: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    _FieldSection(
                      fieldKey: const Key('workDescriptionField'),
                      label: 'Werkomschrijving',
                      controller: _workDescriptionCtrl,
                      placeholder: 'Wat is er uitgevoerd?',
                      cardBg: cardBg,
                      borderColor: borderColor,
                    ),
                    const SizedBox(height: 20),
                    _FieldSection(
                      fieldKey: const Key('startingSituationField'),
                      label: 'Beginsituatie',
                      controller: _startingSituationCtrl,
                      placeholder: 'Situatie bij aankomst...',
                      cardBg: cardBg,
                      borderColor: borderColor,
                    ),
                    const SizedBox(height: 20),
                    _FieldSection(
                      fieldKey: const Key('findingsField'),
                      label: 'Bevindingen',
                      controller: _findingsCtrl,
                      placeholder: 'Wat is er geconstateerd?',
                      cardBg: cardBg,
                      borderColor: borderColor,
                    ),
                    const SizedBox(height: 20),
                    _FieldSection(
                      fieldKey: const Key('recommendationsField'),
                      label: 'Aanbevelingen',
                      controller: _recommendationsCtrl,
                      placeholder: 'Advies voor de klant...',
                      cardBg: cardBg,
                      borderColor: borderColor,
                    ),
                    const SizedBox(height: 28),
                    const _SectionLabel("Foto's"),
                    const SizedBox(height: 10),
                    _PhotoStrip(
                      paths: _photoPaths,
                      isDark: isDark,
                      onAdd: _addPhoto,
                      onRemove: _removePhoto,
                    ),
                    const SizedBox(height: 28),
                    const _SectionLabel('Documenten'),
                    const SizedBox(height: 10),
                    _DocumentList(
                      documents: _documents,
                      cardBg: cardBg,
                      borderColor: borderColor,
                      onAdd: _addDocument,
                      onRemove: _removeDocument,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

// ─── Section label ─────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String title;
  const _SectionLabel(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    );
  }
}

// ─── Free-text field section ───────────────────────────────────────────────

class _FieldSection extends StatelessWidget {
  final Key? fieldKey;
  final String label;
  final TextEditingController controller;
  final String placeholder;
  final Color cardBg;
  final Color borderColor;

  const _FieldSection({
    this.fieldKey,
    required this.label,
    required this.controller,
    required this.placeholder,
    required this.cardBg,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(label),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: CupertinoTextField(
            key: fieldKey,
            controller: controller,
            placeholder: placeholder,
            placeholderStyle: TextStyle(
              fontSize: 14,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
            style: TextStyle(
              fontSize: 15,
              color: CupertinoColors.label.resolveFrom(context),
            ),
            minLines: 4,
            maxLines: null,
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(),
          ),
        ),
      ],
    );
  }
}

// ─── Photo strip ────────────────────────────────────────────────────────────

class _PhotoStrip extends StatelessWidget {
  final List<String> paths;
  final bool isDark;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  const _PhotoStrip({
    required this.paths,
    required this.isDark,
    required this.onAdd,
    required this.onRemove,
  });

  static const _size = 84.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _size,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final path in paths)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _PhotoThumb(
                path: path,
                size: _size,
                onRemove: () => onRemove(path),
              ),
            ),
          _AddPhotoTile(size: _size, isDark: isDark, onTap: onAdd),
        ],
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  final String path;
  final double size;
  final VoidCallback onRemove;

  const _PhotoThumb({
    required this.path,
    required this.size,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(path),
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: CupertinoColors.destructiveRed,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  CupertinoIcons.xmark,
                  size: 12,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddPhotoTile extends StatelessWidget {
  final double size;
  final bool isDark;
  final VoidCallback onTap;

  const _AddPhotoTile({
    required this.size,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const tint = CupertinoColors.activeBlue;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: tint.withValues(alpha: isDark ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tint.withValues(alpha: 0.3)),
        ),
        child: const Icon(CupertinoIcons.add, color: tint, size: 24),
      ),
    );
  }
}

// ─── Document list ──────────────────────────────────────────────────────────

class _DocumentList extends StatelessWidget {
  final List<WorkReportDocumentRef> documents;
  final Color cardBg;
  final Color borderColor;
  final VoidCallback onAdd;
  final ValueChanged<WorkReportDocumentRef> onRemove;

  const _DocumentList({
    required this.documents,
    required this.cardBg,
    required this.borderColor,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final doc in documents)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _DocumentRow(
              document: doc,
              cardBg: cardBg,
              borderColor: borderColor,
              onRemove: () => onRemove(doc),
            ),
          ),
        _AddDocumentRow(cardBg: cardBg, borderColor: borderColor, onTap: onAdd),
      ],
    );
  }
}

class _DocumentRow extends StatelessWidget {
  final WorkReportDocumentRef document;
  final Color cardBg;
  final Color borderColor;
  final VoidCallback onRemove;

  const _DocumentRow({
    required this.document,
    required this.cardBg,
    required this.borderColor,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF2C3E6B).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              CupertinoIcons.doc_text,
              size: 16,
              color: Color(0xFF2C3E6B),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              document.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onRemove,
            behavior: HitTestBehavior.opaque,
            child: Icon(
              CupertinoIcons.xmark_circle_fill,
              size: 20,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddDocumentRow extends StatelessWidget {
  final Color cardBg;
  final Color borderColor;
  final VoidCallback onTap;

  const _AddDocumentRow({
    required this.cardBg,
    required this.borderColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const tint = CupertinoColors.activeBlue;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tint.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: const Icon(CupertinoIcons.add, size: 18, color: tint),
            ),
            const SizedBox(width: 12),
            const Text(
              'Document toevoegen',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: tint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
