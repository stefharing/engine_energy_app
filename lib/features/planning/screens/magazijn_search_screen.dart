import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/planning_repository.dart';

/// Result returned when a user selects an article from the magazine.
class MagazijnSelection {
  final String code;
  final String description;
  final String quantity;

  /// The raw `/itemmanagement/items` catalog record, needed by callers that
  /// must reference this item's real `id` (e.g. to create an order line).
  final Map<String, dynamic> item;

  const MagazijnSelection({
    required this.code,
    required this.description,
    required this.quantity,
    required this.item,
  });
}

class MagazijnSearchScreen extends StatefulWidget {
  const MagazijnSearchScreen({super.key});

  @override
  State<MagazijnSearchScreen> createState() => _MagazijnSearchScreenState();
}

class _MagazijnSearchScreenState extends State<MagazijnSearchScreen> {
  final _searchCtrl = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  List<Map<String, dynamic>> _results = [];
  bool _loading = false;
  bool _searched = false;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusNode.requestFocus(),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final q = _searchCtrl.text.trim();
    if (q == _lastQuery) return;
    _debounce?.cancel();
    if (q.length < 2) {
      setState(() {
        _results = [];
        _searched = false;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _search(q, byCode: false),
    );
  }

  Future<void> _search(String q, {required bool byCode}) async {
    setState(() {
      _loading = true;
      _lastQuery = q;
    });

    // Always search both code and description in parallel, merge deduplicated.
    // Code results come first (more specific match).
    final futures = await Future.wait([
      PlanningRepository.instance.searchPartsByCode(q),
      PlanningRepository.instance.searchParts(q),
    ]);

    final seen = <String>{};
    final merged = <Map<String, dynamic>>[];
    for (final list in futures) {
      for (final item in list) {
        final code = item['code'] as String? ?? item['id'].toString();
        if (seen.add(code)) merged.add(item);
      }
    }

    if (!mounted) return;
    setState(() {
      _results = merged;
      _loading = false;
      _searched = true;
    });
  }

  Future<void> _openBarcodeScanner() async {
    _focusNode.unfocus();
    final code = await Navigator.of(context).push<String>(
      CupertinoPageRoute(builder: (_) => const BarcodeScannerScreen()),
    );
    if (code == null || !mounted) return;

    _searchCtrl.text = code;
    _search(code, byCode: true);
  }

  Future<void> _selectArticle(Map<String, dynamic> part) async {
    final code = part['code'] as String? ?? '';
    final desc = (part['description'] as String?)?.isNotEmpty == true
        ? part['description'] as String
        : part['recordtag'] as String? ?? '';

    final qty = await _askQuantity(desc);
    if (qty == null || !mounted) return;

    Navigator.of(context).pop(
      MagazijnSelection(
        code: code,
        description: desc,
        quantity: qty,
        item: part,
      ),
    );
  }

  Future<String?> _askQuantity(String articleName) async {
    final ctrl = TextEditingController(text: '1');
    String? result;

    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Aantal'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            children: [
              Text(articleName, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                placeholder: 'Aantal',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuleren'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              result = ctrl.text.trim();
              Navigator.of(ctx).pop();
            },
            child: const Text('Toevoegen'),
          ),
        ],
      ),
    );

    ctrl.dispose();
    final qty = result?.trim() ?? '';
    return qty.isEmpty ? null : qty;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9);
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final fieldBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.white,
        border: null,
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.black,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: const Text(
          'Uit magazijn',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: CupertinoColors.black,
          ),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── Search bar ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: fieldBg,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: CupertinoTextField(
                          controller: _searchCtrl,
                          focusNode: _focusNode,
                          placeholder: 'Artikelcode of omschrijving...',
                          prefix: const Padding(
                            padding: EdgeInsets.only(left: 10),
                            child: Icon(
                              CupertinoIcons.search,
                              size: 18,
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 11,
                          ),
                          decoration: const BoxDecoration(),
                          clearButtonMode: OverlayVisibilityMode.editing,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: _openBarcodeScanner,
                      child: Container(
                        // Matches the text field's own (intrinsic) height
                        // instead of a hardcoded value, so they always
                        // line up regardless of font/padding tweaks.
                        width: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF6B2B),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          CupertinoIcons.barcode_viewfinder,
                          color: CupertinoColors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Results ───────────────────────────────────────────────────
            Expanded(child: _buildBody(isDark, cardBg, borderColor)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color cardBg, Color borderColor) {
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator());
    }

    if (!_searched) {
      return _Hint(
        icon: CupertinoIcons.barcode_viewfinder,
        text: 'Typ een artikelcode of omschrijving,\nof scan een barcode.',
      );
    }

    if (_results.isEmpty) {
      return _Hint(
        icon: CupertinoIcons.search,
        text: 'Geen artikelen gevonden voor\n"${_searchCtrl.text.trim()}"',
      );
    }

    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      itemCount: _results.length,
      itemBuilder: (ctx, i) => _ArticleCard(
        part: _results[i],
        cardBg: cardBg,
        borderColor: borderColor,
        onSelect: () => _selectArticle(_results[i]),
      ),
    );
  }
}

// ─── Article card ─────────────────────────────────────────────────────────────

class _ArticleCard extends StatelessWidget {
  final Map<String, dynamic> part;
  final Color cardBg;
  final Color borderColor;
  final VoidCallback onSelect;

  const _ArticleCard({
    required this.part,
    required this.cardBg,
    required this.borderColor,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final code = part['code'] as String? ?? '';
    final desc = (part['description'] as String?)?.isNotEmpty == true
        ? part['description'] as String
        : part['recordtag'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (code.isNotEmpty)
                    Text(
                      code,
                      style: TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  if (code.isNotEmpty) const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                ],
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.all(10),
              onPressed: onSelect,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6B2B).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  CupertinoIcons.plus,
                  size: 18,
                  color: Color(0xFFFF6B2B),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Hint widget ──────────────────────────────────────────────────────────────

class _Hint extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Hint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: CupertinoColors.systemGrey3),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Barcode scanner screen ───────────────────────────────────────────────────

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen();

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final _controller = MobileScannerController(
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  bool _detected = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_detected) return;
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null || code.isEmpty) return;
    _detected = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoTheme(
      data: const CupertinoThemeData(brightness: Brightness.dark),
      child: CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          backgroundColor: CupertinoColors.black,
          border: null,
          leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Annuleren',
              style: TextStyle(color: CupertinoColors.white),
            ),
          ),
          middle: const Text(
            'Barcode scannen',
            style: TextStyle(color: CupertinoColors.white),
          ),
        ),
        child: Stack(
          children: [
            MobileScanner(controller: _controller, onDetect: _onDetect),
            // Scan frame overlay
            Center(
              child: Container(
                width: 260,
                height: 160,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: const Color(0xFFFF6B2B),
                    width: 2.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            // Instruction text
            Positioned(
              bottom: 60,
              left: 0,
              right: 0,
              child: Text(
                'Richt de camera op de barcode van het artikel',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: CupertinoColors.white.withValues(alpha: 0.9),
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
