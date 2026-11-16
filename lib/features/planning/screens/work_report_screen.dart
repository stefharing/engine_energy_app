import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/work_report_snippets.dart';
import '../data/work_report_storage.dart';
import '../models/job_order.dart';
import '../models/work_report_draft.dart';
import '../../../core/theme/app_colors.dart';

/// Titles for each fillable section of the report, in order. Variant 1d of
/// the wizard redesign: a completion ring (not a linear bar or dot row), a
/// dedicated severity-tagged findings section, and photos+documents merged
/// into one attachments section — with Overzicht as the hub: each section
/// is its own full-screen page reached from, and returned to, the
/// overview, rather than a Volgende/Vorige-driven linear flow.
const _stepTitles = [
  'Werkomschrijving',
  'Beginsituatie',
  'Bevindingen',
  'Aanbevelingen',
  "Foto's & documenten",
];

/// Capture-only work-report screen for a bon: an overview hub over three
/// free-text sections, a list of severity-tagged findings, and
/// photo/document attachments, persisted as a local draft (same
/// SharedPreferences-backed pattern as `hours_week_screen.dart`). The
/// content ends up on the visit report the customer signs
/// (`VisitReportScreen`), which goes to Ridder as `htmlFile` on "Werk
/// afronden"; photos and documents are uploaded there as attachments.
class WorkReportScreen extends StatefulWidget {
  final ServiceOrder order;

  const WorkReportScreen({super.key, required this.order});

  @override
  State<WorkReportScreen> createState() => _WorkReportScreenState();
}

class _WorkReportScreenState extends State<WorkReportScreen> {
  late final TextEditingController _workDescriptionCtrl;
  late final TextEditingController _startingSituationCtrl;
  late final TextEditingController _recommendationsCtrl;
  final _uuid = const Uuid();

  List<Finding> _findings = [];
  final Map<String, TextEditingController> _findingCtrls = {};

  List<String> _photoPaths = [];
  List<WorkReportDocumentRef> _documents = [];
  WorkReportStatus _status = WorkReportStatus.draft;

  List<String> _workSnippets = const [];
  List<String> _beginSnippets = const [];
  List<String> _aanbevSnippets = const [];

  bool _loading = true;
  bool _justSaved = false;
  Timer? _draftSaveTimer;
  Timer? _savedBadgeTimer;

  /// Which section is currently shown full-screen — null means the
  /// Overzicht hub itself is showing.
  int? _openStepIndex;

  String get _draftKey => 'work_report_draft_${widget.order.id}';

  /// Whether section [step] (0..4) has enough filled in to count as
  /// complete — drives the completion ring and the overview rows.
  bool _stepComplete(int step) {
    switch (step) {
      case 0:
        return _workDescriptionCtrl.text.trim().isNotEmpty;
      case 1:
        return _startingSituationCtrl.text.trim().isNotEmpty;
      case 2:
        return _findings.any((f) => f.text.trim().isNotEmpty);
      case 3:
        return _recommendationsCtrl.text.trim().isNotEmpty;
      case 4:
        return _photoPaths.isNotEmpty || _documents.isNotEmpty;
      default:
        return true;
    }
  }

  int get _completedRequiredCount =>
      List.generate(_stepTitles.length, (i) => i).where(_stepComplete).length;

  bool get _allRequiredComplete => _completedRequiredCount == _stepTitles.length;

  /// Geen onderdeel is verplicht; opslaan kan zodra er iets is ingevuld.
  bool get _anyComplete => _completedRequiredCount > 0;

  List<String> get _emptyStepTitles => [
    for (var i = 0; i < _stepTitles.length; i++)
      if (!_stepComplete(i)) _stepTitles[i],
  ];

  @override
  void initState() {
    super.initState();
    _workDescriptionCtrl = TextEditingController()
      ..addListener(_onFieldChanged);
    _startingSituationCtrl = TextEditingController()
      ..addListener(_onFieldChanged);
    _recommendationsCtrl = TextEditingController()
      ..addListener(_onFieldChanged);
    _loadDraft();
    _loadSnippets();
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    _savedBadgeTimer?.cancel();
    _workDescriptionCtrl.dispose();
    _startingSituationCtrl.dispose();
    _recommendationsCtrl.dispose();
    for (final c in _findingCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSnippets() async {
    final work = await WorkReportSnippets.forField('workDescription');
    final begin = await WorkReportSnippets.forField('startingSituation');
    final aanbev = await WorkReportSnippets.forField('recommendations');
    if (!mounted) return;
    setState(() {
      _workSnippets = work;
      _beginSnippets = begin;
      _aanbevSnippets = aanbev;
    });
  }

  /// Same debounced autosave as before, plus an immediate rebuild so the
  /// footer's "Volgende" button and the completion ring update live as the
  /// user types.
  void _onFieldChanged() {
    _scheduleDraftSave();
    setState(() {});
  }

  void _openStep(int step) => setState(() => _openStepIndex = step);

  /// Returns from whichever section is open back to the Overzicht hub —
  /// used by every section page's back button, and by the hardware/swipe
  /// back gesture via the [PopScope] in [build].
  void _closeStep() {
    _recordSnippetForOpenStep();
    setState(() => _openStepIndex = null);
  }

  /// Learns the text just entered on sections 0/1/3 as a snippet, so it can
  /// be offered back as a chip on a future report. Findings and
  /// attachments aren't plain-text fields, so they're not part of this.
  void _recordSnippetForOpenStep() {
    switch (_openStepIndex) {
      case 0:
        WorkReportSnippets.recordUsage(
          'workDescription',
          _workDescriptionCtrl.text,
        );
        break;
      case 1:
        WorkReportSnippets.recordUsage(
          'startingSituation',
          _startingSituationCtrl.text,
        );
        break;
      case 3:
        WorkReportSnippets.recordUsage(
          'recommendations',
          _recommendationsCtrl.text,
        );
        break;
    }
  }

  Future<void> _saveReport() async {
    if (!_anyComplete) return;
    if (!_allRequiredComplete) {
      final leeg = _emptyStepTitles;
      final doorgaan = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Niet alles ingevuld'),
          content: Text(
            'Deze onderdelen zijn nog leeg:\n\n'
            '${leeg.map((t) => '• $t').join('\n')}\n\n'
            'Ze komen niet op het bezoekrapport. Toch opslaan?',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Verder invullen'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Toch opslaan'),
            ),
          ],
        ),
      );
      if (doorgaan != true || !mounted) return;
    }
    setState(() => _status = WorkReportStatus.saved);
    await _saveDraft();
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Rapport opgeslagen'),
        content: const Text(
          'Het rapport komt op het bezoekrapport dat de klant tekent, en gaat '
          "samen met de foto's en documenten naar Ridder bij 'Werk afronden'.",
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  /// Restores a previously-saved draft. If it has no findings yet — either
  /// because there was no draft at all, or the saved one had none — seeds
  /// one blank finding so the step isn't a bare "+" button on first open.
  Future<void> _loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftKey);
    var findings = <Finding>[];
    if (raw != null) {
      final draft = WorkReportDraft.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      _workDescriptionCtrl.text = draft.workDescription;
      _startingSituationCtrl.text = draft.startingSituation;
      _recommendationsCtrl.text = draft.recommendations;
      _photoPaths = List.of(draft.photoPaths);
      _documents = List.of(draft.documents);
      _status = draft.status;
      findings = draft.findings;
    }
    if (findings.isEmpty) {
      findings = [Finding(id: _uuid.v4())];
    }
    _findings = findings;
    for (final f in _findings) {
      _findingCtrls[f.id] = TextEditingController(text: f.text);
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Debounced auto-save of the current inputs as a local draft — fires
  /// shortly after the technician stops typing, so it doesn't hit
  /// SharedPreferences on every keystroke.
  void _scheduleDraftSave() {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 500), _saveDraft);
  }

  Future<void> _saveDraft() async {
    final draft = WorkReportDraft(
      workDescription: _workDescriptionCtrl.text,
      startingSituation: _startingSituationCtrl.text,
      findings: _findings,
      recommendations: _recommendationsCtrl.text,
      photoPaths: _photoPaths,
      documents: _documents,
      status: _status,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftKey, jsonEncode(draft.toJson()));
    if (!mounted) return;
    setState(() => _justSaved = true);
    _savedBadgeTimer?.cancel();
    _savedBadgeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _justSaved = false);
    });
  }

  void _appendSnippet(TextEditingController ctrl, String snippet) {
    final current = ctrl.text;
    ctrl.text = current.trim().isEmpty ? snippet : '$current\n$snippet';
    ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
  }

  void _addFinding() {
    final f = Finding(id: _uuid.v4());
    _findingCtrls[f.id] = TextEditingController();
    setState(() => _findings = [..._findings, f]);
    _scheduleDraftSave();
  }

  void _removeFinding(String id) {
    _findingCtrls.remove(id)?.dispose();
    setState(() => _findings = _findings.where((f) => f.id != id).toList());
    _scheduleDraftSave();
  }

  void _onFindingTextChanged(String id) {
    final ctrl = _findingCtrls[id];
    if (ctrl == null) return;
    setState(() {
      _findings = _findings
          .map((f) => f.id == id ? f.copyWith(text: ctrl.text) : f)
          .toList();
    });
    _scheduleDraftSave();
  }

  void _onFindingSeverityChanged(String id, FindingSeverity sev) {
    setState(() {
      _findings = _findings
          .map((f) => f.id == id ? f.copyWith(severity: sev) : f)
          .toList();
    });
    _scheduleDraftSave();
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
    await _addPhotoFrom(source);
  }

  Future<void> _addPhotoFrom(ImageSource source) async {
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

  /// Lets a step other than "Foto's & documenten" attach a photo or
  /// document too — attachments aren't restricted to their own step.
  Future<void> _addAttachmentMenu() async {
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Bijlage toevoegen'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop('camera'),
            child: const Text('Maak foto'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop('gallery'),
            child: const Text('Kies foto uit bibliotheek'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop('document'),
            child: const Text('Kies document'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
    switch (choice) {
      case 'camera':
        await _addPhotoFrom(ImageSource.camera);
        break;
      case 'gallery':
        await _addPhotoFrom(ImageSource.gallery);
        break;
      case 'document':
        await _addDocument();
        break;
    }
  }

  String _textSummary(String text) {
    final t = text.trim();
    if (t.isEmpty) return 'Nog niet ingevuld';
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }

  String _findingsSummary() {
    final n = _findings.where((f) => f.text.trim().isNotEmpty).length;
    return n == 0 ? 'Nog niet ingevuld' : '$n bevinding(en) vastgelegd';
  }

  String _attachmentsSummary() {
    final parts = <String>[];
    if (_photoPaths.isNotEmpty) parts.add("${_photoPaths.length} foto's");
    if (_documents.isNotEmpty) {
      parts.add(
        '${_documents.length} document${_documents.length == 1 ? '' : 'en'}',
      );
    }
    return parts.isEmpty ? 'Nog niet ingevuld' : parts.join(' · ');
  }

  List<_OverviewRowData> get _overviewRows => [
    _OverviewRowData(
      _stepTitles[0],
      _stepComplete(0),
      _textSummary(_workDescriptionCtrl.text),
    ),
    _OverviewRowData(
      _stepTitles[1],
      _stepComplete(1),
      _textSummary(_startingSituationCtrl.text),
    ),
    _OverviewRowData(_stepTitles[2], _stepComplete(2), _findingsSummary()),
    _OverviewRowData(
      _stepTitles[3],
      _stepComplete(3),
      _textSummary(_recommendationsCtrl.text),
    ),
    _OverviewRowData(_stepTitles[4], _stepComplete(4), _attachmentsSummary()),
  ];

  Widget _stepContent(int index, Color cardBg, Color borderColor, bool isDark) {
    switch (index) {
      case 0:
        return _FieldSection(
          fieldKey: const Key('workDescriptionField'),
          label: _stepTitles[0],
          controller: _workDescriptionCtrl,
          placeholder: 'Wat is er uitgevoerd?',
          cardBg: cardBg,
          borderColor: borderColor,
          snippets: _workSnippets,
          onSnippetTap: (s) => _appendSnippet(_workDescriptionCtrl, s),
          onAttach: _addAttachmentMenu,
        );
      case 1:
        return _FieldSection(
          fieldKey: const Key('startingSituationField'),
          label: _stepTitles[1],
          controller: _startingSituationCtrl,
          placeholder: 'Situatie bij aankomst...',
          cardBg: cardBg,
          borderColor: borderColor,
          snippets: _beginSnippets,
          onSnippetTap: (s) => _appendSnippet(_startingSituationCtrl, s),
          onAttach: _addAttachmentMenu,
        );
      case 2:
        return _FindingsStep(
          findings: _findings,
          controllers: _findingCtrls,
          cardBg: cardBg,
          borderColor: borderColor,
          onTextChanged: _onFindingTextChanged,
          onSeverityChanged: _onFindingSeverityChanged,
          onRemove: _removeFinding,
          onAdd: _addFinding,
          onAttach: _addAttachmentMenu,
        );
      case 3:
        return _FieldSection(
          fieldKey: const Key('recommendationsField'),
          label: _stepTitles[3],
          controller: _recommendationsCtrl,
          placeholder: 'Advies voor de klant...',
          cardBg: cardBg,
          borderColor: borderColor,
          snippets: _aanbevSnippets,
          onSnippetTap: (s) => _appendSnippet(_recommendationsCtrl, s),
          onAttach: _addAttachmentMenu,
        );
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionLabel("Foto's"),
            const SizedBox(height: 10),
            _PhotoStrip(
              paths: _photoPaths,
              isDark: isDark,
              onAdd: _addPhoto,
              onRemove: _removePhoto,
            ),
            const SizedBox(height: 20),
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
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final openStep = _openStepIndex;
    return PopScope(
      // While a section is open, the back gesture/button returns to
      // Overzicht instead of leaving the report screen entirely.
      canPop: openStep == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && openStep != null) _closeStep();
      },
      child: openStep == null ? _buildOverview(context) : _buildStep(context, openStep),
    );
  }

  Widget _buildOverview(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
        leading: CupertinoNavigationBarBackButton(
          color: AppColors.navForeground,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: Text(
          'Rapport',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.navForeground.resolveFrom(context),
          ),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Klaar'),
        ),
      ),
      child: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : SafeArea(
              // Onderkant doet _SaveFooter zelf, anders blijft er een grijze
              // strook onder de knop staan.
              bottom: false,
              child: Column(
                children: [
                  _OverviewHeader(
                    completed: _completedRequiredCount,
                    total: _stepTitles.length,
                    justSaved: _justSaved,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      child: _OverviewStep(
                        rows: _overviewRows,
                        onTapRow: _openStep,
                      ),
                    ),
                  ),
                  _SaveFooter(
                    borderColor: borderColor,
                    isDark: isDark,
                    canSave: _anyComplete,
                    hint: !_anyComplete
                        ? 'Vul minstens één onderdeel in'
                        : _allRequiredComplete
                        ? null
                        : 'Niet alle onderdelen zijn verplicht',
                    onSave: _saveReport,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildStep(BuildContext context, int index) {
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
        backgroundColor: AppColors.navBar,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
        leading: CupertinoNavigationBarBackButton(
          color: AppColors.navForeground,
          onPressed: _closeStep,
        ),
        middle: Text(
          _stepTitles[index],
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.navForeground.resolveFrom(context),
          ),
        ),
        trailing: AnimatedOpacity(
          opacity: _justSaved ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: const Text(
            'Opgeslagen',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8E8E93),
            ),
          ),
        ),
      ),
      child: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: _stepContent(index, cardBg, borderColor, isDark),
          ),
        ),
      ),
    );
  }
}

// ─── Overview header ────────────────────────────────────────────────────────

class _OverviewHeader extends StatelessWidget {
  final int completed;
  final int total;
  final bool justSaved;

  const _OverviewHeader({
    required this.completed,
    required this.total,
    required this.justSaved,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: CupertinoColors.systemBackground.resolveFrom(context),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Row(
        children: [
          _RingProgress(
            progress: total == 0 ? 0 : completed / total,
            completed: completed,
            total: total,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Overzicht',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$completed van $total onderdelen ingevuld',
                  style: TextStyle(
                    fontSize: 12,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
          AnimatedOpacity(
            opacity: justSaved ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Text(
              'Opgeslagen',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Ring progress ───────────────────────────────────────────────────────────

class _RingProgress extends StatelessWidget {
  final double progress;
  final int completed;
  final int total;

  const _RingProgress({
    required this.progress,
    required this.completed,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress,
          trackColor: CupertinoColors.systemGrey5.resolveFrom(context),
        ),
        child: Center(
          child: Text(
            '$completed/$total',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Color(0xFF5856D6),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color trackColor;

  const _RingPainter({required this.progress, required this.trackColor});

  static const _strokeWidth = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - _strokeWidth) / 2;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress <= 0) return;
    final progressPaint = Paint()
      ..color = const Color(0xFF5856D6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      2 * pi * progress.clamp(0.0, 1.0),
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.trackColor != trackColor;
}

// ─── Save footer ────────────────────────────────────────────────────────────

/// The Overzicht hub's single "Rapport opslaan" action — grey and inert
/// until every section is complete, then green.
class _SaveFooter extends StatelessWidget {
  final Color borderColor;
  final bool isDark;
  final bool canSave;
  final VoidCallback onSave;
  final String? hint;

  const _SaveFooter({
    required this.borderColor,
    required this.isDark,
    required this.canSave,
    required this.onSave,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    final bg = canSave
        ? const Color(0xFF34C759)
        : AppColors.disabledFill.resolveFrom(context);
    final fg = canSave
        ? CupertinoColors.white
        : AppColors.disabledText.resolveFrom(context);

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomInset),
      decoration: BoxDecoration(
        color: cardBg,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hint != null) ...[
            Text(
              hint!,
              style: TextStyle(
                fontSize: 13,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 8),
          ],
          GestureDetector(
        onTap: canSave ? onSave : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Text(
            'Rapport opslaan',
            style: TextStyle(fontWeight: FontWeight.w600, color: fg),
          ),
        ),
      ),
        ],
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

// ─── Snippet chips ──────────────────────────────────────────────────────────

/// Tappable recall chips for text previously typed into this field on
/// earlier reports — tapping appends the snippet at the end of the current
/// text, it never replaces it.
class _SnippetChips extends StatelessWidget {
  final List<String> snippets;
  final ValueChanged<String> onTap;

  const _SnippetChips({required this.snippets, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (snippets.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SizedBox(
        height: 30,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: snippets.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final s = snippets[i];
            return GestureDetector(
              onTap: () => onTap(s),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF5856D6).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                alignment: Alignment.center,
                child: Text(
                  s.length > 28 ? '${s.substring(0, 28)}…' : s,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF5856D6),
                  ),
                ),
              ),
            );
          },
        ),
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
  final List<String> snippets;
  final ValueChanged<String> onSnippetTap;
  final VoidCallback onAttach;

  const _FieldSection({
    this.fieldKey,
    required this.label,
    required this.controller,
    required this.placeholder,
    required this.cardBg,
    required this.borderColor,
    required this.snippets,
    required this.onSnippetTap,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _SectionLabel(label)),
            GestureDetector(
              onTap: onAttach,
              behavior: HitTestBehavior.opaque,
              child: Icon(
                CupertinoIcons.paperclip,
                size: 18,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _SnippetChips(snippets: snippets, onTap: onSnippetTap),
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

// ─── Findings step ──────────────────────────────────────────────────────────

class _FindingsStep extends StatelessWidget {
  final List<Finding> findings;
  final Map<String, TextEditingController> controllers;
  final Color cardBg;
  final Color borderColor;
  final ValueChanged<String> onTextChanged;
  final void Function(String id, FindingSeverity sev) onSeverityChanged;
  final ValueChanged<String> onRemove;
  final VoidCallback onAdd;
  final VoidCallback onAttach;

  const _FindingsStep({
    required this.findings,
    required this.controllers,
    required this.cardBg,
    required this.borderColor,
    required this.onTextChanged,
    required this.onSeverityChanged,
    required this.onRemove,
    required this.onAdd,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionLabel('Bevindingen')),
            GestureDetector(
              onTap: onAttach,
              behavior: HitTestBehavior.opaque,
              child: Icon(
                CupertinoIcons.paperclip,
                size: 18,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (int i = 0; i < findings.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _FindingCard(
              fieldKey: Key('findingField_$i'),
              finding: findings[i],
              controller: controllers[findings[i].id]!,
              cardBg: cardBg,
              borderColor: borderColor,
              onTextChanged: () => onTextChanged(findings[i].id),
              onSeverityChanged: (sev) =>
                  onSeverityChanged(findings[i].id, sev),
              onRemove: () => onRemove(findings[i].id),
            ),
          ),
        _AddFindingRow(onTap: onAdd),
      ],
    );
  }
}

class _FindingCard extends StatelessWidget {
  final Key? fieldKey;
  final Finding finding;
  final TextEditingController controller;
  final Color cardBg;
  final Color borderColor;
  final VoidCallback onTextChanged;
  final ValueChanged<FindingSeverity> onSeverityChanged;
  final VoidCallback onRemove;

  const _FindingCard({
    this.fieldKey,
    required this.finding,
    required this.controller,
    required this.cardBg,
    required this.borderColor,
    required this.onTextChanged,
    required this.onSeverityChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: CupertinoTextField(
                  key: fieldKey,
                  controller: controller,
                  placeholder: 'Beschrijf de bevinding...',
                  placeholderStyle: TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
                  style: TextStyle(
                    fontSize: 15,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                  minLines: 2,
                  maxLines: null,
                  padding: EdgeInsets.zero,
                  decoration: const BoxDecoration(),
                  onChanged: (_) => onTextChanged(),
                ),
              ),
              GestureDetector(
                onTap: onRemove,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    CupertinoIcons.xmark_circle_fill,
                    size: 20,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          CupertinoSlidingSegmentedControl<FindingSeverity>(
            groupValue: finding.severity,
            backgroundColor: CupertinoColors.tertiarySystemFill.resolveFrom(
              context,
            ),
            children: const {
              FindingSeverity.laag: Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('Laag', style: TextStyle(fontSize: 12)),
              ),
              FindingSeverity.aandacht: Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('Aandacht', style: TextStyle(fontSize: 12)),
              ),
              FindingSeverity.urgent: Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('Urgent', style: TextStyle(fontSize: 12)),
              ),
            },
            onValueChanged: (v) {
              if (v != null) onSeverityChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

class _AddFindingRow extends StatelessWidget {
  final VoidCallback onTap;
  const _AddFindingRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    const tint = Color(0xFF5856D6);
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
              child: Icon(CupertinoIcons.add, size: 18, color: tint),
            ),
            const SizedBox(width: 12),
            const Text(
              'Bevinding toevoegen',
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

// ─── Overview step ──────────────────────────────────────────────────────────

class _OverviewRowData {
  final String title;
  final bool complete;
  final String valueLabel;
  const _OverviewRowData(this.title, this.complete, this.valueLabel);
}

class _OverviewStep extends StatelessWidget {
  final List<_OverviewRowData> rows;
  final ValueChanged<int> onTapRow;

  const _OverviewStep({required this.rows, required this.onTapRow});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _OverviewRow(
              data: rows[i],
              stepNumber: i + 1,
              onTap: () => onTapRow(i),
            ),
          ),
      ],
    );
  }
}

class _OverviewRow extends StatelessWidget {
  final _OverviewRowData data;
  final int stepNumber;
  final VoidCallback onTap;

  const _OverviewRow({
    required this.data,
    required this.stepNumber,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: data.complete ? const Color(0xFF34C759) : borderColor,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: data.complete
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        size: 14,
                        color: CupertinoColors.white,
                      )
                    : Text(
                        '$stepNumber',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.valueLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: data.complete
                          ? CupertinoColors.secondaryLabel.resolveFrom(context)
                          : const Color(0xFFFF9500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ],
        ),
      ),
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
                decoration: BoxDecoration(
                  color: CupertinoColors.destructiveRed.resolveFrom(context),
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
    final tint = CupertinoColors.activeBlue.resolveFrom(context);
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
        child: Icon(CupertinoIcons.add, color: tint, size: 24),
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
              color: AppColors.navy
                  .resolveFrom(context)
                  .withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              CupertinoIcons.doc_text,
              size: 16,
              color: AppColors.navy.resolveFrom(context),
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
    final tint = CupertinoColors.activeBlue.resolveFrom(context);
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
              child: Icon(CupertinoIcons.add, size: 18, color: tint),
            ),
            const SizedBox(width: 12),
            Text(
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
