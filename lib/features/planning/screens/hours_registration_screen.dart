import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/planning_repository.dart';
import '../models/job_order.dart';

class HoursRegistrationScreen extends StatefulWidget {
  final ServiceOrder order;

  const HoursRegistrationScreen({super.key, required this.order});

  @override
  State<HoursRegistrationScreen> createState() =>
      _HoursRegistrationScreenState();
}

class _HoursRegistrationScreenState extends State<HoursRegistrationScreen> {
  late final List<DateTime> _days;
  late final Map<String, TextEditingController> _workCtrl;
  late final Map<String, TextEditingController> _travelCtrl;
  late final Map<String, TextEditingController> _kmCtrl;
  late final Map<String, TextEditingController> _memoCtrl;
  final Set<String> _memoVisible = {};
  bool _showNavTitle = false;
  bool _saving = false;
  int _workActivityId = workActivityIdWork;
  final _scrollCtrl = ScrollController();

  String get _draftKey => 'hours_draft_${widget.order.id}';

  static const _dayNames = ['', 'Ma', 'Di', 'Wo', 'Do', 'Vr', 'Za', 'Zo'];
  static const _months = [
    '',
    'jan',
    'feb',
    'mrt',
    'apr',
    'mei',
    'jun',
    'jul',
    'aug',
    'sep',
    'okt',
    'nov',
    'dec',
  ];

  @override
  void initState() {
    super.initState();
    _days = _buildDays();
    _workCtrl = {for (final d in _days) _key(d): TextEditingController()};
    _travelCtrl = {for (final d in _days) _key(d): TextEditingController()};
    _kmCtrl = {for (final d in _days) _key(d): TextEditingController()};
    _memoCtrl = {for (final d in _days) _key(d): TextEditingController()};
    _scrollCtrl.addListener(() {
      final show = _scrollCtrl.offset > 53;
      if (show != _showNavTitle) setState(() => _showNavTitle = show);
    });
    _loadDraft();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    for (final c in _workCtrl.values) c.dispose();
    for (final c in _travelCtrl.values) c.dispose();
    for (final c in _kmCtrl.values) c.dispose();
    for (final c in _memoCtrl.values) c.dispose();
    super.dispose();
  }

  /// Restores a previously locally-saved (not-yet-synced) draft, if any,
  /// so the mechanic can keep adjusting hours across app sessions before
  /// they're eventually sent to Ridder.
  Future<void> _loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftKey);
    if (raw == null) return;
    final draft = jsonDecode(raw) as Map<String, dynamic>;
    final days = (draft['days'] as Map<String, dynamic>?) ?? {};
    for (final entry in days.entries) {
      final d = entry.value as Map<String, dynamic>;
      _workCtrl[entry.key]?.text = d['work'] as String? ?? '';
      _travelCtrl[entry.key]?.text = d['travel'] as String? ?? '';
      _kmCtrl[entry.key]?.text = d['km'] as String? ?? '';
      final memo = d['memo'] as String? ?? '';
      _memoCtrl[entry.key]?.text = memo;
      if (memo.isNotEmpty) _memoVisible.add(entry.key);
    }
    if (mounted) {
      setState(() {
        _workActivityId = draft['workActivityId'] as int? ?? _workActivityId;
      });
    }
  }

  String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  List<DateTime> _buildDays() {
    final start = widget.order.startDate;
    if (start == null) return [];
    final end = widget.order.endTime ?? start;
    final last = DateTime(end.year, end.month, end.day);
    final days = <DateTime>[];
    var cur = DateTime(start.year, start.month, start.day);
    while (!cur.isAfter(last)) {
      if (cur.weekday <= 5) days.add(cur);
      cur = cur.add(const Duration(days: 1));
    }
    return days;
  }

  double _parseValue(String key, Map<String, TextEditingController> map) =>
      double.tryParse(map[key]?.text.replaceAll(',', '.') ?? '') ?? 0.0;

  double get _totalWork =>
      _days.fold(0.0, (s, d) => s + _parseValue(_key(d), _workCtrl));

  double get _totalTravel =>
      _days.fold(0.0, (s, d) => s + _parseValue(_key(d), _travelCtrl));

  double get _totalKm =>
      _days.fold(0.0, (s, d) => s + _parseValue(_key(d), _kmCtrl));

  String _fmtDate(DateTime d) =>
      '${_dayNames[d.weekday]}  ${d.day} ${_months[d.month]}';

  String _fmtDouble(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  /// Saves the entered hours/km/memo's locally only — nothing is sent to
  /// Ridder yet. This lets the mechanic keep reviewing and adjusting the
  /// week before it's eventually submitted.
  Future<void> _save() async {
    setState(() => _saving = true);
    final days = <String, dynamic>{
      for (final d in _days)
        _key(d): {
          'work': _workCtrl[_key(d)]!.text,
          'travel': _travelCtrl[_key(d)]!.text,
          'km': _kmCtrl[_key(d)]!.text,
          'memo': _memoCtrl[_key(d)]!.text,
        },
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _draftKey,
      jsonEncode({'workActivityId': _workActivityId, 'days': days}),
    );
    if (mounted) {
      setState(() => _saving = false);
      Navigator.of(context).pop();
    }
  }

  void _toggleMemo(String key) {
    setState(() {
      if (_memoVisible.contains(key)) {
        _memoVisible.remove(key);
        _memoCtrl[key]?.clear();
      } else {
        _memoVisible.add(key);
      }
    });
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  String get _selectedWorkActivityLabel =>
      workActivityOptions.firstWhere((o) => o.id == _workActivityId).label;

  Future<void> _pickWorkActivity() async {
    final selected = await showCupertinoModalPopup<int>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Uursoort'),
        actions: [
          for (final option in workActivityOptions)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(ctx).pop(option.id),
              isDefaultAction: option.id == _workActivityId,
              child: Text(option.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
    if (selected != null) setState(() => _workActivityId = selected);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final divider = isDark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6);
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final totalWork = _totalWork;
    final totalTravel = _totalTravel;
    final totalKm = _totalKm;

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.systemBackground,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4),
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.label,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: AnimatedOpacity(
          opacity: _showNavTitle ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: const Text(
            'Uren & KM',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      child: Stack(
        children: [
          _days.isEmpty
              ? SafeArea(child: _EmptyState())
              : CustomScrollView(
                  controller: _scrollCtrl,
                  slivers: [
                    // ── Grote titel ─────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                        child: const Text(
                          'Uren & KM',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),

                    // ── Uursoort ────────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: GestureDetector(
                          onTap: _pickWorkActivity,
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: cardBg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: borderColor),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  'Uursoort',
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: CupertinoColors.label.resolveFrom(
                                      context,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  _selectedWorkActivityLabel,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: CupertinoColors.activeBlue,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  CupertinoIcons.chevron_down,
                                  size: 14,
                                  color: CupertinoColors.activeBlue,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── Kolomkoppen ─────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
                        child: Row(
                          children: [
                            const Expanded(flex: 5, child: SizedBox()),
                            Expanded(
                              flex: 3,
                              child: _ColHeader(
                                'Werktijd',
                                icon: CupertinoIcons.hammer_fill,
                                color: const Color(0xFF34C759),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              flex: 3,
                              child: _ColHeader(
                                'Reistijd',
                                icon: CupertinoIcons.car_fill,
                                color: CupertinoColors.activeBlue,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              flex: 3,
                              child: _ColHeader(
                                'KM',
                                icon: CupertinoIcons.location_solid,
                                color: const Color(0xFFFF9500),
                              ),
                            ),
                            const SizedBox(width: 28),
                          ],
                        ),
                      ),
                    ),

                    // ── Dagen ───────────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: borderColor),
                          boxShadow: [
                            BoxShadow(
                              color: CupertinoColors.black.withValues(
                                alpha: isDark ? 0 : 0.03,
                              ),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Column(
                            children: [
                              for (int i = 0; i < _days.length; i++) ...[
                                if (i > 0)
                                  Container(height: 0.5, color: borderColor),
                                _DayRow(
                                  label: _fmtDate(_days[i]),
                                  isToday: _isToday(_days[i]),
                                  workCtrl: _workCtrl[_key(_days[i])]!,
                                  travelCtrl: _travelCtrl[_key(_days[i])]!,
                                  kmCtrl: _kmCtrl[_key(_days[i])]!,
                                  memoCtrl: _memoCtrl[_key(_days[i])]!,
                                  memoVisible: _memoVisible.contains(
                                    _key(_days[i]),
                                  ),
                                  borderColor: borderColor,
                                  onChanged: () => setState(() {}),
                                  onToggleMemo: () =>
                                      _toggleMemo(_key(_days[i])),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),

                    // ── Totaal ──────────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: borderColor),
                        ),
                        child: Row(
                          children: [
                            Text(
                              'Totaal',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: CupertinoColors.label.resolveFrom(
                                  context,
                                ),
                              ),
                            ),
                            const Spacer(),
                            _TotalChip(
                              label: '${_fmtDouble(totalWork)}u werk',
                              color: const Color(0xFF34C759),
                            ),
                            if (totalTravel > 0) ...[
                              const SizedBox(width: 8),
                              _TotalChip(
                                label: '${_fmtDouble(totalTravel)}u reis',
                                color: CupertinoColors.activeBlue,
                              ),
                            ],
                            if (totalKm > 0) ...[
                              const SizedBox(width: 8),
                              _TotalChip(
                                label: '${_fmtDouble(totalKm)} km',
                                color: const Color(0xFFFF9500),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    // ── Opslaan ─────────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 48),
                        child: CupertinoButton(
                          color: const Color(0xFF34C759),
                          borderRadius: BorderRadius.circular(14),
                          onPressed: totalWork > 0 && !_saving ? _save : null,
                          child: _saving
                              ? const CupertinoActivityIndicator(
                                  color: CupertinoColors.white,
                                )
                              : const Text(
                                  'Uren opslaan',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: CupertinoColors.white,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),

          // ── Hairline ────────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 0.5,
            child: Container(color: divider),
          ),
        ],
      ),
    );
  }
}

// ─── Column header ────────────────────────────────────────────────────────────

class _ColHeader extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;

  const _ColHeader(this.text, {required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      ],
    );
  }
}

// ─── Day row ──────────────────────────────────────────────────────────────────

class _DayRow extends StatelessWidget {
  final String label;
  final bool isToday;
  final TextEditingController workCtrl;
  final TextEditingController travelCtrl;
  final TextEditingController kmCtrl;
  final TextEditingController memoCtrl;
  final bool memoVisible;
  final Color borderColor;
  final VoidCallback onChanged;
  final VoidCallback onToggleMemo;

  const _DayRow({
    required this.label,
    required this.isToday,
    required this.workCtrl,
    required this.travelCtrl,
    required this.kmCtrl,
    required this.memoCtrl,
    required this.memoVisible,
    required this.borderColor,
    required this.onChanged,
    required this.onToggleMemo,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final inputBg = isDark ? const Color(0xFF2C2C2E) : CupertinoColors.white;
    final hasMemo = memoCtrl.text.isNotEmpty;
    final todayBg = isDark
        ? CupertinoColors.activeBlue.withValues(alpha: 0.08)
        : CupertinoColors.activeBlue.withValues(alpha: 0.05);

    return Container(
      color: isToday ? todayBg : null,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      if (isToday) ...[
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: CupertinoColors.activeBlue,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: isToday
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: isToday
                              ? CupertinoColors.activeBlue
                              : CupertinoColors.label.resolveFrom(context),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: _InputField(
                    controller: workCtrl,
                    bg: inputBg,
                    border: borderColor,
                    decimal: true,
                    onChanged: onChanged,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: _InputField(
                    controller: travelCtrl,
                    bg: inputBg,
                    border: borderColor,
                    decimal: true,
                    onChanged: onChanged,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: _InputField(
                    controller: kmCtrl,
                    bg: inputBg,
                    border: borderColor,
                    decimal: false,
                    onChanged: onChanged,
                  ),
                ),
                SizedBox(
                  width: 28,
                  child: CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 0),
                    onPressed: onToggleMemo,
                    child: Icon(
                      memoVisible || hasMemo
                          ? CupertinoIcons.text_bubble_fill
                          : CupertinoIcons.text_bubble,
                      size: 18,
                      color: memoVisible || hasMemo
                          ? CupertinoColors.activeBlue
                          : CupertinoColors.tertiaryLabel.resolveFrom(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (memoVisible)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: CupertinoTextField(
                controller: memoCtrl,
                placeholder: 'Notitie voor deze dag...',
                placeholderStyle: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                ),
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
                maxLines: 2,
                minLines: 1,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: inputBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor, width: 0.5),
                ),
                onChanged: (_) => onChanged(),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Input field ──────────────────────────────────────────────────────────────

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final Color bg;
  final Color border;
  final bool decimal;
  final VoidCallback onChanged;

  const _InputField({
    required this.controller,
    required this.bg,
    required this.border,
    required this.decimal,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: border, width: 0.5),
      ),
      child: CupertinoTextField(
        controller: controller,
        textAlign: TextAlign.center,
        keyboardType: decimal
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.number,
        inputFormatters: [
          decimal
              ? FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))
              : FilteringTextInputFormatter.digitsOnly,
        ],
        placeholder: '—',
        placeholderStyle: TextStyle(
          fontSize: 15,
          color: CupertinoColors.tertiaryLabel.resolveFrom(context),
        ),
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: CupertinoColors.label.resolveFrom(context),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: const BoxDecoration(),
        onChanged: (_) => onChanged(),
      ),
    );
  }
}

// ─── Total chip ───────────────────────────────────────────────────────────────

class _TotalChip extends StatelessWidget {
  final String label;
  final Color color;

  const _TotalChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          'Geen geplande dagen gevonden voor deze order.',
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
