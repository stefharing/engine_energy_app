import 'dart:math' as math;
import 'package:flutter/cupertino.dart';

import '../core/api/api_client.dart';
import '../core/auth/auth_service.dart';
import '../features/planning/screens/hours_week_screen.dart';
import '../widgets/engine_logo.dart';
import '../widgets/nav_border.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String? _error;
  double _weekHours = 0;
  final double _contractHoursPerWeek = 40;

  static const _months = [
    '', 'jan', 'feb', 'mrt', 'apr', 'mei', 'jun',
    'jul', 'aug', 'sep', 'okt', 'nov', 'dec',
  ];

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
      final employeeId = AuthService.instance.currentMechanicId;
      if (employeeId == null) {
        setState(() {
          _error = 'Je bent niet ingelogd.';
          _loading = false;
        });
        return;
      }

      final dio = ApiClient.instance.dio;

      // Compute current ISO year-week number (e.g. 202616)
      final now = DateTime.now();
      final yearWeek = _isoYearWeek(now);

      // Fetch projecttimes for this week — single filter, no quotes needed.
      // Then filter client-side by employee so Dio's query encoding can't break it.
      final hoursResponse = await dio.get(
        '/hours/projecttimes',
        queryParameters: {
          'page': 1,
          'size': 200,
          'filter': 'yearweeknr[eq]$yearWeek',
        },
      );

      final entries = (hoursResponse.data['data'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      double total = 0;
      for (final entry in entries) {
        final emp = entry['employee'] as Map<String, dynamic>?;
        final entryEmployeeId = emp?['id'];
        if (entryEmployeeId == employeeId) {
          // timeemployee is in HH:MM:SS format
          total += _parseTimeHHMMSS(entry['timeemployee'] as String? ?? '');
        }
      }

      setState(() {
        _weekHours = total;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  double _parseTimeHHMMSS(String t) {
    final parts = t.split(':');
    if (parts.length < 2) return 0;
    final h = double.tryParse(parts[0]) ?? 0;
    final m = double.tryParse(parts[1]) ?? 0;
    return h + m / 60;
  }

  // Returns ISO year-week as integer e.g. 202616 for week 16 of 2026.
  int _isoYearWeek(DateTime date) {
    final thursday = date.add(Duration(days: 4 - date.weekday));
    final jan1 = DateTime(thursday.year, 1, 1);
    final week = ((thursday.difference(jan1).inDays) / 7).floor() + 1;
    return thursday.year * 100 + week;
  }

  String _fmtHours(double h) =>
      h == h.truncateToDouble() ? h.toInt().toString() : h.toStringAsFixed(1);

  Future<void> _openHoursWeek() async {
    await Navigator.of(
      context,
    ).push(CupertinoPageRoute<double>(builder: (_) => const HoursWeekScreen()));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;

    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: const Color(0xFFFFFFFF),
        border: null,
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 20),
        middle: const EngineLogo(),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => AuthService.instance.logout(),
          child: const Icon(CupertinoIcons.square_arrow_right),
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
                      ? _buildError()
                      : _buildContent(isDark),
            ),
          ],
        ),
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
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 20),
            CupertinoButton(
              onPressed: _load,
              child: const Text('Opnieuw proberen'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(bool isDark) {
    final pct =
        _contractHoursPerWeek > 0 ? (_weekHours / _contractHoursPerWeek).clamp(0.0, 1.0) : 0.0;
    final pctInt = (pct * 100).round();

    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    final weekLabel =
        '${monday.day} – ${sunday.day} ${_months[sunday.month]} ${sunday.year}';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Dashboard',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Week $weekLabel',
            style: const TextStyle(
              fontSize: 15,
              color: CupertinoColors.systemGrey,
            ),
          ),
          const SizedBox(height: 20),
          _ActionCard(
            label: 'Uren & km registreren',
            icon: CupertinoIcons.timer,
            isDark: isDark,
            onTap: _openHoursWeek,
          ),
          const SizedBox(height: 24),
          Center(
            child: _RingChart(
              bookedHours: _weekHours,
              contractHours: _contractHoursPerWeek,
              percentage: pct,
              isDark: isDark,
            ),
          ),
          const SizedBox(height: 40),
          _StatCard(
            label: 'Geboekte uren',
            value: '${_fmtHours(_weekHours)} uur',
            color: const Color(0xFFFF6B2B),
            isDark: isDark,
          ),
          const SizedBox(height: 10),
          _StatCard(
            label: 'Contract uren / week',
            value: '${_fmtHours(_contractHoursPerWeek)} uur',
            color: CupertinoColors.systemGrey,
            isDark: isDark,
          ),
          const SizedBox(height: 10),
          _StatCard(
            label: 'Voortgang',
            value: '$pctInt%',
            color: pct >= 1.0
                ? CupertinoColors.systemGreen
                : const Color(0xFFFF6B2B),
            isDark: isDark,
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isDark;
  final VoidCallback onTap;

  const _ActionCard({
    required this.label,
    required this.icon,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF1C1C1E) : CupertinoColors.systemBackground;
    final borderColor = isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: const Color(0xFFFF6B2B)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
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

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool isDark;

  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF1C1C1E) : CupertinoColors.systemBackground;
    final borderColor = isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 15)),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _RingChart extends StatelessWidget {
  final double bookedHours;
  final double contractHours;
  final double percentage;
  final bool isDark;

  const _RingChart({
    required this.bookedHours,
    required this.contractHours,
    required this.percentage,
    required this.isDark,
  });

  String _fmt(double h) =>
      h == h.truncateToDouble() ? h.toInt().toString() : h.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final pctInt = (percentage * 100).round();
    return SizedBox(
      width: 240,
      height: 240,
      child: CustomPaint(
        painter: _RingPainter(percentage: percentage, isDark: isDark),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$pctInt%',
                style: const TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '${_fmt(bookedHours)} / ${_fmt(contractHours)} uur',
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.systemGrey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double percentage;
  final bool isDark;

  const _RingPainter({required this.percentage, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 20;
    const strokeWidth = 22.0;

    final bgPaint = Paint()
      ..color = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    if (percentage > 0) {
      final fgPaint = Paint()
        ..color = const Color(0xFFFF6B2B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * percentage,
        false,
        fgPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.percentage != percentage || old.isDark != isDark;
}
