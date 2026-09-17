import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/planning_repository.dart';
import '../models/job_order.dart';
import '../models/scanned_extra.dart';
import 'magazijn_search_screen.dart';

/// Registers materials used on a bon that weren't on the office-planned
/// parts list — opened from the "Extra materiaal" task on [BonDetailScreen].
/// Adding goes through [MagazijnSearchScreen] (see [ScannedExtra]), which
/// already covers search, barcode scanning and asking for a quantity in one
/// flow. Persists to the same `extra_scanned_<orderId>` draft [PartsListScreen]
/// uses, so both screens agree on what's been added — but this screen has no
/// office-planned parts of its own to pick against, so every added article
/// is an extra.
class ExtraMaterialsScreen extends StatefulWidget {
  final ServiceOrder order;

  const ExtraMaterialsScreen({super.key, required this.order});

  @override
  State<ExtraMaterialsScreen> createState() => _ExtraMaterialsScreenState();
}

class _ExtraMaterialsScreenState extends State<ExtraMaterialsScreen> {
  List<ScannedExtra> _extras = [];
  bool _loading = true;
  String? _error;
  bool _showNavTitle = false;
  final _scrollCtrl = ScrollController();

  String? _toastMessage;

  String get _orderId => widget.order.id;

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
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('extra_scanned_$_orderId') ?? '[]';
      final extras = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(ScannedExtra.fromJson)
          .toList();
      if (mounted) {
        setState(() {
          _extras = extras;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _saveExtras() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'extra_scanned_$_orderId',
      jsonEncode(_extras.map((e) => e.toJson()).toList()),
    );
  }

  /// Lets the mechanic choose how to add a material: pick a real catalog
  /// item ("Uit magazijn" — search or scan) or type in a free-text name and
  /// quantity ("Artikel aanmaken") for something not in the catalog.
  Future<void> _chooseAddMethod() async {
    final choice = await showCupertinoModalPopup<_AddMethod>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Materiaal toevoegen'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop(_AddMethod.warehouse),
            child: const Text('Uit magazijn'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop(_AddMethod.manual),
            child: const Text('Artikel aanmaken'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _AddMethod.warehouse:
        await _addFromSearch();
      case _AddMethod.manual:
        await _addManualArticle();
    }
  }

  /// Opens the magazine search screen so the mechanic can find a material by
  /// code/description, or scan its barcode — that screen handles both.
  Future<void> _addFromSearch() async {
    final selection = await Navigator.of(context).push<MagazijnSelection>(
      CupertinoPageRoute(builder: (_) => const MagazijnSearchScreen()),
    );
    if (selection == null) return;

    final qty =
        int.tryParse(selection.quantity) ??
        double.tryParse(selection.quantity)?.round() ??
        1;
    await _addExtra(
      code: selection.code,
      quantity: qty,
      catalogItem: selection.item,
    );
  }

  /// Registers a scanned/searched quantity for [code]: against an
  /// already-added extra if seen before, or as a brand-new extra otherwise —
  /// resolved against the item catalog (via [catalogItem] if already known,
  /// e.g. from search, or by looking it up) since extras need a real catalog
  /// `item.id` to become an order line later.
  Future<void> _addExtra({
    required String code,
    required int quantity,
    Map<String, dynamic>? catalogItem,
  }) async {
    final normalized = code.trim().toUpperCase();

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
    _showToast('Materiaal toegevoegd');
  }

  /// Adds a free-text article with no catalog match. It is stored as a local
  /// draft and becomes a Service Remote `detailMisc` line on publication.
  Future<void> _addManualArticle() async {
    final input = await showCupertinoDialog<_ManualArticleInput>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ManualArticleDialog(),
    );
    if (input == null) return;

    final normalized = input.name.trim().toUpperCase();
    final idx = _extras.indexWhere((e) => e.code.toUpperCase() == normalized);
    if (idx >= 0) {
      setState(() {
        _extras[idx] = _extras[idx].copyWith(
          scannedCount: _extras[idx].scannedCount + input.quantity,
        );
      });
      await _saveExtras();
      _showToast('Aantal bijgewerkt');
      return;
    }

    setState(
      () => _extras.add(
        ScannedExtra(
          item: {
            'id': null,
            'code': normalized,
            'description': input.name.trim(),
          },
          scannedCount: input.quantity,
        ),
      ),
    );
    await _saveExtras();
    _showToast('Materiaal toegevoegd');
  }

  Future<Map<String, dynamic>?> _lookupCatalogItem(String code) async {
    final matches = await PlanningRepository.instance.searchPartsByCode(code);
    for (final m in matches) {
      if ((m['code'] as String? ?? '').toUpperCase() == code) return m;
    }
    return null;
  }

  Future<void> _register() async {
    // Extras are already stored locally on every edit. They are included in
    // the Service Remote job-order payload only from "Werk afronden".
    if (mounted) Navigator.of(context).pop();
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
    final empty = !_loading && _error == null && _extras.isEmpty;

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
            'Extra materialen',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: CupertinoColors.black,
            ),
          ),
        ),
      ),
      child: Column(
        children: [
          // ── Hairline ──────────────────────────────────────────────────────
          Container(height: 0.5, color: divider),
          Expanded(
            child: Stack(
              children: [
                CustomScrollView(
                  controller: _scrollCtrl,
                  slivers: [
                    // ── Grote titel ──────────────────────────────────────────
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(16, 20, 16, 0),
                        child: Text(
                          'Extra materialen',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
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
                    else if (empty)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        sliver: SliverToBoxAdapter(
                          child: _EmptyExtrasHint(onTap: _chooseAddMethod),
                        ),
                      )
                    else ...[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            for (final e in _extras)
                              _ExtraMaterialCard(extra: e, isDark: isDark),
                          ]),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    ],
                  ],
                ),
                // ── Snelle "+" actie om materiaal toe te voegen ────────────
                // Scoped to this Stack (not the whole screen) so it always
                // sits a fixed distance above the content area regardless
                // of the footer's own height — no more overlap between them.
                if (!_loading && _error == null)
                  Positioned(
                    right: 20,
                    bottom: 16,
                    child: GestureDetector(
                      onTap: _chooseAddMethod,
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF6B2B),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Color(0x33000000),
                              blurRadius: 10,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(
                          CupertinoIcons.plus,
                          color: CupertinoColors.white,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                // ── Toast ───────────────────────────────────────────────────
                // Sits above the "+" button rather than under it.
                if (_toastMessage != null)
                  Positioned(
                    bottom: 84,
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
          ),
          _RegisterFooter(
            isDark: isDark,
            canRegister: _extras.isNotEmpty,
            onPressed: _register,
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

// ─── Add-method choice ────────────────────────────────────────────────────────

enum _AddMethod { warehouse, manual }

/// Result of [_ManualArticleDialog] — a free-text article name and quantity.
class _ManualArticleInput {
  final String name;
  final int quantity;
  const _ManualArticleInput({required this.name, required this.quantity});
}

/// Asks for a name and a quantity — used by "Artikel aanmaken" for a
/// material that isn't in the catalog.
class _ManualArticleDialog extends StatefulWidget {
  const _ManualArticleDialog();

  @override
  State<_ManualArticleDialog> createState() => _ManualArticleDialogState();
}

class _ManualArticleDialogState extends State<_ManualArticleDialog> {
  final _nameCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _nameCtrl.text.trim();
    final qty = int.tryParse(_qtyCtrl.text.trim());
    if (name.isEmpty || qty == null || qty <= 0) return;
    Navigator.of(context).pop(_ManualArticleInput(name: name, quantity: qty));
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('Artikel aanmaken'),
      content: Column(
        children: [
          const SizedBox(height: 14),
          CupertinoTextField(
            controller: _nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            placeholder: 'Naam',
            decoration: BoxDecoration(
              color: CupertinoColors.tertiarySystemBackground,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(height: 10),
          CupertinoTextField(
            controller: _qtyCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            placeholder: 'Aantal',
            decoration: BoxDecoration(
              color: CupertinoColors.tertiarySystemBackground,
              borderRadius: BorderRadius.circular(8),
            ),
            onSubmitted: (_) => _confirm(),
          ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: _confirm,
          child: const Text('Toevoegen'),
        ),
      ],
    );
  }
}

// ─── Register footer ─────────────────────────────────────────────────────────

/// Full-width local-save button, styled after
/// [HoursWeekScreen]'s `_SubmitFooter` — grey/disabled until there's at
/// least one material to register, then accent green.
class _RegisterFooter extends StatelessWidget {
  final bool isDark;
  final bool canRegister;
  final VoidCallback onPressed;

  const _RegisterFooter({
    required this.isDark,
    required this.canRegister,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 16 + bottomInset),
      decoration: BoxDecoration(
        color: cardBg,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CupertinoButton(
            color: const Color(0xFF34C759),
            borderRadius: BorderRadius.circular(14),
            onPressed: canRegister ? onPressed : null,
            child: const Text(
              'Opslaan voor publicatie',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: CupertinoColors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty state ────────────────────────────────────────────────────────────

/// Tappable orange hint card shown while no extra materials have been
/// registered yet — mirrors [HoursWeekScreen]'s `_EmptyCardsHint`.
class _EmptyExtrasHint extends StatelessWidget {
  final VoidCallback onTap;

  const _EmptyExtrasHint({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    const tint = Color(0xFFFF6B2B);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: isDark ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: const Icon(CupertinoIcons.add, size: 22, color: tint),
            ),
            const SizedBox(height: 12),
            Text(
              'Geen extra materialen geregistreerd',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'Tik om extra materialen toe te voegen',
              style: TextStyle(fontSize: 12, color: tint),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Extra material card ─────────────────────────────────────────────────────

class _ExtraMaterialCard extends StatelessWidget {
  final ScannedExtra extra;
  final bool isDark;

  const _ExtraMaterialCard({required this.extra, required this.isDark});

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
                  extra.isManual ? extra.description : extra.code,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (extra.isManual)
                  Text(
                    'Niet gekoppeld aan magazijn',
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                    ),
                  )
                else
                  Text(
                    extra.description,
                    style: TextStyle(
                      fontSize: 13,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
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
