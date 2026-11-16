import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Material, Theme, ThemeData, Colors;
import 'package:printing/printing.dart';

import '../../../core/theme/app_colors.dart';
import '../data/planning_repository.dart';

/// Lijst met de documenten van een serviceobject. Een tik downloadt het
/// document uit Ridder en toont het (pdf en afbeeldingen).
class ServiceObjectDocumentsScreen extends StatefulWidget {
  final String serviceObjectId;
  final String objectTitel;

  const ServiceObjectDocumentsScreen({
    super.key,
    required this.serviceObjectId,
    required this.objectTitel,
  });

  @override
  State<ServiceObjectDocumentsScreen> createState() =>
      _ServiceObjectDocumentsScreenState();
}

class _ServiceObjectDocumentsScreenState
    extends State<ServiceObjectDocumentsScreen> {
  static const _maanden = [
    '', 'jan', 'feb', 'mrt', 'apr', 'mei', 'jun',
    'jul', 'aug', 'sep', 'okt', 'nov', 'dec',
  ];

  List<Map<String, dynamic>>? _docs;
  bool _fout = false;
  bool _laden = true;
  String? _openId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool stil = false}) async {
    if (!stil) setState(() => _laden = true);
    try {
      final docs = await PlanningRepository.instance
          .fetchServiceObjectDocuments(widget.serviceObjectId);
      if (!mounted) return;
      setState(() {
        _docs = docs;
        _fout = false;
        _laden = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _fout = _docs == null;
        _laden = false;
      });
    }
  }

  String _ext(Map<String, dynamic> d) =>
      (d['extension']?.toString() ?? '').replaceFirst('.', '').toLowerCase();

  String _titel(Map<String, dynamic> d) {
    for (final k in ['description', 'name', 'recordtag']) {
      final t = d[k]?.toString().trim() ?? '';
      if (t.isNotEmpty) return t;
    }
    return 'Document';
  }

  String _datum(Map<String, dynamic> d) {
    final raw = d['datecreated']?.toString();
    final dt = raw == null ? null : DateTime.tryParse(raw);
    if (dt == null) return '';
    return '${dt.day} ${_maanden[dt.month]} ${dt.year}';
  }

  static bool _isAfbeelding(String ext) =>
      const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'}.contains(ext);

  (IconData, Color) _icoon(String ext) {
    if (ext == 'pdf') return (CupertinoIcons.doc_richtext, const Color(0xFFFF3B30));
    if (_isAfbeelding(ext)) return (CupertinoIcons.photo, const Color(0xFF007AFF));
    if (const {'xls', 'xlsx', 'csv'}.contains(ext)) {
      return (CupertinoIcons.table, const Color(0xFF248A3D));
    }
    if (const {'doc', 'docx', 'rtf', 'txt'}.contains(ext)) {
      return (CupertinoIcons.doc_text, const Color(0xFF007AFF));
    }
    return (CupertinoIcons.doc, const Color(0xFF8E8E93));
  }

  Future<void> _open(Map<String, dynamic> d) async {
    final id = d['id']?.toString();
    if (id == null || _openId != null) return;
    setState(() => _openId = id);
    try {
      final bytes = await PlanningRepository.instance.downloadDocument(id);
      if (!mounted) return;
      if (bytes.isEmpty) throw Exception('leeg bestand');
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => _DocumentViewerScreen(
            titel: _titel(d),
            extensie: _ext(d),
            bytes: bytes,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Openen mislukt'),
          content: const Text(
            'Het document kon niet worden opgehaald. Controleer je verbinding en probeer het opnieuw.',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _openId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final docs = _docs;
    return CupertinoPageScaffold(
      backgroundColor: AppColors.page.resolveFrom(context),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        previousPageTitle: 'Terug',
        middle: Text(
          'Documenten',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.navForeground.resolveFrom(context),
          ),
        ),
      ),
      child: SafeArea(
        child: _laden && docs == null
            ? const Center(child: CupertinoActivityIndicator())
            : _fout
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Documenten laden mislukt',
                      style: TextStyle(fontSize: 15, color: secundair),
                    ),
                    const SizedBox(height: 8),
                    CupertinoButton(
                      onPressed: _load,
                      child: const Text('Opnieuw proberen'),
                    ),
                  ],
                ),
              )
            : CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  CupertinoSliverRefreshControl(
                    onRefresh: () => _load(stil: true),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        widget.objectTitel,
                        style: TextStyle(fontSize: 13, color: secundair),
                      ),
                    ),
                  ),
                  if (docs == null || docs.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          'Geen documenten bij dit object',
                          style: TextStyle(fontSize: 15, color: secundair),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      sliver: SliverToBoxAdapter(
                        child: Container(
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: AppColors.card.resolveFrom(context),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: AppColors.border.resolveFrom(context),
                            ),
                          ),
                          child: Column(
                            children: [
                              for (var i = 0; i < docs.length; i++) ...[
                                if (i > 0)
                                  Container(
                                    height: 0.5,
                                    margin: const EdgeInsets.only(left: 70),
                                    color: AppColors.border.resolveFrom(context),
                                  ),
                                _rij(context, docs[i]),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _rij(BuildContext context, Map<String, dynamic> d) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final ext = _ext(d);
    final (icoon, kleur) = _icoon(ext);
    final datum = _datum(d);
    final bezig = _openId == d['id']?.toString();
    final meta = [
      if (ext.isNotEmpty) ext.toUpperCase(),
      if (datum.isNotEmpty) datum,
    ].join(' · ');
    return GestureDetector(
      onTap: () => _open(d),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: kleur.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icoon, size: 22, color: kleur),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _titel(d),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(meta, style: TextStyle(fontSize: 13, color: secundair)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (bezig)
              const CupertinoActivityIndicator(radius: 9)
            else
              Icon(
                CupertinoIcons.chevron_right,
                size: 14,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
          ],
        ),
      ),
    );
  }
}

/// Toont een gedownload document: pdf via `printing`, afbeeldingen met zoom.
class _DocumentViewerScreen extends StatelessWidget {
  final String titel;
  final String extensie;
  final Uint8List bytes;

  const _DocumentViewerScreen({
    required this.titel,
    required this.extensie,
    required this.bytes,
  });

  String get _bestandsnaam {
    final schoon = titel.replaceAll(RegExp(r'[^\w\- .]'), '_');
    return extensie.isEmpty ? schoon : '$schoon.$extensie';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final isPdf = extensie == 'pdf';
    final isAfb = _ServiceObjectDocumentsScreenState._isAfbeelding(extensie);

    Widget inhoud;
    if (isPdf) {
      // PdfPreview is een Material-widget; de app is Cupertino.
      inhoud = Theme(
        data: ThemeData(
          brightness: isDark ? Brightness.dark : Brightness.light,
          colorSchemeSeed: const Color(0xFFFF6B2B),
        ),
        child: Material(
          color: Colors.transparent,
          child: PdfPreview(
            build: (_) async => bytes,
            pdfFileName: _bestandsnaam,
            canChangePageFormat: false,
            canChangeOrientation: false,
            canDebug: false,
            allowPrinting: true,
            allowSharing: true,
          ),
        ),
      );
    } else if (isAfb) {
      inhoud = InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
      );
    } else {
      inhoud = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Dit bestandstype (${extensie.isEmpty ? 'onbekend' : extensie}) kan nog niet in de app worden geopend.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ),
      );
    }

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        previousPageTitle: 'Documenten',
        middle: Text(
          titel,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.navForeground.resolveFrom(context),
          ),
        ),
      ),
      child: SafeArea(child: inhoud),
    );
  }
}
