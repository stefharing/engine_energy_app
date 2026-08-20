import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/auth_service.dart';
import '../data/planning_repository.dart';
import '../data/service_remote_job_order_repository.dart';
import '../models/hours_entry.dart';
import '../models/job_order.dart';

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
    CupertinoColors.activeBlue,
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

/// Paginated week view for entering a technician's hours on a bon — one day
/// per page, swipeable, with the bon's planned days highlighted but every
/// day of the week open for entry. Hours are entered as individual cards
/// (amount + type + description) via the "+" button, rather than fixed
/// work/travel fields. Submission writes to Ridder via
/// [ServiceRemoteJobOrderRepository.submitHoursForJobOrder].
class HoursWeekScreen extends StatefulWidget {
  final ServiceOrder order;

  const HoursWeekScreen({super.key, required this.order});

  @override
  State<HoursWeekScreen> createState() => _HoursWeekScreenState();
}

class _HoursWeekScreenState extends State<HoursWeekScreen> {
  late final List<DateTime> _days;
  late final Map<String, List<_HourCard>> _cardsByDay;
  late final PageController _pageController;
  int _currentPage = 0;

  bool _submitting = false;
  String? _submitError;
  Timer? _draftSaveTimer;
  final _uuid = const Uuid();

  String get _draftKey => 'hours_week_draft_${widget.order.id}';

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
    _days = _buildWeekDays();
    _cardsByDay = {for (final d in _days) _key(d): <_HourCard>[]};
    final initialPage = _initialPageIndex();
    _currentPage = initialPage;
    _pageController = PageController(initialPage: initialPage);
    _loadDraft();
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// The Mon–Sun week containing `order.startDate` (or today's week if the
  /// bon has no planned date).
  List<DateTime> _buildWeekDays() {
    final anchor = widget.order.startDate ?? DateTime.now();
    final anchorDay = DateTime(anchor.year, anchor.month, anchor.day);
    final monday = anchorDay.subtract(Duration(days: anchorDay.weekday - 1));
    return List.generate(7, (i) => monday.add(Duration(days: i)));
  }

  int _initialPageIndex() {
    final today = DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    final todayIndex = _days.indexWhere((d) => d == todayOnly);
    if (todayIndex >= 0) return todayIndex;
    final firstPlanned = _days.indexWhere(_isPlanned);
    return firstPlanned >= 0 ? firstPlanned : 0;
  }

  bool _isPlanned(DateTime day) {
    final start = widget.order.startDate;
    if (start == null) return false;
    final end = widget.order.endTime ?? start;
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

  /// Restores a previously locally-saved (not-yet-submitted) draft, if any
  /// — the phone remembers cards created in a previous session until
  /// they're actually submitted.
  Future<void> _loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftKey);
    if (raw == null) return;
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
    final days = <String, dynamic>{
      for (final d in _days)
        _key(d): {
          'cards': (_cardsByDay[_key(d)] ?? const [])
              .map((c) => c.toDraftJson())
              .toList(),
        },
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftKey, jsonEncode({'days': days}));
  }

  Future<void> _addHourCard(DateTime day) async {
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
            jobOrderId: int.parse(widget.order.id),
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
        jobOrderId: int.parse(widget.order.id),
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
    final canSubmit = !_submitting && _hasPendingCards;

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.systemBackground,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.label,
          onPressed: () {
            final submitted = _submittedTotalHours;
            Navigator.of(context).pop(submitted > 0 ? submitted : null);
          },
        ),
        middle: const Text(
          'Uren & KM',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _DayTabStrip(
                days: _days,
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
                      onPageChanged: (i) => setState(() => _currentPage = i),
                      itemBuilder: (context, i) {
                        final d = _days[i];
                        final key = _key(d);
                        return SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: _DayPage(
                            label: _fmtDate(d),
                            isToday: _isToday(d),
                            isPlanned: _isPlanned(d),
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
          color: CupertinoColors.activeBlue,
          shape: BoxShape.circle,
          // boxShadow: [
          //   BoxShadow(
          //     color: CupertinoColors.activeBlue.withValues(alpha: 0.35),
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
  final int currentIndex;
  final bool Function(DateTime) isPlanned;
  final bool Function(DateTime) isToday;
  final ValueChanged<int> onSelect;

  const _DayTabStrip({
    required this.days,
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
        ? CupertinoColors.activeBlue
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

// ─── Day page ──────────────────────────────────────────────────────────────

class _DayPage extends StatelessWidget {
  final String label;
  final bool isToday;
  final bool isPlanned;
  final List<_HourCard> cards;
  final Color borderColor;
  final bool isDark;
  final ValueChanged<String> onDeleteCard;
  final VoidCallback onAddPressed;

  const _DayPage({
    required this.label,
    required this.isToday,
    required this.isPlanned,
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
            Text(
              label,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
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
          _EmptyCardsHint(onAddPressed: onAddPressed, isDark: isDark)
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

  const _EmptyCardsHint({required this.onAddPressed, required this.isDark});

  @override
  Widget build(BuildContext context) {
    const tint = CupertinoColors.activeBlue;
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
              child: const Icon(CupertinoIcons.add, size: 22, color: tint),
            ),
            const SizedBox(height: 12),
            Text(
              'Nog geen uren toegevoegd',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'Tik om uren toe te voegen',
              style: TextStyle(fontSize: 12, color: tint),
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
