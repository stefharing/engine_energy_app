import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/planning_repository.dart';
import '../models/job_order.dart';

class PartsSearchScreen extends StatefulWidget {
  final ServiceOrder order;

  const PartsSearchScreen({super.key, required this.order});

  @override
  State<PartsSearchScreen> createState() => _PartsSearchScreenState();
}

class _PartsSearchScreenState extends State<PartsSearchScreen> {
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
    // Auto-focus search field on open
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
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
      setState(() { _results = []; _searched = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q));
  }

  Future<void> _search(String q) async {
    setState(() { _loading = true; _lastQuery = q; });
    final results = await PlanningRepository.instance.searchParts(q);
    if (!mounted) return;
    setState(() { _results = results; _loading = false; _searched = true; });
  }

  void _addPart(Map<String, dynamic> part) {
    // TODO: register part on order via API
    Navigator.of(context).pop(part);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
    final cardBg = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.systemBackground,
        border: null,
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.label.resolveFrom(context),
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: const Text(
          'Onderdelen',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── Search bar ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: CupertinoSearchTextField(
                controller: _searchCtrl,
                focusNode: _focusNode,
                placeholder: 'Zoek op artikelnaam of code...',
                onChanged: (_) {},
              ),
            ),

            // ── Results ───────────────────────────────────────────────────
            Expanded(
              child: _buildBody(isDark, borderColor, cardBg),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color borderColor, Color cardBg) {
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator());
    }

    if (!_searched && _searchCtrl.text.length < 2) {
      return _Hint(text: 'Typ minimaal 2 tekens om te zoeken.');
    }

    if (_searched && _results.isEmpty) {
      return _Hint(text: 'Geen resultaten voor "${_searchCtrl.text.trim()}".');
    }

    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      itemCount: _results.length,
      itemBuilder: (ctx, i) {
        final part = _results[i];
        return _PartCard(
          part: part,
          borderColor: borderColor,
          cardBg: cardBg,
          isLast: i == _results.length - 1,
          onAdd: () => _addPart(part),
        );
      },
    );
  }
}

// ─── Part card ─────────────────────────────────────────────────────────────────

class _PartCard extends StatelessWidget {
  final Map<String, dynamic> part;
  final Color borderColor;
  final Color cardBg;
  final bool isLast;
  final VoidCallback onAdd;

  const _PartCard({
    required this.part,
    required this.borderColor,
    required this.cardBg,
    required this.isLast,
    required this.onAdd,
  });

  String _str(String key) => part[key]?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    final code = _str('code');
    final description = _str('description').isNotEmpty
        ? _str('description')
        : _str('recordtag');
    final unit = _str('salesunit').isNotEmpty
        ? _str('salesunit')
        : _str('unit');
    final price = part['salesprice'] ?? part['price'];
    final priceText = price != null
        ? '€ ${(price as num).toStringAsFixed(2)}'
        : '';

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
                        fontWeight: FontWeight.w500,
                        color: CupertinoColors.secondaryLabel.resolveFrom(context),
                      ),
                    ),
                  if (code.isNotEmpty) const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  if (priceText.isNotEmpty || unit.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (priceText.isNotEmpty)
                          Text(
                            priceText,
                            style: TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.secondaryLabel.resolveFrom(context),
                            ),
                          ),
                        if (priceText.isNotEmpty && unit.isNotEmpty)
                          Text(
                            ' · ',
                            style: TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                            ),
                          ),
                        if (unit.isNotEmpty)
                          Text(
                            'per $unit',
                            style: TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.secondaryLabel.resolveFrom(context),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.all(10),
              onPressed: onAdd,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: CupertinoColors.activeBlue.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  CupertinoIcons.plus,
                  size: 18,
                  color: CupertinoColors.activeBlue,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Hint ──────────────────────────────────────────────────────────────────────

class _Hint extends StatelessWidget {
  final String text;
  const _Hint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      ),
    );
  }
}
