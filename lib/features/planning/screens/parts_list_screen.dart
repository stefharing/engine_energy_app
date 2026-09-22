import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import '../data/planning_repository.dart';
import '../models/job_order.dart';
import '../models/scanned_extra.dart';
import '../widgets/quantity_dialog.dart';
import 'magazijn_search_screen.dart';

class PartsListScreen extends StatefulWidget {
  final ServiceOrder order;

  const PartsListScreen({super.key, required this.order});

  @override
  State<PartsListScreen> createState() => _PartsListScreenState();
}

class _PartsListScreenState extends State<PartsListScreen> {
  List<Map<String, dynamic>> _parts = [];
  Map<String, int> _scannedCounts = {};
  List<ScannedExtra> _extras = [];
  Set<String> _flashIds = {};
  String? _toastMessage;
  bool _loading = true;
  String? _error;
  bool _showNavTitle = false;
  final _scrollCtrl = ScrollController();
  MobileScannerController? _scannerCtrl;
  bool _scannerActive = false;
  bool _scanCooldown = false;
  bool _confirming = false;

  String get _orderId => widget.order.id;

  static int _expectedQty(Map<String, dynamic> p) {
    final v = p['totalquantity'] ?? p['quantity'];
    if (v is int) return v > 0 ? v : 1;
    if (v is double) return v > 0 ? v.ceil() : 1;
    if (v is String) return int.tryParse(v) ?? 1;
    return 1;
  }

  static String _partCode(Map<String, dynamic> p) {
    final item = p['item'] as Map<String, dynamic>?;
    return (item?['code'] as String? ?? p['code'] as String? ?? '')
        .trim()
        .toUpperCase();
  }

  static String _partId(Map<String, dynamic> p) => p['id'].toString();

  bool _isComplete(Map<String, dynamic> p) =>
      (_scannedCounts[_partId(p)] ?? 0) >= _expectedQty(p);

  List<Map<String, dynamic>> get _sortedParts {
    final incomplete = _parts.where((p) => !_isComplete(p)).toList();
    final complete = _parts.where(_isComplete).toList();
    return [...incomplete, ...complete];
  }

  /// Extras whose code doesn't match a planned part — used purely to avoid
  /// showing the same article twice when [UsedMaterialsScreen] has seeded
  /// the shared extras list with an already-planned, already-picked part.
  List<ScannedExtra> get _extrasNotInParts {
    final partCodes = _parts.map(_partCode).toSet();
    return _extras.where((e) => !partCodes.contains(e.code.toUpperCase())).toList();
  }

  int get _totalExpected => _parts.fold(0, (s, p) => s + _expectedQty(p));

  int get _totalScannedQty => _parts.fold(0, (s, p) {
    final scanned = _scannedCounts[_partId(p)] ?? 0;
    return s + scanned.clamp(0, _expectedQty(p));
  });

  bool get _anyScanned => _totalScannedQty > 0 || _extras.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
    _scrollCtrl.addListener(() {
      final show = _scrollCtrl.offset > 53;
      if (show != _showNavTitle) setState(() => _showNavTitle = show);
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _scannerCtrl?.dispose();
    super.dispose();
  }

  Future<void> _load({bool showLoading = true}) async {
    setState(() {
      if (showLoading) _loading = true;
      _error = null;
    });
    try {
      final response = await ApiClient.instance.dio.get(
        '/production/joborderdetails',
        queryParameters: {
          'page': 1,
          'size': 200,
          'filter': 'joborder.id[eq]$_orderId',
        },
      );
      final all = (response.data['data'] as List).cast<Map<String, dynamic>>();
      final parts = all.where((e) => e['joborderdetailitem'] != null).toList();

      final prefs = await SharedPreferences.getInstance();

      final countsRaw = prefs.getString('scanned_counts_$_orderId') ?? '{}';
      final countsMap = (jsonDecode(countsRaw) as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, (v as num).toInt()),
      );

      final extrasRaw = prefs.getString('extra_scanned_$_orderId') ?? '[]';
      final loadedExtras = (jsonDecode(extrasRaw) as List)
          .cast<Map<String, dynamic>>()
          .map(ScannedExtra.fromJson)
          .toList();

      // A synced extra becomes a real joborderdetail line in Ridder, so on
      // the next load it comes back here as a normal (office-style) part.
      // Fold it into the picked-parts count instead of showing it twice.
      var extrasChanged = false;
      final extras = <ScannedExtra>[];
      for (final extra in loadedExtras) {
        Map<String, dynamic>? mergedPart;
        if (extra.ridderId != null) {
          for (final p in parts) {
            if (_partCode(p) == extra.code.toUpperCase()) {
              mergedPart = p;
              break;
            }
          }
        }
        if (mergedPart != null) {
          countsMap[_partId(mergedPart)] = extra.scannedCount;
          extrasChanged = true;
        } else {
          extras.add(extra);
        }
      }

      if (mounted) {
        setState(() {
          _parts = parts;
          _scannedCounts = countsMap;
          _extras = extras;
          _loading = false;
        });
      }
      if (extrasChanged) {
        await _saveCounts();
        await _saveExtras();
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString();
          _loading = false;
        });
    }
  }

  Future<void> _onRefresh() => _load(showLoading: false);

  void _startScanner() {
    setState(() {
      _scannerCtrl = MobileScannerController(
        facing: CameraFacing.back,
        torchEnabled: false,
      );
      _scannerActive = true;
      _scanCooldown = false;
    });
  }

  void _stopScanner() {
    _scannerCtrl?.dispose();
    setState(() {
      _scannerCtrl = null;
      _scannerActive = false;
      _scanCooldown = false;
    });
  }

  Future<void> _onScannerDetect(BarcodeCapture capture) async {
    if (_scanCooldown) return;
    final barcode = capture.barcodes.firstOrNull?.rawValue;
    if (barcode == null || barcode.isEmpty) return;
    setState(() => _scanCooldown = true);
    HapticFeedback.selectionClick();
    await _showQuantityDialog(barcode);
    if (mounted) setState(() => _scanCooldown = false);
  }

  Future<void> _showQuantityDialog(String rawBarcode) async {
    final code = rawBarcode.trim().toUpperCase();

    Map<String, dynamic>? match;
    for (final p in _parts) {
      if (_partCode(p) == code) {
        match = p;
        break;
      }
    }

    final int defaultQty;
    final String title;
    final String subtitle;
    if (match != null) {
      final id = _partId(match);
      final item = match['item'] as Map<String, dynamic>?;
      title = _partCode(match);
      subtitle =
          item?['description'] as String? ??
          match['description'] as String? ??
          '';
      final remaining = _expectedQty(match) - (_scannedCounts[id] ?? 0);
      defaultQty = remaining > 0 ? remaining : 1;
    } else {
      title = rawBarcode;
      subtitle = 'Onbekend artikel';
      defaultQty = 1;
    }

    final qty = await promptQuantity(
      context,
      title: title,
      subtitle: subtitle,
      defaultQty: defaultQty,
    );

    if (qty != null && qty > 0) {
      await _addPickedItem(code: rawBarcode, quantity: qty);
    }
  }

  /// Opens the magazine search screen so the mechanic can find an extra
  /// part by code/description instead of scanning it.
  Future<void> _addFromSearch() async {
    final selection = await Navigator.of(context).push<MagazijnSelection>(
      CupertinoPageRoute(builder: (_) => const MagazijnSearchScreen()),
    );
    if (selection == null) return;

    final qty =
        int.tryParse(selection.quantity) ??
        double.tryParse(selection.quantity)?.round() ??
        1;
    await _addPickedItem(
      code: selection.code,
      quantity: qty,
      catalogItem: selection.item,
    );
  }

  /// Lets the mechanic edit the picked quantity for a known part by hand.
  Future<void> _manualEntry(Map<String, dynamic> part) async {
    final id = _partId(part);
    final item = part['item'] as Map<String, dynamic>?;

    final qty = await promptQuantity(
      context,
      title: _partCode(part),
      subtitle:
          item?['description'] as String? ??
          part['description'] as String? ??
          '',
      defaultQty: _scannedCounts[id] ?? 0,
      minimumQty: 0,
    );

    if (qty == null) return;

    setState(() {
      if (qty == 0) {
        _scannedCounts.remove(id);
      } else {
        _scannedCounts[id] = qty;
      }
    });
    await _saveCounts();
  }

  /// Registers a picked quantity for [code]: against an expected part if it
  /// matches one, against an already-added extra if seen before, or as a
  /// brand-new extra otherwise — resolved against the item catalog (via
  /// [catalogItem] if already known, e.g. from search, or by looking it up)
  /// since extras need a real catalog `item.id` to become an order line later.
  Future<void> _addPickedItem({
    required String code,
    required int quantity,
    Map<String, dynamic>? catalogItem,
  }) async {
    final normalized = code.trim().toUpperCase();

    Map<String, dynamic>? match;
    for (final p in _parts) {
      if (_partCode(p) == normalized) {
        match = p;
        break;
      }
    }

    if (match != null) {
      final id = _partId(match);
      setState(() {
        _scannedCounts[id] = (_scannedCounts[id] ?? 0) + quantity;
        _flashIds.add(id);
      });
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _flashIds.remove(id));
      });
      await _saveCounts();
      return;
    }

    final idx = _extras.indexWhere((e) => e.code.toUpperCase() == normalized);
    if (idx >= 0) {
      setState(() {
        _extras[idx] = _extras[idx].copyWith(
          scannedCount: _extras[idx].scannedCount + quantity,
        );
      });
      await _saveExtras();
      _showToast('Aantal bijgewerkt');
      return;
    }

    final item = catalogItem ?? await _lookupCatalogItem(normalized);
    if (item == null) {
      _showToast('Artikel niet gevonden in het magazijn');
      return;
    }

    setState(
      () => _extras.add(ScannedExtra(item: item, scannedCount: quantity)),
    );
    await _saveExtras();
    _showToast('Artikel toegevoegd als extra');
  }

  Future<Map<String, dynamic>?> _lookupCatalogItem(String code) async {
    final matches = await PlanningRepository.instance.searchPartsByCode(code);
    for (final m in matches) {
      if ((m['code'] as String? ?? '').toUpperCase() == code) return m;
    }
    return null;
  }

  Future<void> _saveCounts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'scanned_counts_$_orderId',
      jsonEncode(_scannedCounts),
    );
  }

  Future<void> _saveExtras() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'extra_scanned_$_orderId',
      jsonEncode(_extras.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> _confirm() async {
    setState(() => _confirming = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final p in _parts) {
        await prefs.setBool('part_taken_${_orderId}_${p['id']}', true);
      }
      await prefs.setBool('parts_confirmed_$_orderId', true);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirming = false);
      showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Bevestigen mislukt'),
          content: Text(
            'De materialen konden niet lokaal worden opgeslagen.\n$e',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  void _showToast(String msg) {
    setState(() => _toastMessage = msg);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toastMessage = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final divider = isDark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6);

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.white,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4),
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.black,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: AnimatedOpacity(
          opacity: _showNavTitle ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: const Text(
            'Artikelen picken',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: CupertinoColors.black,
            ),
          ),
        ),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              // ── Inline camera ──────────────────────────────────────────────
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOut,
                height: _scannerActive ? 220 : 0,
                child: ClipRect(
                  child: _scannerCtrl != null
                      ? LayoutBuilder(
                          builder: (context, constraints) {
                            const double frameW = 220;
                            const double frameH = 130;
                            const double cameraH = 220;
                            final scanWindow = Rect.fromCenter(
                              center: Offset(
                                constraints.maxWidth / 2,
                                cameraH / 2,
                              ),
                              width: frameW,
                              height: frameH,
                            );
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                MobileScanner(
                                  controller: _scannerCtrl!,
                                  onDetect: _onScannerDetect,
                                  scanWindow: scanWindow,
                                ),
                                Center(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    width: frameW,
                                    height: frameH,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: _scanCooldown
                                            ? const Color(0xFF34C759)
                                            : const Color(0xFFFF9500),
                                        width: 2.5,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  bottom: 10,
                                  left: 0,
                                  right: 0,
                                  child: Text(
                                    _scanCooldown
                                        ? 'Gescand!'
                                        : 'Richt de camera op een barcode',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: CupertinoColors.white.withValues(
                                        alpha: 0.9,
                                      ),
                                      fontSize: 13,
                                      fontWeight: _scanCooldown
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      shadows: [
                                        Shadow(
                                          color: CupertinoColors.black
                                              .withValues(alpha: 0.6),
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Container(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    width: frameW,
                                    height: frameH,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              Expanded(
                child: CustomScrollView(
                  controller: _scrollCtrl,
                  slivers: [
                    CupertinoSliverRefreshControl(onRefresh: _onRefresh),
                    // ── Grote titel ──────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Artikelen picken',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            // Low-key pick count — just enough to track
                            // progress without competing with the title.
                            if (!_loading &&
                                _error == null &&
                                _parts.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                '$_totalScannedQty van $_totalExpected stuks gepickt',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: CupertinoColors.secondaryLabel
                                      .resolveFrom(context),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    // ── Content ──────────────────────────────────────────────
                    if (_loading)
                      const SliverFillRemaining(
                        child: Center(child: CupertinoActivityIndicator()),
                      )
                    else if (_error != null)
                      SliverFillRemaining(child: _buildError())
                    else if (_parts.isEmpty && _extras.isEmpty)
                      const SliverFillRemaining(
                        child: Center(
                          child: Text(
                            'Geen onderdelen gevonden',
                            style: TextStyle(color: CupertinoColors.systemGrey),
                          ),
                        ),
                      )
                    else ...[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            for (final p in _sortedParts)
                              _PartCard(
                                part: p,
                                scanned: _scannedCounts[_partId(p)] ?? 0,
                                expected: _expectedQty(p),
                                flashing: _flashIds.contains(_partId(p)),
                                isDark: isDark,
                                onTap: () => _manualEntry(p),
                              ),
                          ]),
                        ),
                      ),
                      if (_extrasNotInParts.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
                            child: Text(
                              'Extra artikelen',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                          sliver: SliverList(
                            delegate: SliverChildListDelegate([
                              for (final e in _extrasNotInParts)
                                _ExtraCard(extra: e, isDark: isDark),
                            ]),
                          ),
                        ),
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    ],
                  ],
                ),
              ),
              // ── Bottom buttons ────────────────────────────────────────────
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: CupertinoButton(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              color: _scannerActive
                                  ? const Color(0xFF636366)
                                  : const Color(0xFFE5E5EA),
                              borderRadius: BorderRadius.circular(14),
                              onPressed: _scannerActive
                                  ? _stopScanner
                                  : _startScanner,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _scannerActive
                                        ? CupertinoIcons.stop_circle
                                        : CupertinoIcons.barcode_viewfinder,
                                    size: 20,
                                    color: _scannerActive
                                        ? CupertinoColors.white
                                        : CupertinoColors.label.resolveFrom(
                                            context,
                                          ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _scannerActive ? 'Stop scannen' : 'Scannen',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _scannerActive
                                          ? CupertinoColors.white
                                          : CupertinoColors.label.resolveFrom(
                                              context,
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: CupertinoButton(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              // Neutral, not another saturated color — this
                              // is a secondary action next to "Scannen".
                              color: isDark
                                  ? const Color(0xFF2C2C2E)
                                  : const Color(0xFFE5E5EA),
                              borderRadius: BorderRadius.circular(14),
                              onPressed: _addFromSearch,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    CupertinoIcons.search,
                                    size: 20,
                                    color: CupertinoColors.label.resolveFrom(
                                      context,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Zoeken',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: CupertinoColors.label.resolveFrom(
                                        context,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_anyScanned) ...[
                        SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: CupertinoButton(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            color: const Color(0xFF34C759),
                            borderRadius: BorderRadius.circular(14),
                            onPressed: _confirming ? null : _confirm,
                            child: _confirming
                                ? const CupertinoActivityIndicator(
                                    color: CupertinoColors.white,
                                  )
                                : const Text(
                                    'Bevestigen en afsluiten',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: CupertinoColors.white,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          // ── Hairline ──────────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 0.5,
            child: Container(color: divider),
          ),
          // ── Toast ─────────────────────────────────────────────────────────
          if (_toastMessage != null)
            Positioned(
              bottom: _anyScanned ? 160 : 100,
              left: 40,
              right: 40,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF3A3A3C)
                      : const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _toastMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 44,
              color: CupertinoColors.systemRed,
            ),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            CupertinoButton(
              onPressed: _load,
              child: const Text('Opnieuw proberen'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Part card ────────────────────────────────────────────────────────────────

class _PartCard extends StatelessWidget {
  final Map<String, dynamic> part;
  final int scanned;
  final int expected;
  final bool flashing;
  final bool isDark;
  final VoidCallback onTap;

  const _PartCard({
    required this.part,
    required this.scanned,
    required this.expected,
    required this.flashing,
    required this.isDark,
    required this.onTap,
  });

  String _fmtQty(dynamic v) {
    if (v == null) return '—';
    if (v is double) {
      return v == v.truncateToDouble()
          ? v.toInt().toString()
          : v.toStringAsFixed(1);
    }
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final item = part['item'] as Map<String, dynamic>?;
    final code = item?['code'] as String? ?? part['code'] as String? ?? '—';
    final desc =
        item?['description'] as String? ??
        part['description'] as String? ??
        '—';
    final qty = _fmtQty(part['totalquantity'] ?? part['quantity']);
    final loc = part['warehouselocation'] as Map<String, dynamic>?;
    final locLabel = loc?['description'] as String?;
    final complete = scanned >= expected;
    final partial = scanned > 0 && !complete;

    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final flashBg = isDark ? const Color(0xFF1A2E1C) : const Color(0xFFEAF7EC);
    final borderColor = flashing
        ? const Color(0xFF34C759)
        : isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);

    final Color dotColor;
    if (complete || flashing) {
      dotColor = const Color(0xFF34C759);
    } else if (partial) {
      dotColor = const Color(0xFFFF9500);
    } else {
      dotColor = isDark ? const Color(0xFF5A5A5C) : const Color(0xFFD1D1D6);
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: flashing ? flashBg : cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: flashing ? 1.5 : 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Status indicator
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: dotColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: complete || flashing
                    ? Icon(CupertinoIcons.checkmark, size: 14, color: dotColor)
                    : partial
                    ? Text(
                        '$scanned',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: dotColor,
                        ),
                      )
                    : Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: dotColor,
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            // Article info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    code,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: complete
                          ? CupertinoColors.secondaryLabel.resolveFrom(context)
                          : CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 13,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (locLabel != null) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          CupertinoIcons.cube_box,
                          size: 11,
                          color: CupertinoColors.tertiaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          locLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: CupertinoColors.tertiaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Scan count
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$scanned/$qty',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: complete
                        ? const Color(0xFF34C759)
                        : partial
                        ? const Color(0xFFFF9500)
                        : CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
                ),
                Text(
                  'stuks',
                  style: TextStyle(
                    fontSize: 11,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Extra scanned card ───────────────────────────────────────────────────────

class _ExtraCard extends StatelessWidget {
  final ScannedExtra extra;
  final bool isDark;

  const _ExtraCard({required this.extra, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFF34C759).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              CupertinoIcons.checkmark,
              size: 14,
              color: Color(0xFF34C759),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  extra.code,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  extra.description,
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${extra.scannedCount}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF34C759),
                ),
              ),
              Text(
                'stuks',
                style: TextStyle(
                  fontSize: 11,
                  color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
