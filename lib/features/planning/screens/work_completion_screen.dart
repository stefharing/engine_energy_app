import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/hours_draft_service.dart';
import '../models/job_order.dart';
import '../widgets/summary_row.dart';
import 'hours_week_screen.dart' show describeHoursSubmitError;

/// Same key [BonDetailScreen] and the planning Gantt view read to show the
/// job order as completed — set here once the publish call succeeds.
String bonCompletedKey(String orderId) => 'bon_completed_$orderId';

// The dashboard's accent orange, reused here for the publish button so it
// matches the rest of the app instead of Cupertino's default blue.
const _accentOrange = Color(0xFFFF6B2B);

/// The last step in a bon's workflow, opened from the "Werk afronden" task
/// in [BonDetailScreen] — only reachable once hours are registered and the
/// customer has signed. Shows a summary of the job (including a per-day
/// hours breakdown with memos and a thumbnail of the captured signature)
/// plus a button that publishes the bon's locally-saved hours and materials
/// to Ridder in one job-order registration — see [HoursDraftService].
class WorkCompletionScreen extends StatefulWidget {
  final ServiceOrder order;
  final double totalUrenGeregistreerd;
  final Uint8List? signatureBytes;

  const WorkCompletionScreen({
    super.key,
    required this.order,
    required this.totalUrenGeregistreerd,
    this.signatureBytes,
  });

  @override
  State<WorkCompletionScreen> createState() => _WorkCompletionScreenState();
}

const _dayNames = ['', 'Ma', 'Di', 'Wo', 'Do', 'Vr', 'Za', 'Zo'];
const _monthNames = [
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

String _fmtDay(DateTime d) =>
    '${_dayNames[d.weekday]} ${d.day} ${_monthNames[d.month]}';

class _WorkCompletionScreenState extends State<WorkCompletionScreen> {
  bool _publishing = false;
  bool _published = false;
  String? _error;

  List<HoursDayBreakdown> _dailyBreakdown = [];

  @override
  void initState() {
    super.initState();
    _loadBreakdown();
  }

  Future<void> _loadBreakdown() async {
    final breakdown = await HoursDraftService.instance.localDailyBreakdown(
      widget.order.id,
    );
    if (mounted) setState(() => _dailyBreakdown = breakdown);
  }

  Future<void> _publish() async {
    setState(() {
      _publishing = true;
      _error = null;
    });
    try {
      await HoursDraftService.instance.submitPendingHours(widget.order);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(bonCompletedKey(widget.order.id), true);
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _published = true;
      });
      // Let the checkmark flash briefly before bubbling back up to the
      // job order list, instead of leaving the user stranded on a screen
      // for a bon that's now finished.
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _error = describeHoursSubmitError(e);
      });
    }
  }

  String _fmtUren(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final order = widget.order;
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final border = isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
    final title = order.description.isNotEmpty
        ? order.description
        : order.orderNumber;

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.white,
        border: null,
        middle: const Text(
          'Werk afronden',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: CupertinoColors.black,
          ),
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (order.orderNumber.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Bon ${order.orderNumber}',
                  style: TextStyle(
                    fontSize: 15,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: border),
                ),
                child: Column(
                  children: [
                    SummaryRow(
                      icon: CupertinoIcons.wrench,
                      label: 'Type service',
                      value: order.serviceType.isNotEmpty
                          ? order.serviceType
                          : '—',
                    ),
                    Container(height: 0.5, color: border),
                    SummaryRow(
                      icon: CupertinoIcons.location,
                      label: 'Locatie',
                      value: order.location.isNotEmpty ? order.location : '—',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // ── Uren-breakdown, per dag ─────────────────────────────────
              Text(
                'UREN GEREGISTREERD'.toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: border),
                  ),
                  child: _dailyBreakdown.isEmpty
                      ? SummaryRow(
                          icon: CupertinoIcons.timer,
                          label: 'Totaal',
                          value: '${_fmtUren(widget.totalUrenGeregistreerd)}u',
                        )
                      : Column(
                          children: [
                            for (final day in _dailyBreakdown) ...[
                              _DayHeaderRow(
                                date: day.date,
                                value: '${_fmtUren(day.totalMinutes / 60)}u',
                              ),
                              for (final card in day.cards)
                                _HourEntryRow(
                                  icon: card.label == 'Reistijd'
                                      ? CupertinoIcons.car_fill
                                      : CupertinoIcons.hammer_fill,
                                  label: card.label,
                                  memo: card.memo,
                                  value: '${_fmtUren(card.hours)}u',
                                ),
                            ],
                            Container(height: 0.5, color: border),
                            SummaryRow(
                              icon: CupertinoIcons.timer,
                              label: 'Totaal',
                              value:
                                  '${_fmtUren(widget.totalUrenGeregistreerd)}u',
                            ),
                          ],
                        ),
                ),
              ),
              // ── Handtekening ───────────────────────────────────────────
              if (widget.signatureBytes != null) ...[
                const SizedBox(height: 20),
                Text(
                  'HANDTEKENING KLANT'.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 120,
                  decoration: BoxDecoration(
                    color: CupertinoColors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: border),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Image.memory(
                      widget.signatureBytes!,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: CupertinoColors.destructiveRed,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (_published) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(
                      CupertinoIcons.checkmark_alt_circle_fill,
                      color: Color(0xFF34C759),
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Werk gepubliceerd',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF34C759),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 14),
                color: _accentOrange,
                borderRadius: BorderRadius.circular(14),
                onPressed: _publishing ? null : _publish,
                child: _publishing
                    ? const CupertinoActivityIndicator(
                        color: CupertinoColors.white,
                      )
                    : const Text(
                        'Werk publiceren',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.white,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Day header row ─────────────────────────────────────────────────────────

/// A compact sub-header inside the (single) hours card, separating one
/// day's [_HourEntryRow]s from the next.
class _DayHeaderRow extends StatelessWidget {
  final DateTime date;
  final String value;

  const _DayHeaderRow({required this.date, required this.value});

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return Container(
      color: isDark ? const Color(0xFF232324) : const Color(0xFFF7F7F9),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _fmtDay(date),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Hour entry row ─────────────────────────────────────────────────────────

/// Like [SummaryRow], but with room for the memo entered alongside an hour
/// card (if any) — folded into a single compact line with the label instead
/// of a whole second row, so a day's worth of cards stays scannable.
class _HourEntryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? memo;
  final String value;

  const _HourEntryRow({
    required this.icon,
    required this.label,
    required this.memo,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: 15,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: label,
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
                children: [
                  if (memo != null)
                    TextSpan(
                      text: '  ·  $memo',
                      style: TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.tertiaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}
