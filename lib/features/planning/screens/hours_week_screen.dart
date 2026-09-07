import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/auth_service.dart';
import '../../../core/auth/current_user.dart';
import '../data/planning_repository.dart';
import '../data/service_remote_job_order_repository.dart';
import '../models/hours_entry.dart';
import '../models/job_order.dart';

// The dashboard's accent orange, reused here so this screen's interactive
// accents (selected states, buttons, links) match the rest of the app
// instead of Cupertino's default blue.
const _accentOrange = Color(0xFFFF6B2B);

const _fullDayNames = [
  '',
  'Maandag',
  'Dinsdag',
  'Woensdag',
  'Donderdag',
  'Vrijdag',
  'Zaterdag',
  'Zondag',
];

/// A selectable "hour type" in the add-entry sheet — the existing Uursoort
/// options (Service NL, Service Abroad, Overwerk, ...) plus Reistijd
/// (travel), which used to be its own separate input field. Merging it in
/// here matches how the API actually models hours: one `workActivityId` per
/// line, no structural distinction between "work" and "travel" beyond that.
class _HourType {
  const _HourType(this.id, this.label, this.icon, this.color);
  final int id;
  final String label;
  final IconData icon;
  final Color color;
}

final List<_HourType> _hourTypes = [
  for (final o in workActivityOptions)
    _HourType(
      o.id,
      o.label,
      CupertinoIcons.hammer_fill,
      const Color(0xFF34C759),
    ),
  const _HourType(
    workActivityIdTravel,
    'Reistijd',
    CupertinoIcons.car_fill,
    _accentOrange,
  ),
];

_HourType _hourTypeById(int id) =>
    _hourTypes.firstWhere((t) => t.id == id, orElse: () => _hourTypes.first);

String _formatMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}u' : '${h}u ${m}m';
}

double _parseDecimal(String text) =>
    double.tryParse(text.replaceAll(',', '.')) ?? 0.0;

/// A single locally-added hours entry for one day: an amount of time, tagged
/// with an [_HourType], plus an optional short description. This is what
/// the "+" button in [HoursWeekScreen] creates.
class _HourCard {
  const _HourCard({
    required this.id,
    required this.workActivityId,
    required this.minutes,
    this.memo,
    this.submitted = false,
  });

  final String id;
  final int workActivityId;
  final int minutes;
  final String? memo;

  /// Whether this card has already been sent to Ridder. Submitted cards
  /// stay visible (as a local record of what was sent) but are locked:
  /// greyed out, not swipe-to-delete, and excluded from the next submit.
  final bool submitted;

  _HourCard copyWith({bool? submitted}) => _HourCard(
    id: id,
    workActivityId: workActivityId,
    minutes: minutes,
    memo: memo,
    submitted: submitted ?? this.submitted,
  );

  Map<String, dynamic> toDraftJson() => {
    'id': id,
    'workActivityId': workActivityId,
    'minutes': minutes,
    'memo': memo,
    'submitted': submitted,
  };

  factory _HourCard.fromDraftJson(Map<String, dynamic> json) => _HourCard(
    id: json['id'] as String,
    workActivityId: json['workActivityId'] as int,
    minutes: json['minutes'] as int,
    memo: json['memo'] as String?,
    submitted: json['submitted'] as bool? ?? false,
  );
}

/// Paginated day view for entering a technician's hours against a bon —
/// one day per page, swipeable, across a fixed 29-day window (2 weeks back
/// through 2 weeks forward from today) with the selected bon's planned days
/// highlighted. The bon to book hours onto is chosen via [_ProjectSelectorBar]
/// — either pre-filled with [initialOrder] (opened from a bon's detail
/// screen) or left empty for the technician to pick (opened from the
/// dashboard). Hours are entered as individual cards (amount + type +
/// description) via the "+" button, rather than fixed work/travel fields.
/// Submission writes to Ridder via
/// [ServiceRemoteJobOrderRepository.submitHoursForJobOrder].
class HoursWeekScreen extends StatefulWidget {
  final ServiceOrder? initialOrder;

  const HoursWeekScreen({super.key, this.initialOrder});

  @override
  State<HoursWeekScreen> createState() => _HoursWeekScreenState();
}

class _HoursWeekScreenState extends State<HoursWeekScreen> {
  late final List<DateTime> _days;
  late final Map<String, List<_HourCard>> _cardsByDay;
  late final PageController _pageController;
  late final List<GlobalKey> _dayChipKeys;
  int _currentPage = 0;
  ServiceOrder? _selectedOrder;

  bool _submitting = false;
  String? _submitError;
  Timer? _draftSaveTimer;
  final _uuid = const Uuid();

  String? _draftKeyFor(ServiceOrder? order) =>
      order == null ? null : 'hours_week_draft_${order.id}';

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
    _selectedOrder = widget.initialOrder;
    _days = _buildDayRange();
    _dayChipKeys = List.generate(_days.length, (_) => GlobalKey());
    _cardsByDay = {for (final d in _days) _key(d): <_HourCard>[]};
    final initialPage = _initialPageIndex();
    _currentPage = initialPage;
    _pageController = PageController(initialPage: initialPage);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollDayStripToCurrent(),
    );
    _loadDraft();
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  List<DateTime> _buildDayRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(const Duration(days: 14));
    return List.generate(29, (i) => start.add(Duration(days: i)));
  }

  int _initialPageIndex() {
    final today = DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    final todayIndex = _days.indexWhere((d) => d == todayOnly);
    return todayIndex >= 0 ? todayIndex : 0;
  }

  void _scrollDayStripToCurrent({bool animate = false}) {
    final ctx = _dayChipKeys[_currentPage].currentContext;
    if (ctx == null) return;
    if (animate) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      Scrollable.ensureVisible(ctx, alignment: 0.5);
    }
  }

  bool _isPlanned(DateTime day) {
    final start = _selectedOrder?.startDate;
    if (start == null) return false;
    final end = _selectedOrder?.endTime ?? start;
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    return !day.isBefore(s) && !day.isAfter(e);
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  int _totalMinutesForDay(String key) =>
      (_cardsByDay[key] ?? const []).fold(0, (s, c) => s + c.minutes);

  double get _totalHours =>
      _days.fold(0, (s, d) => s + _totalMinutesForDay(_key(d))) / 60;

  bool get _hasPendingCards =>
      _cardsByDay.values.any((l) => l.any((c) => !c.submitted));

  /// Total of only the cards already sent to Ridder — used when leaving the
  /// screen, so [BonDetailScreen] doesn't get credited for still-local
  /// drafts that were never actually submitted.
  double get _submittedTotalHours =>
      _cardsByDay.values
          .expand((l) => l)
          .where((c) => c.submitted)
          .fold(0, (s, c) => s + c.minutes) /
      60;

  String _fmtDate(DateTime d) =>
      '${_fullDayNames[d.weekday]} ${d.day} ${_months[d.month]}';
  String _fmtDouble(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  /// Restores a previously locally-saved (not-yet-submitted) draft for the
  /// currently selected bon, if any — the phone remembers cards created in
  /// a previous session until they're actually submitted. Each bon keeps
  /// its own draft, so switching the selected bon swaps the visible cards.
  Future<void> _loadDraft() async {
    for (final d in _days) {
      _cardsByDay[_key(d)] = [];
    }
    final key = _draftKeyFor(_selectedOrder);
    if (key == null) {
      if (mounted) setState(() {});
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) {
      if (mounted) setState(() {});
      return;
    }
    final draft = jsonDecode(raw) as Map<String, dynamic>;
    final days = (draft['days'] as Map<String, dynamic>?) ?? {};
    for (final entry in days.entries) {
      final d = entry.value as Map<String, dynamic>;
      final cardsJson = (d['cards'] as List<dynamic>?) ?? const [];
      _cardsByDay[entry.key] = cardsJson
          .map(
            (c) => _HourCard.fromDraftJson(Map<String, dynamic>.from(c as Map)),
          )
          .toList();
    }
    if (mounted) setState(() {});
  }

  /// Debounced auto-save of the current inputs as a local draft — fires
  /// shortly after the technician stops typing, so it doesn't hit
  /// SharedPreferences on every keystroke.
  void _scheduleDraftSave() {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 500), _saveDraft);
  }

  Future<void> _saveDraft() async {
    final key = _draftKeyFor(_selectedOrder);
    if (key == null) return;
    final days = <String, dynamic>{
      for (final d in _days)
        _key(d): {
          'cards': (_cardsByDay[_key(d)] ?? const [])
              .map((c) => c.toDraftJson())
              .toList(),
        },
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode({'days': days}));
  }

  /// Opens the bon picker and, if a different bon is chosen, saves the
  /// current bon's draft, clears the visible cards, and loads the newly
  /// selected bon's own draft.
  Future<void> _pickOrder() async {
    final picked = await Navigator.of(context).push<ServiceOrder>(
      CupertinoPageRoute<ServiceOrder>(
        builder: (_) => _BonPickerScreen(selectedId: _selectedOrder?.id),
      ),
    );
    if (picked == null || picked.id == _selectedOrder?.id) return;
    _draftSaveTimer?.cancel();
    await _saveDraft();
    setState(() => _selectedOrder = picked);
    await _loadDraft();
  }

  /// Adds an hour card for [day] — or, if no bon is selected yet, opens the
  /// bon picker instead. Cards are always scoped to the selected bon's
  /// draft (see [_saveDraft]/[_loadDraft]), so entry is blocked until a bon
  /// exists to attribute them to; this also means [_loadDraft]'s reset when
  /// switching bons never discards cards a technician just entered.
  Future<void> _addHourCard(DateTime day) async {
    if (_selectedOrder == null) {
      await _pickOrder();
      if (_selectedOrder == null || !mounted) return;
    }
    final draft = await showCupertinoModalPopup<_HourCardDraft>(
      context: context,
      builder: (ctx) => const _AddHourCardSheet(),
    );
    if (draft == null) return;
    final key = _key(day);
    setState(() {
      _cardsByDay
          .putIfAbsent(key, () => [])
          .add(
            _HourCard(
              id: _uuid.v4(),
              workActivityId: draft.workActivityId,
              minutes: draft.minutes,
              memo: draft.memo,
            ),
          );
    });
    _scheduleDraftSave();
  }

  void _removeHourCard(DateTime day, String cardId) {
    setState(() {
      _cardsByDay[_key(day)]?.removeWhere((c) => c.id == cardId);
    });
    _scheduleDraftSave();
  }

  /// Builds one [HoursEntry] per not-yet-submitted card, in chronological
  /// order within each day (so multiple cards on the same day get distinct,
  /// non-overlapping start/end times — only their total duration and day
  /// actually matter to the API, but a sane local narrative is easy to
  /// keep). Cards already marked [_HourCard.submitted] are skipped — they
  /// were sent in an earlier round and must not be sent again.
  List<HoursEntry> _buildHoursEntries() {
    final order = _selectedOrder;
    if (order == null) return const [];
    final entries = <HoursEntry>[];
    for (final d in _days) {
      final cards = (_cardsByDay[_key(d)] ?? const [])
          .where((c) => !c.submitted)
          .toList();
      if (cards.isEmpty) continue;
      var cursor = DateTime(d.year, d.month, d.day, 8);
      for (final card in cards) {
        final end = cursor.add(Duration(minutes: card.minutes));
        entries.add(
          HoursEntry(
            jobOrderId: int.parse(order.id),
            employeeId: AuthService.instance.currentMechanicId!,
            start: cursor,
            end: end,
            totalTime: card.minutes,
            timeEmployee: card.minutes,
            workActivityId: card.workActivityId,
            uniqueId: _uuid.v4(),
            memo: card.memo,
          ),
        );
        cursor = end;
      }
    }
    return entries;
  }

  static String _submitErrorMessage(Object error) {
    if (error is JobOrderSubmissionLoginFailed) {
      return 'Inloggen mislukt bij indienen.\n$error';
    }
    if (error is JobOrderSubmissionFetchFailed) {
      return 'Bon ophalen mislukt.\n$error';
    }
    if (error is JobOrderSubmissionAppointmentNotFound) {
      return 'Deze bon is niet aan jou toegewezen.\n$error';
    }
    if (error is JobOrderSubmissionAppointmentOpenFailed) {
      return 'Afspraak openen mislukt.\n$error';
    }
    if (error is JobOrderSubmissionAppointmentCloseFailed) {
      return 'Afspraak afsluiten mislukt.\n$error';
    }
    if (error is JobOrderSubmissionPostFailed) {
      return 'Indienen van de uren mislukt.\n$error';
    }
    return 'Indienen mislukt.\n$error';
  }

  Future<void> _submit() async {
    final order = _selectedOrder;
    if (order == null) {
      setState(() => _submitError = 'Selecteer eerst een bon.');
      return;
    }
    final mechanicId = AuthService.instance.currentMechanicId;
    if (mechanicId == null) {
      setState(() => _submitError = 'Je bent niet ingelogd.');
      return;
    }
    final entries = _buildHoursEntries();
    if (entries.isEmpty) return;

    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      await ServiceRemoteJobOrderRepository.instance.submitHoursForJobOrder(
        jobOrderId: int.parse(order.id),
        employeeId: mechanicId,
        hours: entries,
      );
      if (!mounted) return;
      // Keep the cards visible — just lock them so they read as sent
      // rather than disappearing, and can't be re-submitted or deleted.
      setState(() {
        for (final d in _days) {
          final key = _key(d);
          _cardsByDay[key] = (_cardsByDay[key] ?? const [])
              .map((c) => c.submitted ? c : c.copyWith(submitted: true))
              .toList();
        }
        _submitting = false;
      });
      await _saveDraft();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = _submitErrorMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final canSubmit =
        !_submitting && _hasPendingCards && _selectedOrder != null;

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.white,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.black,
          onPressed: () {
            // Only report a submitted total back to the caller if it still
            // matches the bon the screen was opened for — if the technician
            // switched to a different bon, those hours don't belong to the
            // caller's optimistic display.
            final matchesInitial =
                widget.initialOrder != null &&
                _selectedOrder?.id == widget.initialOrder!.id;
            final submitted = matchesInitial ? _submittedTotalHours : 0.0;
            Navigator.of(context).pop(submitted > 0 ? submitted : null);
          },
        ),
        middle: const Text(
          'Uren & KM',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: CupertinoColors.black,
          ),
        ),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _ProjectSelectorBar(order: _selectedOrder, onTap: _pickOrder),
              _DayTabStrip(
                days: _days,
                chipKeys: _dayChipKeys,
                currentIndex: _currentPage,
                isPlanned: _isPlanned,
                isToday: _isToday,
                onSelect: (i) => _pageController.animateToPage(
                  i,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    PageView.builder(
                      controller: _pageController,
                      itemCount: _days.length,
                      onPageChanged: (i) {
                        setState(() => _currentPage = i);
                        _scrollDayStripToCurrent(animate: true);
                      },
                      itemBuilder: (context, i) {
                        final d = _days[i];
                        final key = _key(d);
                        return SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: _DayPage(
                            label: _fmtDate(d),
                            isToday: _isToday(d),
                            isPlanned: _isPlanned(d),
                            hasOrder: _selectedOrder != null,
                            cards: _cardsByDay[key] ?? const [],
                            borderColor: borderColor,
                            isDark: isDark,
                            onDeleteCard: (cardId) =>
                                _removeHourCard(d, cardId),
                            onAddPressed: () => _addHourCard(d),
                          ),
                        );
                      },
                    ),
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: _AddHourFab(
                        onPressed: () => _addHourCard(_days[_currentPage]),
                      ),
                    ),
                  ],
                ),
              ),
              _SubmitFooter(
                borderColor: borderColor,
                isDark: isDark,
                totalsLabel: '${_fmtDouble(_totalHours)}u',
                error: _submitError,
                submitting: _submitting,
                canSubmit: canSubmit,
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Add hour FAB ──────────────────────────────────────────────────────────

class _AddHourFab extends StatelessWidget {
  final VoidCallback onPressed;

  const _AddHourFab({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: _accentOrange,
          shape: BoxShape.circle,
          // boxShadow: [
          //   BoxShadow(
          //     color: _accentOrange.withValues(alpha: 0.35),
          //     blurRadius: 14,
          //     offset: const Offset(0, 6),
          //   ),
          // ],
        ),
        child: const Icon(
          CupertinoIcons.add,
          color: CupertinoColors.white,
          size: 28,
        ),
      ),
    );
  }
}

// ─── Day tab strip ─────────────────────────────────────────────────────────

class _DayTabStrip extends StatelessWidget {
  final List<DateTime> days;
  final List<GlobalKey> chipKeys;
  final int currentIndex;
  final bool Function(DateTime) isPlanned;
  final bool Function(DateTime) isToday;
  final ValueChanged<int> onSelect;

  const _DayTabStrip({
    required this.days,
    required this.chipKeys,
    required this.currentIndex,
    required this.isPlanned,
    required this.isToday,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            for (int i = 0; i < days.length; i++)
              GestureDetector(
                key: chipKeys[i],
                onTap: () => onSelect(i),
                behavior: HitTestBehavior.opaque,
                child: _DayTabChip(
                  weekday: _fullDayNames[days[i].weekday],
                  dayNumber: days[i].day,
                  active: i == currentIndex,
                  planned: isPlanned(days[i]),
                  today: isToday(days[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DayTabChip extends StatelessWidget {
  final String weekday;
  final int dayNumber;
  final bool active;
  final bool planned;
  final bool today;

  const _DayTabChip({
    required this.weekday,
    required this.dayNumber,
    required this.active,
    required this.planned,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final bg = active
        ? _accentOrange
        : planned
        ? const Color(0xFF34C759).withValues(alpha: 0.14)
        : const Color(0x00000000);
    final fg = active
        ? CupertinoColors.white
        : planned
        ? const Color(0xFF34C759)
        : CupertinoColors.label.resolveFrom(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            weekday,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: fg,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$dayNumber',
            style: TextStyle(
              fontSize: 14,
              fontWeight: today ? FontWeight.w800 : FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Project selector bar ───────────────────────────────────────────────────

/// Tappable row shown at the top of the screen for choosing which bon the
/// entered hours will be booked onto. Shows a placeholder prompt when no
/// bon is selected yet (e.g. when opened from the dashboard).
class _ProjectSelectorBar extends StatelessWidget {
  final ServiceOrder? order;
  final VoidCallback onTap;

  const _ProjectSelectorBar({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final order = this.order;
    final title = order != null
        ? (order.description.isNotEmpty ? order.description : order.orderNumber)
        : 'Selecteer een bon';
    final subtitle = order != null && order.orderNumber.isNotEmpty
        ? order.orderNumber
        : null;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.resolveFrom(context),
          border: Border(bottom: BorderSide(color: borderColor)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.doc_text,
              size: 18,
              color: order != null
                  ? _accentOrange
                  : CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: order != null
                          ? CupertinoColors.label.resolveFrom(context)
                          : _accentOrange,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              CupertinoIcons.chevron_down,
              size: 14,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Bon picker screen ───────────────────────────────────────────────────────

/// Full-screen picker listing the current technician's bonnen (filtered the
/// same way [ProjectenScreen] does — by matching the logged-in mechanic's
/// name), with search, for choosing which one to book hours onto.
class _BonPickerScreen extends StatefulWidget {
  final String? selectedId;

  const _BonPickerScreen({this.selectedId});

  @override
  State<_BonPickerScreen> createState() => _BonPickerScreenState();
}

class _BonPickerScreenState extends State<_BonPickerScreen> {
  List<ServiceOrder> _orders = [];
  String _query = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await PlanningRepository.instance.fetchServiceOrders();
      final myId = orders
          .firstWhere(
            (o) =>
                o.mechanic?.name.toLowerCase() == currentUserName.toLowerCase(),
            orElse: () => orders.first,
          )
          .mechanic
          ?.id;
      final myOrders = orders.where((o) => o.mechanic?.id == myId).toList()
        ..sort((a, b) {
          final ad = a.planningDate;
          final bd = b.planningDate;
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return bd.compareTo(ad);
        });
      if (mounted) {
        setState(() {
          _orders = myOrders;
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

  List<ServiceOrder> get _filtered {
    if (_query.isEmpty) return _orders;
    final q = _query.toLowerCase();
    return _orders
        .where(
          (o) =>
              o.description.toLowerCase().contains(q) ||
              o.orderNumber.toLowerCase().contains(q) ||
              o.relationName.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.white,
        border: null,
        middle: const Text(
          'Kies een bon',
          style: TextStyle(color: CupertinoColors.black),
        ),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: CupertinoSearchTextField(
                placeholder: 'Zoeken',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : _error != null
                  ? _BonPickerErrorView(error: _error!, onRetry: _load)
                  : _filtered.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty
                            ? 'Geen bonnen gevonden'
                            : 'Geen resultaten',
                        style: const TextStyle(
                          color: CupertinoColors.secondaryLabel,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: _filtered.length,
                      itemBuilder: (context, i) {
                        final o = _filtered[i];
                        return GestureDetector(
                          onTap: () => Navigator.of(context).pop(o),
                          behavior: HitTestBehavior.opaque,
                          child: _BonPickerRow(
                            order: o,
                            selected: o.id == widget.selectedId,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BonPickerRow extends StatelessWidget {
  final ServiceOrder order;
  final bool selected;

  const _BonPickerRow({required this.order, required this.selected});

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

  String _formatDate(DateTime? d) {
    if (d == null) return '—';
    return '${d.day} ${_months[d.month]}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final title = order.description.isNotEmpty
        ? order.description
        : order.orderNumber;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? _accentOrange : borderColor,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    order.orderNumber,
                    order.relationName,
                    _formatDate(order.planningDate),
                  ].where((s) => s.isNotEmpty).join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
          if (selected) ...[
            const SizedBox(width: 8),
            const Icon(
              CupertinoIcons.checkmark_circle_fill,
              size: 20,
              color: _accentOrange,
            ),
          ],
        ],
      ),
    );
  }
}

class _BonPickerErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _BonPickerErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 40,
              color: CupertinoColors.destructiveRed,
            ),
            const SizedBox(height: 12),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: onRetry,
              child: const Text('Opnieuw proberen'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Day page ──────────────────────────────────────────────────────────────

class _DayPage extends StatelessWidget {
  final String label;
  final bool isToday;
  final bool isPlanned;
  final bool hasOrder;
  final List<_HourCard> cards;
  final Color borderColor;
  final bool isDark;
  final ValueChanged<String> onDeleteCard;
  final VoidCallback onAddPressed;

  const _DayPage({
    required this.label,
    required this.isToday,
    required this.isPlanned,
    required this.hasOrder,
    required this.cards,
    required this.borderColor,
    required this.isDark,
    required this.onDeleteCard,
    required this.onAddPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (isPlanned) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF34C759).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Gepland',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF34C759),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        if (cards.isEmpty)
          _EmptyCardsHint(
            onAddPressed: onAddPressed,
            isDark: isDark,
            hasOrder: hasOrder,
          )
        else
          for (final card in cards)
            _HourCardTile(
              key: ValueKey(card.id),
              type: _hourTypeById(card.workActivityId),
              minutes: card.minutes,
              memo: card.memo,
              borderColor: borderColor,
              isDark: isDark,
              submitted: card.submitted,
              onDelete: () => onDeleteCard(card.id),
            ),
      ],
    );
  }
}

// ─── Hour card tile ─────────────────────────────────────────────────────────

class _HourCardTile extends StatelessWidget {
  final _HourType type;
  final int minutes;
  final String? memo;
  final Color borderColor;
  final bool isDark;
  final bool submitted;
  final VoidCallback onDelete;

  const _HourCardTile({
    super.key,
    required this.type,
    required this.minutes,
    required this.memo,
    required this.borderColor,
    required this.isDark,
    required this.submitted,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final mutedFg = CupertinoColors.tertiaryLabel.resolveFrom(context);
    final cardBg = submitted
        ? (isDark ? const Color(0xFF232324) : const Color(0xFFF2F2F7))
        : (isDark ? const Color(0xFF1C1C1E) : CupertinoColors.systemBackground);
    final iconBg = submitted
        ? mutedFg.withValues(alpha: 0.15)
        : type.color.withValues(alpha: 0.14);
    final iconFg = submitted ? mutedFg : type.color;
    final titleFg = submitted
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : CupertinoColors.label.resolveFrom(context);
    final durationFg = submitted ? mutedFg : type.color;

    final content = Container(
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
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              submitted ? CupertinoIcons.checkmark_alt : type.icon,
              size: 16,
              color: iconFg,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      type.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: titleFg,
                      ),
                    ),
                    if (submitted) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: mutedFg.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Verzonden',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (memo != null && memo!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    memo!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: submitted
                          ? mutedFg
                          : CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatMinutes(minutes),
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: durationFg,
            ),
          ),
        ],
      ),
    );

    // Submitted cards are locked: no swipe-to-delete, they're a record of
    // what was actually sent.
    if (submitted) return content;

    return Dismissible(
      key: key!,
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        margin: const EdgeInsets.only(bottom: 10),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: CupertinoColors.destructiveRed,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(
          CupertinoIcons.delete_solid,
          color: CupertinoColors.white,
          size: 18,
        ),
      ),
      child: content,
    );
  }
}

class _EmptyCardsHint extends StatelessWidget {
  final VoidCallback onAddPressed;
  final bool isDark;
  final bool hasOrder;

  const _EmptyCardsHint({
    required this.onAddPressed,
    required this.isDark,
    required this.hasOrder,
  });

  @override
  Widget build(BuildContext context) {
    const tint = _accentOrange;
    return GestureDetector(
      onTap: onAddPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: isDark ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(16),
          // border: Border.all(color: tint.withValues(alpha: 0.3), width: 1),
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
              child: Icon(
                hasOrder ? CupertinoIcons.add : CupertinoIcons.doc_text,
                size: 22,
                color: tint,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              hasOrder ? 'Nog geen uren toegevoegd' : 'Geen bon geselecteerd',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              hasOrder
                  ? 'Tik om uren toe te voegen'
                  : 'Tik om een bon te kiezen',
              style: const TextStyle(fontSize: 12, color: tint),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Add hour card sheet ────────────────────────────────────────────────────

class _HourCardDraft {
  const _HourCardDraft({
    required this.workActivityId,
    required this.minutes,
    this.memo,
  });
  final int workActivityId;
  final int minutes;
  final String? memo;
}

class _AddHourCardSheet extends StatefulWidget {
  const _AddHourCardSheet();

  @override
  State<_AddHourCardSheet> createState() => _AddHourCardSheetState();
}

class _AddHourCardSheetState extends State<_AddHourCardSheet> {
  final _amountCtrl = TextEditingController();
  final _memoCtrl = TextEditingController();
  late _HourType _selectedType;

  @override
  void initState() {
    super.initState();
    _selectedType = _hourTypes.first;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  double get _amount => _parseDecimal(_amountCtrl.text);
  bool get _isValid => _amount > 0;

  Future<void> _pickType() async {
    final selected = await showCupertinoModalPopup<_HourType>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Type uren'),
        actions: [
          for (final type in _hourTypes)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(ctx).pop(type),
              isDefaultAction: type.id == _selectedType.id,
              child: Text(type.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
    if (selected != null) setState(() => _selectedType = selected);
  }

  void _add() {
    if (!_isValid) return;
    final memo = _memoCtrl.text.trim();
    Navigator.of(context).pop(
      _HourCardDraft(
        workActivityId: _selectedType.id,
        minutes: (_amount * 60).round(),
        memo: memo.isEmpty ? null : memo,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final sheetBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final inputBg = isDark ? const Color(0xFF2C2C2E) : CupertinoColors.white;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 5,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: borderColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const Text(
              'Uren toevoegen',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Text(
                  'Aantal uren',
                  style: TextStyle(
                    fontSize: 15,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                const Spacer(),
                SizedBox(
                  width: 100,
                  height: 40,
                  child: Container(
                    decoration: BoxDecoration(
                      color: inputBg,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: borderColor, width: 0.5),
                    ),
                    child: CupertinoTextField(
                      controller: _amountCtrl,
                      autofocus: true,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                      ],
                      placeholder: '— u',
                      placeholderStyle: TextStyle(
                        fontSize: 14,
                        color: CupertinoColors.tertiaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                      decoration: const BoxDecoration(),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _pickType,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Text(
                    'Type',
                    style: TextStyle(
                      fontSize: 15,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _selectedType.label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: _accentOrange,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    CupertinoIcons.chevron_down,
                    size: 14,
                    color: _accentOrange,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            CupertinoTextField(
              controller: _memoCtrl,
              placeholder: 'Omschrijving (optioneel)',
              minLines: 2,
              maxLines: 4,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              placeholderStyle: TextStyle(
                fontSize: 14,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
              style: TextStyle(
                fontSize: 14,
                color: CupertinoColors.label.resolveFrom(context),
              ),
              decoration: BoxDecoration(
                color: inputBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: borderColor, width: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            CupertinoButton(
              color: const Color(0xFF34C759),
              borderRadius: BorderRadius.circular(14),
              onPressed: _isValid ? _add : null,
              child: const Text(
                'Toevoegen',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Submit footer ─────────────────────────────────────────────────────────

class _SubmitFooter extends StatelessWidget {
  final Color borderColor;
  final bool isDark;
  final String totalsLabel;
  final String? error;
  final bool submitting;
  final bool canSubmit;
  final VoidCallback onSubmit;

  const _SubmitFooter({
    required this.borderColor,
    required this.isDark,
    required this.totalsLabel,
    required this.error,
    required this.submitting,
    required this.canSubmit,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
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
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                totalsLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error!,
              style: const TextStyle(
                fontSize: 12,
                color: CupertinoColors.destructiveRed,
              ),
            ),
          ],
          const SizedBox(height: 10),
          CupertinoButton(
            color: const Color(0xFF34C759),
            borderRadius: BorderRadius.circular(14),
            onPressed: canSubmit ? onSubmit : null,
            child: submitting
                ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                : const Text(
                    'Uren indienen',
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
