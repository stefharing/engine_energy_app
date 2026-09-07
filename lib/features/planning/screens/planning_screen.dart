import 'package:flutter/cupertino.dart';

import '../data/planning_repository.dart';
import '../models/job_order.dart';
import '../../../widgets/engine_logo.dart';
import '../../../core/storage/settings_service.dart';
import '../../../core/auth/current_user.dart';
import '../../../widgets/nav_border.dart';
import 'planning_settings_screen.dart';
import 'bon_detail_screen.dart';

const _leftColWidth = 72.0;
const _rowMinHeight = 48.0;
const _rowMaxHeight = 88.0;
const _headerHeight = 40.0;
const _visibleDays = 2.5;

// Days to show before/after the order range
const _padDaysBefore = 7;
const _padDaysAfter = 14;

const List<Color> _palette = [
  Color(0xFF4A90D9),
  Color(0xFFE85D75),
  Color(0xFF50C878),
  Color(0xFFF5A623),
  Color(0xFF9B59B6),
  Color(0xFF1ABC9C),
  Color(0xFFE67E22),
];

Color _colorFor(int? id) =>
    id == null ? const Color(0xFFAAAAAA) : _palette[id % _palette.length];

// Fixed, mechanic-independent color for CRM appointments (Outlook-agenda-items)
// so they read as a distinct category rather than blending into a mechanic's row.
const Color _appointmentColor = Color(0xFF6B7684);

// ─── Screen ────────────────────────────────────────────────────────────────────

class PlanningScreen extends StatefulWidget {
  const PlanningScreen({super.key});

  @override
  State<PlanningScreen> createState() => _PlanningScreenState();
}

class _PlanningScreenState extends State<PlanningScreen> {
  List<ServiceOrder> _allOrders = [];
  List<Appointment> _allAppointments = [];
  List<ServicePerson> _employees = [];
  Set<int> _hiddenIds = {};
  List<int> _employeeOrder = [];
  bool _loading = true;
  String? _error;
  final _hScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadHiddenIds();
  }

  Future<void> _loadHiddenIds() async {
    final results = await Future.wait([
      SettingsService.instance.loadHiddenIds(),
      SettingsService.instance.loadEmployeeOrder(),
    ]);
    setState(() {
      _hiddenIds = results[0] as Set<int>;
      _employeeOrder = results[1] as List<int>;
    });
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => PlanningSettingsScreen(employees: _employees),
      ),
    );
    _loadHiddenIds();
  }

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        PlanningRepository.instance.fetchServiceOrders(),
        PlanningRepository.instance.fetchEmployees(),
        PlanningRepository.instance.fetchAppointments(),
      ]);
      setState(() {
        _allOrders = results[0] as List<ServiceOrder>;
        _employees = results[1] as List<ServicePerson>;
        _allAppointments = results[2] as List<Appointment>;
        _loading = false;
      });
      _scrollToToday();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Scroll to today's column after the layout has been built.
  void _scrollToToday() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hScroll.hasClients) return;
      final days = _timelineDays;
      if (days.isEmpty) return;
      final today = DateTime.now();
      final todayOnly = DateTime(today.year, today.month, today.day);
      final index = days.indexWhere((d) => d == todayOnly);
      if (index < 0) return;
      final dayWidth = (_hScroll.position.viewportDimension) / _visibleDays;
      final offset = index * dayWidth;
      _hScroll.animateTo(
        offset.clamp(0.0, _hScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    });
  }

  /// Ridder auto-generates a calendar appointment whenever a job order is
  /// assigned to a mechanic; its title embeds the job order's recordtag
  /// (e.g. "Holland Diesel Maassluis B.V. 200027.1 3000 HR service ...").
  /// Such appointments duplicate the job order block, so they're filtered
  /// out here — only genuine (non-order-linked) appointments remain as
  /// separate agenda-items.
  bool _appointmentIsOrder(Appointment appt) => _allOrders.any(
        (o) =>
            o.recordTag.isNotEmpty &&
            o.mechanicId == appt.mechanicId &&
            appt.description.contains(o.recordTag),
      );

  List<PlanningItem> get _allItems => [
    ..._allOrders,
    ..._allAppointments.where((a) => !_appointmentIsOrder(a)),
  ];

  /// Builds the full date range: earliest order − padBefore … latest order + padAfter.
  /// Falls back to today ± some days if there are no orders.
  List<DateTime> get _timelineDays {
    final today = DateTime.now();
    DateTime earliest = DateTime(
      today.year,
      today.month,
      today.day - _padDaysBefore,
    );
    DateTime latest = DateTime(
      today.year,
      today.month,
      today.day + _padDaysAfter,
    );

    for (final o in _allItems) {
      final d = o.planningDate;
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(earliest)) earliest = day;
      if (day.isAfter(latest)) latest = day;
    }

    // Add padding around the order range
    earliest = DateTime(
      earliest.year,
      earliest.month,
      earliest.day - _padDaysBefore,
    );
    latest = DateTime(latest.year, latest.month, latest.day + _padDaysAfter);

    final count = latest.difference(earliest).inDays + 1;
    return List.generate(
      count,
      (i) => DateTime(earliest.year, earliest.month, earliest.day + i),
    );
  }

  List<ServicePerson> get _mechanics {
    final visible = _employees
        .where((e) => !_hiddenIds.contains(e.id))
        .toList();
    if (_employeeOrder.isNotEmpty) {
      visible.sort((a, b) {
        final ai = _employeeOrder.indexOf(a.id);
        final bi = _employeeOrder.indexOf(b.id);
        return (ai < 0 ? 9999 : ai).compareTo(bi < 0 ? 9999 : bi);
      });
    }
    final currentIndex = visible.indexWhere(
      (e) => e.name.toLowerCase() == currentUserName.toLowerCase(),
    );
    if (currentIndex > 0) {
      final current = visible.removeAt(currentIndex);
      visible.insert(0, current);
    }
    return visible;
  }

  List<PlanningItem> _itemsForMechanic(ServicePerson m) =>
      _allItems.where((o) => o.mechanicId == m.id).toList();

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: const Color(0xFFFFFFFF),
        border: null,
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 20),
        middle: const EngineLogo(),
        trailing: GestureDetector(
          onTap: _openSettings,
          behavior: HitTestBehavior.opaque,
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Icon(
              CupertinoIcons.ellipsis,
              color: CupertinoColors.black,
              size: 18,
            ),
          ),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const NavBorder(),
            Expanded(
              child: _loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : _error != null
                  ? _ErrorView(error: _error!, onRetry: _loadData)
                  : _TimetableView(
                      days: _timelineDays,
                      mechanics: _mechanics,
                      itemsForMechanic: _itemsForMechanic,
                      hScroll: _hScroll,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Timetable view ────────────────────────────────────────────────────────────

class _TimetableView extends StatefulWidget {
  final List<DateTime> days;
  final List<ServicePerson> mechanics;
  final List<PlanningItem> Function(ServicePerson) itemsForMechanic;
  final ScrollController hScroll;

  const _TimetableView({
    required this.days,
    required this.mechanics,
    required this.itemsForMechanic,
    required this.hScroll,
  });

  @override
  State<_TimetableView> createState() => _TimetableViewState();
}

class _TimetableViewState extends State<_TimetableView> {
  final _headerScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.hScroll.addListener(_syncHeader);
  }

  @override
  void dispose() {
    widget.hScroll.removeListener(_syncHeader);
    _headerScroll.dispose();
    super.dispose();
  }

  void _syncHeader() {
    if (_headerScroll.hasClients) {
      _headerScroll.jumpTo(widget.hScroll.offset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final gridBorderColor = isDark
        ? const Color(0xFF2A2A2C)
        : const Color(0xFFF0F0F5);

    return LayoutBuilder(
      builder: (context, constraints) {
        final dayWidth = (constraints.maxWidth - _leftColWidth) / _visibleDays;
        final totalGridWidth = dayWidth * widget.days.length;

        final availableHeight = constraints.maxHeight - _headerHeight;
        final rowCount = widget.mechanics.length;
        final rowHeight = rowCount == 0
            ? _rowMinHeight
            : (availableHeight / rowCount).clamp(_rowMinHeight, _rowMaxHeight);

        final headerBg = isDark
            ? const Color(0xFF1C1C1E)
            : const Color(0xFFF2F2F7);

        return Column(
          children: [
            // ── Sticky day header ──
            Container(
              height: _headerHeight,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: borderColor)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: _leftColWidth,
                    child: Container(
                      decoration: BoxDecoration(
                        color: headerBg,
                        border: Border(right: BorderSide(color: borderColor)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _headerScroll,
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: SizedBox(
                        width: totalGridWidth,
                        child: Row(
                          children: widget.days
                              .map(
                                (d) => _DayHeaderCell(
                                  day: d,
                                  width: dayWidth,
                                  borderColor: borderColor,
                                  baseBg: headerBg,
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Employee rows ──
            Expanded(
              child: SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fixed name column
                    SizedBox(
                      width: _leftColWidth,
                      child: Column(
                        children: [
                          for (int i = 0; i < widget.mechanics.length; i++)
                            _NameCell(
                              mechanic: widget.mechanics[i],
                              rowHeight: rowHeight,
                              borderColor: borderColor,
                              isLast: i == widget.mechanics.length - 1,
                              isCurrentUser:
                                  widget.mechanics[i].name.toLowerCase() ==
                                  currentUserName.toLowerCase(),
                            ),
                        ],
                      ),
                    ),
                    // Horizontally scrollable grid
                    SizedBox(
                      width: constraints.maxWidth - _leftColWidth,
                      child: SingleChildScrollView(
                        controller: widget.hScroll,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: totalGridWidth,
                          child: Column(
                            children: [
                              for (int i = 0; i < widget.mechanics.length; i++)
                                _MechanicRow(
                                  mechanic: widget.mechanics[i],
                                  items: widget.itemsForMechanic(
                                    widget.mechanics[i],
                                  ),
                                  days: widget.days,
                                  dayWidth: dayWidth,
                                  rowHeight: rowHeight,
                                  borderColor: gridBorderColor,
                                  isLast: i == widget.mechanics.length - 1,
                                  hScroll: widget.hScroll,
                                  isCurrentUser:
                                      widget.mechanics[i].name.toLowerCase() ==
                                      currentUserName.toLowerCase(),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Day header cell ───────────────────────────────────────────────────────────

class _DayHeaderCell extends StatelessWidget {
  final DateTime day;
  final double width;
  final Color borderColor;
  final Color baseBg;

  const _DayHeaderCell({
    required this.day,
    required this.width,
    required this.borderColor,
    required this.baseBg,
  });

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

  bool get _isToday {
    final now = DateTime.now();
    return day.year == now.year && day.month == now.month && day.day == now.day;
  }

  bool get _isFirstOfMonth => day.day == 1;

  bool get _isWeekend => day.weekday >= 6;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final weekendBg = isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFF2F2F7);
    final labelColor = _isToday
        ? CupertinoColors.activeBlue
        : CupertinoColors.secondaryLabel.resolveFrom(context);

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: _isToday
            ? CupertinoColors.activeBlue.withValues(alpha: 0.10)
            : _isWeekend
            ? weekendBg
            : baseBg,
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: Center(
        child: _isFirstOfMonth
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _months[day.month].toUpperCase(),
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: labelColor,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    '${day.day}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: labelColor,
                    ),
                  ),
                ],
              )
            : RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: TextStyle(color: labelColor),
                  children: [
                    TextSpan(
                      text: _dayNames[day.weekday],
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    TextSpan(
                      text: ' ${day.day}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: _isToday
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

// ─── Name cell ─────────────────────────────────────────────────────────────────

class _NameCell extends StatelessWidget {
  final ServicePerson mechanic;
  final double rowHeight;
  final Color borderColor;
  final bool isLast;
  final bool isCurrentUser;

  const _NameCell({
    required this.mechanic,
    required this.rowHeight,
    required this.borderColor,
    required this.isLast,
    this.isCurrentUser = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final baseBg = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final bg = isCurrentUser
        ? CupertinoColors.activeOrange.withValues(alpha: 0.08)
        : baseBg;
    final fg = isCurrentUser
        ? CupertinoColors.activeOrange
        : CupertinoColors.secondaryLabel.resolveFrom(context);
    final firstName = mechanic.name.split(' ').first;

    return Container(
      height: rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          bottom: isLast ? BorderSide.none : BorderSide(color: borderColor),
          right: BorderSide(color: borderColor),
        ),
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        firstName,
        style: TextStyle(
          fontSize: 13,
          fontWeight: isCurrentUser ? FontWeight.w700 : FontWeight.w500,
          color: fg,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

// ─── Mechanic row ──────────────────────────────────────────────────────────────

class _MechanicRow extends StatelessWidget {
  final ServicePerson mechanic;
  final List<PlanningItem> items;
  final List<DateTime> days;
  final double dayWidth;
  final double rowHeight;
  final Color borderColor;
  final bool isLast;
  final ScrollController hScroll;
  final bool isCurrentUser;

  const _MechanicRow({
    required this.mechanic,
    required this.items,
    required this.days,
    required this.dayWidth,
    required this.rowHeight,
    required this.borderColor,
    required this.isLast,
    required this.hScroll,
    this.isCurrentUser = false,
  });

  DateTime get _rangeStart => days.first;

  // Use UTC midnights for day-index arithmetic to avoid DST off-by-one errors.
  static int _daysBetween(DateTime a, DateTime b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  double _leftOffset(PlanningItem o) {
    final start = o.planningDate;
    if (start == null) return -1;
    final dayIndex = _daysBetween(_rangeStart, start);
    return dayIndex * dayWidth;
  }

  double _eventWidth(PlanningItem o) {
    final start = o.planningDate;
    if (start == null) return dayWidth - 4;
    final end = o.endTime ?? start;
    final spanDays = _daysBetween(start, end) + 1;
    return spanDays * dayWidth - 4;
  }

  bool _isVisible(PlanningItem o) {
    final date = o.planningDate;
    if (date == null) return false;
    final day = DateTime(date.year, date.month, date.day);
    return !day.isBefore(days.first) && !day.isAfter(days.last);
  }

  DateTime _endDay(PlanningItem o) {
    final start = o.planningDate!;
    final end = o.endTime ?? start;
    return DateTime(end.year, end.month, end.day);
  }

  /// Assigns each visible item to a vertical lane so overlapping items
  /// don't cover each other. Items are grouped into clusters of mutually
  /// overlapping dates first, so the lane count — and therefore block
  /// height — only shrinks for items that actually overlap something.
  /// A lone item elsewhere in the row stays full height even if this
  /// mechanic has a double-booking on another day.
  ({Map<PlanningItem, int> lanes, Map<PlanningItem, int> clusterSize})
  _computeLanes(List<PlanningItem> visible) {
    if (visible.isEmpty) return (lanes: {}, clusterSize: {});

    final sorted = visible.toList()
      ..sort((a, b) {
        final da = a.planningDate ?? DateTime(2000);
        final db = b.planningDate ?? DateTime(2000);
        return da.compareTo(db);
      });

    final lanes = <PlanningItem, int>{};
    final clusterSize = <PlanningItem, int>{};

    var cluster = <PlanningItem>[];
    DateTime? clusterEnd;

    void flushCluster() {
      if (cluster.isEmpty) return;
      // laneEnds[i] = end day of the last item placed in lane i
      final laneEnds = <int, DateTime>{};
      var maxLane = 0;
      for (final item in cluster) {
        final start = item.planningDate;
        if (start == null) {
          lanes[item] = 0;
          continue;
        }
        final startDay = DateTime(start.year, start.month, start.day);
        final endDay = _endDay(item);

        // Find first lane whose last end is strictly before this item's start
        int lane = 0;
        while (laneEnds.containsKey(lane) &&
            !laneEnds[lane]!.isBefore(startDay)) {
          lane++;
        }
        lanes[item] = lane;
        if (lane > maxLane) maxLane = lane;
        final prev = laneEnds[lane];
        if (prev == null || endDay.isAfter(prev)) laneEnds[lane] = endDay;
      }
      for (final item in cluster) {
        clusterSize[item] = maxLane + 1;
      }
      cluster = [];
      clusterEnd = null;
    }

    for (final item in sorted) {
      final start = item.planningDate;
      if (start == null) {
        cluster.add(item);
        continue;
      }
      final startDay = DateTime(start.year, start.month, start.day);
      final endDay = _endDay(item);

      if (clusterEnd != null && startDay.isAfter(clusterEnd!)) {
        flushCluster();
      }
      cluster.add(item);
      if (clusterEnd == null || endDay.isAfter(clusterEnd!)) {
        clusterEnd = endDay;
      }
    }
    flushCluster();

    return (lanes: lanes, clusterSize: clusterSize);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final cellBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final todayBg = isDark
        ? const Color(0xFF1A2A3A)
        : CupertinoColors.activeBlue.withValues(alpha: 0.05);
    final mechanicColor = _colorFor(mechanic.id);
    final totalWidth = dayWidth * days.length;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final visible = items.where(_isVisible).toList();
    final (:lanes, :clusterSize) = _computeLanes(visible);

    return SizedBox(
      height: rowHeight,
      width: totalWidth,
      child: Stack(
        children: [
          // Background day cells
          Row(
            children: days.map((day) {
              final isToday = day == today;
              return Container(
                width: dayWidth,
                height: rowHeight,
                decoration: BoxDecoration(
                  color: cellBg,
                  border: Border(
                    bottom: isLast
                        ? BorderSide.none
                        : BorderSide(color: borderColor),
                    right: BorderSide(color: borderColor),
                  ),
                ),
              );
            }).toList(),
          ),

          // Event blocks
          for (final item in visible)
            Positioned(
              left: _leftOffset(item) + 2,
              top:
                  6 +
                  (lanes[item] ?? 0) *
                      ((rowHeight - 12) / (clusterSize[item] ?? 1)),
              height: (rowHeight - 12) / (clusterSize[item] ?? 1) - 2,
              width: _eventWidth(item),
              child: GestureDetector(
                onTap: () {
                  if (item is ServiceOrder) {
                    Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => BonDetailScreen(order: item),
                      ),
                    );
                  } else if (item is Appointment) {
                    showAppointmentDetail(context, item);
                  }
                },
                child: _EventChip(
                  item: item,
                  color: item is Appointment ? _appointmentColor : mechanicColor,
                  chipLeft: _leftOffset(item) + 2,
                  hScroll: hScroll,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Event chip ────────────────────────────────────────────────────────────────

class _EventChip extends StatelessWidget {
  final PlanningItem item;
  final Color color;
  final double chipLeft;
  final ScrollController hScroll;

  const _EventChip({
    required this.item,
    required this.color,
    required this.chipLeft,
    required this.hScroll,
  });

  @override
  Widget build(BuildContext context) {
    final label = item.title;
    final subtitle = item.subtitle;
    final isAppointment = item is Appointment;

    return AnimatedBuilder(
      animation: hScroll,
      builder: (context, _) {
        final scrollOffset = hScroll.hasClients ? hScroll.offset : 0.0;
        final stickyOffset = (scrollOffset - chipLeft).clamp(
          0.0,
          double.infinity,
        );

        return Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
          padding: EdgeInsets.only(
            left: 6 + stickyOffset,
            right: 6,
            top: 4,
            bottom: 4,
          ),
          alignment: Alignment.centerLeft,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isAppointment) ...[
                    const Icon(
                      CupertinoIcons.calendar,
                      size: 11,
                      color: CupertinoColors.white,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: CupertinoColors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Appointment detail ────────────────────────────────────────────────────────

const _appointmentMonths = [
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

String _fmtAppointmentTime(DateTime? d) {
  if (d == null) return '—';
  final time =
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  return '${d.day} ${_appointmentMonths[d.month]}, $time';
}

void showAppointmentDetail(BuildContext context, Appointment appt) {
  final range = appt.allDay
      ? _fmtAppointmentTime(appt.start).split(',').first
      : '${_fmtAppointmentTime(appt.start)} - '
            '${appt.end != null ? '${appt.end!.hour.toString().padLeft(2, '0')}:${appt.end!.minute.toString().padLeft(2, '0')}' : '—'}';

  showCupertinoDialog<void>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(appt.title),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(range),
            if (appt.employee != null) ...[
              const SizedBox(height: 4),
              Text(appt.employee!.name),
            ],
          ],
        ),
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

// ─── Error view ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

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
