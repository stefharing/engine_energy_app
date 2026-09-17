import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/api/api_client.dart';
import '../data/hours_draft_service.dart';
import '../data/planning_repository.dart';
import '../data/signature_draft_service.dart';
import '../models/job_order.dart';
import '../models/service_interval.dart';
import 'declarations_screen.dart';
import 'extra_materials_screen.dart';
import 'hours_week_screen.dart';
import 'parts_list_screen.dart';
import 'signature_pad_screen.dart';
import 'work_completion_screen.dart' show WorkCompletionScreen, bonCompletedKey;
import 'work_report_screen.dart';

// ─── Screen ────────────────────────────────────────────────────────────────────

class BonDetailScreen extends StatefulWidget {
  final ServiceOrder order;
  const BonDetailScreen({super.key, required this.order});

  @override
  State<BonDetailScreen> createState() => _BonDetailScreenState();
}

class _BonDetailScreenState extends State<BonDetailScreen> {
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

  List<Map<String, dynamic>> _parts = [];
  Set<String> _takenIds = {};
  int _extraCount = 0;
  bool _partsConfirmed = false;

  Map<String, dynamic>? _address;
  String? _contactName;
  String? _contactPhone;

  bool _loading = true;
  String? _error;
  bool _showNavTitle = false;
  final _scrollCtrl = ScrollController();

  String? _bannerText;
  Timer? _bannerTimer;

  Uint8List? _signatureBytes;
  bool _isCompleted = false;

  ServiceOrder get _order => widget.order;
  int get _aantalOpenPick =>
      _parts.where((p) => !_takenIds.contains(p['id'].toString())).length;

  /// Total hours in this bon's local draft (see [HoursDraftService]) —
  /// every card entered via "Uren & km".
  double _totalUrenGeregistreerd = 0;

  @override
  void initState() {
    super.initState();
    _load();
    // Toon navbar-titel zodra de grote titel voorbij scrolt (~20px padding + ~33px tekst)
    _scrollCtrl.addListener(() {
      final show = _scrollCtrl.offset > 53;
      if (show != _showNavTitle) setState(() => _showNavTitle = show);
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _bannerTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool showLoading = true}) async {
    setState(() {
      if (showLoading) _loading = true;
      _error = null;
    });
    try {
      await Future.wait([
        _loadParts(),
        _loadAddress(),
        _loadContact(),
        _loadHours(),
        _loadSignature(),
        _loadCompleted(),
      ]);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Pull-to-refresh: reloads everything (parts, address, contact) without
  /// swapping the screen to the full-page spinner — in particular this is
  /// how the "Uren & km" hours count picks up hours registered elsewhere
  /// (e.g. via "Werk afronden") without leaving and re-opening this screen.
  Future<void> _onRefresh() => _load(showLoading: false);

  Future<void> _loadParts() async {
    final resp = await ApiClient.instance.dio.get(
      '/production/joborderdetails',
      queryParameters: {
        'page': 1,
        'size': 200,
        'filter': 'joborder.id[eq]${_order.id}',
      },
    );
    final all = (resp.data['data'] as List).cast<Map<String, dynamic>>();
    final parts = all.where((e) => e['joborderdetailitem'] != null).toList();

    final prefs = await SharedPreferences.getInstance();
    final taken = <String>{};
    for (final p in parts) {
      if (prefs.getBool('part_taken_${_order.id}_${p['id']}') ?? false) {
        taken.add(p['id'].toString());
      }
    }
    // Same key ExtraMaterialsScreen and PartsListScreen persist extras
    // under — this used to read a different, never-written key, so the
    // "Extra materiaal" task always showed a count of 0.
    final extrasRaw = prefs.getString('extra_scanned_${_order.id}') ?? '[]';
    final extrasCount = (jsonDecode(extrasRaw) as List).length;
    final confirmed = prefs.getBool('parts_confirmed_${_order.id}') ?? false;

    if (mounted)
      setState(() {
        _parts = parts;
        _takenIds = taken;
        _extraCount = extrasCount;
        _partsConfirmed = confirmed;
      });
  }

  Future<void> _loadHours() async {
    final total = await HoursDraftService.instance.localTotalHours(_order.id);
    if (mounted) setState(() => _totalUrenGeregistreerd = total);
  }

  Future<void> _loadSignature() async {
    final bytes = await SignatureDraftService.instance.load(_order.id);
    if (mounted) setState(() => _signatureBytes = bytes);
  }

  Future<void> _loadCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    final completed = prefs.getBool(bonCompletedKey(_order.id)) ?? false;
    if (mounted) setState(() => _isCompleted = completed);
  }

  Future<void> _loadAddress() async {
    final id = _order.serviceObjectId;
    if (id == null) return;
    final obj = await PlanningRepository.instance.fetchServiceObject(id);
    if (obj == null) return;
    final locId = (obj['objectlocation'] as Map<String, dynamic>?)?['id']
        ?.toString();
    if (locId == null) return;
    final del = await PlanningRepository.instance.fetchDeliveryAddress(locId);
    final addrId = (del?['address'] as Map<String, dynamic>?)?['id']
        ?.toString();
    if (addrId == null) return;
    final addr = await PlanningRepository.instance.fetchAddress(addrId);
    if (addr != null && mounted) setState(() => _address = addr);
  }

  Future<void> _loadContact() async {
    final orderId = _order.productionOrderId;
    if (orderId == null) return;
    final prod = await PlanningRepository.instance.fetchProductionOrder(
      orderId,
    );
    if (prod == null || !mounted) return;
    final ref = prod['contact'] as Map<String, dynamic>?;
    if (ref == null) return;
    final name = ref['recordtag']?.toString() ?? '';
    final cId = ref['id']?.toString();
    String phone = '';
    if (cId != null) {
      final c = await PlanningRepository.instance.fetchContact(cId);
      if (c != null) {
        phone =
            c['phone']?.toString() ??
            c['mobile']?.toString() ??
            c['phone1']?.toString() ??
            c['mobilephone']?.toString() ??
            '';
      }
    }
    if (!mounted) return;
    setState(() {
      _contactName = name.isNotEmpty ? name : null;
      _contactPhone = phone.isNotEmpty ? phone : null;
    });
  }

  String _fmtDate(DateTime? d) {
    if (d == null) return '—';
    return '${d.day} ${_months[d.month]} ${d.year}';
  }

  String _fmtAddr(Map<String, dynamic> a) {
    final line1 = '${a['street'] ?? ''} ${a['housenumber'] ?? ''}'.trim();
    final line2 = '${a['zipcode'] ?? ''} ${a['city'] ?? ''}'.trim();
    return [line1, line2].where((s) => s.isNotEmpty).join(', ');
  }

  Future<void> _openMaps() async {
    final addr = _address != null ? _fmtAddr(_address!) : _order.location;
    final q = Uri.encodeComponent(addr);
    final opts = <(String, Uri)>[];
    if (await canLaunchUrl(Uri.parse('maps://')))
      opts.add(('Apple Maps', Uri.parse('maps://?q=$q')));
    if (await canLaunchUrl(Uri.parse('comgooglemaps://')))
      opts.add(('Google Maps', Uri.parse('comgooglemaps://?q=$q')));
    if (await canLaunchUrl(Uri.parse('waze://')))
      opts.add(('Waze', Uri.parse('waze://?q=$q')));
    if (opts.length == 1) {
      await launchUrl(opts.first.$2);
      return;
    }
    if (!mounted) return;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Navigeer naar locatie'),
        message: Text(addr),
        actions: [
          for (final (n, u) in opts)
            CupertinoActionSheetAction(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await launchUrl(u);
              },
              child: Text(n),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
  }

  Future<void> _callContact() async {
    final p = _contactPhone;
    if (p == null) return;
    final uri = Uri.parse('tel:${p.replaceAll(' ', '')}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _push(
    Widget screen, {
    bool refreshParts = false,
    bool refreshHours = false,
  }) async {
    await Navigator.of(
      context,
    ).push(CupertinoPageRoute<void>(builder: (_) => screen));
    if (refreshParts && mounted) _loadParts();
    if (refreshHours && mounted) _loadHours();
  }

  Future<void> _openHoursWeek() async {
    final saved = await Navigator.of(context).push<bool>(
      CupertinoPageRoute<bool>(
        builder: (_) => HoursWeekScreen(initialOrder: _order),
      ),
    );
    if (!mounted) return;
    await _loadHours();
    if (saved == true && mounted) _showBanner('Uren opgeslagen');
  }

  Future<void> _openSignaturePad() async {
    final bytes = await Navigator.of(context).push<Uint8List>(
      CupertinoPageRoute<Uint8List>(
        builder: (_) => SignaturePadScreen(initialSignature: _signatureBytes),
      ),
    );
    if (bytes == null || !mounted) return;
    await SignatureDraftService.instance.save(_order.id, bytes);
    if (!mounted) return;
    setState(() => _signatureBytes = bytes);
    _showBanner('Handtekening opgeslagen');
  }

  void _showBanner(String text) {
    _bannerTimer?.cancel();
    setState(() => _bannerText = text);
    _bannerTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _bannerText = null);
    });
  }

  /// Opens the "Werk afronden" summary screen, which publishes this bon's
  /// locally-saved hours to Ridder in one go.
  Future<void> _openWorkCompletion() async {
    final published = await Navigator.of(context).push<bool>(
      CupertinoPageRoute<bool>(
        builder: (_) => WorkCompletionScreen(
          order: _order,
          totalUrenGeregistreerd: _totalUrenGeregistreerd,
          signatureBytes: _signatureBytes,
        ),
      ),
    );
    if (!mounted) return;
    // The bon is finished — bubble the result up to the job order list
    // instead of staying here, so it can show its own confirmation and
    // mark this bon as completed.
    if (published == true) {
      Navigator.of(context).pop(true);
      return;
    }
    _loadHours();
  }

  void _showComingSoon(String feature) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Komt binnenkort'),
        content: Text('$feature is beschikbaar in een volgende versie.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final border = isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
    final order = _order;
    final title = order.description.isNotEmpty
        ? order.description
        : order.orderNumber;
    final subtitle = [
      order.serviceObjectTag,
      order.location,
    ].where((s) => s.isNotEmpty).join('  ·  ');
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
          child: Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: CupertinoColors.black,
            ),
          ),
        ),
      ),
      child: Stack(
        children: [
          CustomScrollView(
            controller: _scrollCtrl,
            slivers: [
              CupertinoSliverRefreshControl(onRefresh: _onRefresh),
              if (_loading)
                const SliverFillRemaining(
                  child: Center(child: CupertinoActivityIndicator()),
                )
              else if (_error != null)
                SliverFillRemaining(
                  child: _ErrorView(error: _error!, onRetry: _load),
                )
              else ...[
                // ── Titel + info blok (witte achtergrond) ────────────────
                SliverToBoxAdapter(
                  child: Container(
                    color: isDark
                        ? const Color(0xFF1C1C1E)
                        : CupertinoColors.systemBackground,
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (order.orderNumber.isNotEmpty)
                          Text(
                            'Bon ${order.orderNumber}',
                            style: TextStyle(
                              fontSize: 15,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 15,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            _StatusBadge(state: order.workflowState),
                            const SizedBox(width: 10),
                            _DatePill(
                              startDate: order.startDate,
                              endDate: order.endTime,
                              fmtDate: _fmtDate,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SliverToBoxAdapter(child: SizedBox(height: 20)),

                // ── Waarschuwing ──────────────────────────────────────────
                if (_aantalOpenPick > 0 && !_partsConfirmed) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _WarningCard(
                        count: _aantalOpenPick,
                        onTap: () => _push(
                          PartsListScreen(order: order),
                          refreshParts: true,
                        ),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],

                // ── Taken ─────────────────────────────────────────────────
                SliverToBoxAdapter(child: _SectionLabel('Taken')),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _TaskGrid(
                      aantalOpenPick: _aantalOpenPick,
                      partsConfirmed: _partsConfirmed,
                      extraCount: _extraCount,
                      totalUrenGeregistreerd: _totalUrenGeregistreerd,
                      hasSignature: _signatureBytes != null,
                      isCompleted: _isCompleted,
                      onPick: () => _push(
                        PartsListScreen(order: order),
                        refreshParts: true,
                      ),
                      onUren: _openHoursWeek,
                      onExtra: () => _push(
                        ExtraMaterialsScreen(order: order),
                        refreshParts: true,
                      ),
                      onDeclaraties: () =>
                          _push(DeclarationsScreen(order: order)),
                      onRapport: () => _push(WorkReportScreen(order: order)),
                      onTekenen: _openSignaturePad,
                      onWerkAfronden: _openWorkCompletion,
                    ),
                  ),
                ),

                const SliverToBoxAdapter(child: SizedBox(height: 28)),

                // ── Klus ──────────────────────────────────────────────────
                SliverToBoxAdapter(child: _SectionLabel('Klus')),
                SliverToBoxAdapter(
                  child: _InfoCard(
                    bg: cardBg,
                    border: border,
                    children: [
                      if (order.mechanic != null)
                        _InfoRow(
                          icon: CupertinoIcons.person,
                          label: 'Monteur',
                          value: order.mechanic!.name,
                        ),
                      if (order.serviceType.isNotEmpty)
                        _InfoRow(
                          icon: CupertinoIcons.wrench,
                          label: 'Type service',
                          value: order.serviceType,
                        ),
                      if (order.orderNumber.isNotEmpty)
                        _InfoRow(
                          icon: CupertinoIcons.doc_text,
                          label: 'Ordernummer',
                          value: order.orderNumber,
                        ),
                    ],
                  ),
                ),

                // ── Object ────────────────────────────────────────────────
                if (order.serviceObjectId != null) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  SliverToBoxAdapter(child: _SectionLabel('Object')),
                  SliverToBoxAdapter(
                    child: _ObjectSection(
                      order: order,
                      cardBg: cardBg,
                      border: border,
                      onShowComingSoon: _showComingSoon,
                    ),
                  ),
                ],

                // ── Adres & contact ───────────────────────────────────────
                if (order.location.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  SliverToBoxAdapter(child: _SectionLabel('Adres & contact')),
                  SliverToBoxAdapter(
                    child: _InfoCard(
                      bg: cardBg,
                      border: border,
                      children: [
                        _NavRow(
                          icon: CupertinoIcons.map_pin_ellipse,
                          label: order.location,
                          subtitle: _address != null
                              ? _fmtAddr(_address!)
                              : null,
                          onTap: _openMaps,
                        ),
                        if (_contactName != null || _contactPhone != null)
                          _NavRow(
                            icon: CupertinoIcons.phone,
                            label: _contactName ?? _contactPhone!,
                            subtitle: _contactPhone,
                            onTap: _callContact,
                          ),
                      ],
                    ),
                  ),
                ],

                const SliverToBoxAdapter(child: SizedBox(height: 48)),
              ],
            ],
          ),
          // Vaste hairline onder de navbar, onafhankelijk van scroll
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 0.5,
            child: Container(
              color: isDark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6),
            ),
          ),
          // Banner die kort verschijnt na het opslaan van uren of handtekening
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutBack,
            top: _bannerText != null ? 12 : -80,
            left: 16,
            right: 16,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _bannerText != null ? 1 : 0,
              child: _SavedBanner(text: _bannerText ?? ''),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Saved banner ──────────────────────────────────────────────────────────────

class _SavedBanner extends StatelessWidget {
  final String text;
  const _SavedBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF34C759),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.checkmark_alt_circle_fill,
            size: 18,
            color: CupertinoColors.white,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.white,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String state;
  const _StatusBadge({required this.state});

  Color _color() {
    final s = state.toLowerCase();
    if (s.contains('nieuw') || s.contains('new'))
      return const Color(0xFF64B5F6);
    if (s.contains('uitvoering') || s.contains('progress'))
      return const Color(0xFFFFCC02);
    if (s.contains('gereed') || s.contains('done') || s.contains('klaar'))
      return const Color(0xFF4CD964);
    if (s.contains('gepland') || s.contains('planned'))
      return const Color(0xFFCFB0F5);
    return const Color(0xFFCCCCCC);
  }

  @override
  Widget build(BuildContext context) {
    final c = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        state,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c),
      ),
    );
  }
}

// ─── Date pill ─────────────────────────────────────────────────────────────────

class _DatePill extends StatelessWidget {
  final DateTime? startDate;
  final DateTime? endDate;
  final String Function(DateTime?) fmtDate;

  const _DatePill({
    required this.startDate,
    required this.endDate,
    required this.fmtDate,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final bg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);
    final textColor = isDark
        ? CupertinoColors.label.resolveFrom(context)
        : const Color(0xFF3A3A3C);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.calendar, size: 12, color: textColor),
          const SizedBox(width: 5),
          Text(
            fmtDate(startDate),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          if (endDate != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Icon(
                CupertinoIcons.arrow_right,
                size: 9,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
            ),
            Text(
              fmtDate(endDate),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Warning card ──────────────────────────────────────────────────────────────

class _WarningCard extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _WarningCard({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          color: const Color(0xFFFF9500),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 16,
              color: Color(0xFFFFFFFF),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Actie vereist voor vertrek',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFFFFFFF),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$count ${count == 1 ? 'artikel' : 'artikelen'} klaarzetten en bevestigen voordat je vertrekt.',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              CupertinoIcons.chevron_right,
              size: 14,
              color: Color(0xCCFFFFFF),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Task list ─────────────────────────────────────────────────────────────────

String _fmtUren(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// Builds the seven [_TaskItem]s shown in [_TaskGrid].
List<_TaskItem> _buildTaskItems({
  required int aantalOpenPick,
  required bool partsConfirmed,
  required int extraCount,
  required double totalUrenGeregistreerd,
  required bool hasSignature,
  required bool isCompleted,
  required VoidCallback onPick,
  required VoidCallback onUren,
  required VoidCallback onExtra,
  required VoidCallback onDeclaraties,
  required VoidCallback onRapport,
  required VoidCallback onTekenen,
  required VoidCallback onWerkAfronden,
}) => [
  _TaskItem(
    iconBg: const Color(0xFFFFF4E0),
    icon: CupertinoIcons.cube_box,
    iconColor: const Color(0xFFFF9500),
    title: 'Artikelen picken',
    subtitle: partsConfirmed
        ? 'Bevestigd'
        : aantalOpenPick > 0
        ? '$aantalOpenPick nog te bevestigen'
        : 'Alles bevestigd',
    badge: partsConfirmed ? null : (aantalOpenPick > 0 ? aantalOpenPick : null),
    done: partsConfirmed || aantalOpenPick == 0,
    locked: false,
    onTap: onPick,
  ),
  _TaskItem(
    iconBg: const Color(0xFFE6F9EC),
    icon: CupertinoIcons.timer,
    iconColor: const Color(0xFF34C759),
    title: 'Uren & km',
    subtitle: totalUrenGeregistreerd > 0
        ? '${_fmtUren(totalUrenGeregistreerd)}u geregistreerd'
        : 'Nog niets geregistreerd',
    done: totalUrenGeregistreerd > 0,
    locked: false,
    onTap: onUren,
  ),
  _TaskItem(
    iconBg: const Color(0xFFE3F0FF),
    icon: CupertinoIcons.add_circled,
    iconColor: const Color(0xFF007AFF),
    title: 'Extra materiaal',
    subtitle: 'Nog niet beschikbaar',
    done: false,
    locked: true,
    onTap: null,
  ),
  _TaskItem(
    iconBg: const Color(0xFFE8EBF5),
    icon: CupertinoIcons.doc_text,
    iconColor: const Color(0xFF2C3E6B),
    title: 'Kosten & bonnen',
    subtitle: 'Nog niet beschikbaar',
    done: false,
    locked: true,
    onTap: null,
  ),
  _TaskItem(
    iconBg: const Color(0xFFEDE8F5),
    icon: CupertinoIcons.pencil_outline,
    iconColor: const Color(0xFF5856D6),
    title: 'Rapport schrijven',
    subtitle: 'Nog niet beschikbaar',
    done: false,
    locked: true,
    onTap: null,
  ),
  _TaskItem(
    iconBg: const Color(0xFFE6F9EC),
    icon: CupertinoIcons.signature,
    iconColor: const Color(0xFF34C759),
    title: 'Klant laten tekenen',
    subtitle: hasSignature
        ? 'Handtekening vastgelegd'
        : totalUrenGeregistreerd > 0
        ? 'Tik om handtekening te verzamelen'
        : 'Beschikbaar zodra uren zijn ingevuld',
    done: hasSignature,
    locked: totalUrenGeregistreerd == 0,
    onTap: totalUrenGeregistreerd > 0 ? onTekenen : null,
  ),
  _TaskItem(
    iconBg: const Color(0xFFFFE9DE),
    icon: CupertinoIcons.flag,
    iconColor: const Color(0xFFFF6B2B),
    title: 'Werk afronden',
    subtitle: isCompleted
        ? 'Gepubliceerd'
        : totalUrenGeregistreerd > 0 && hasSignature
        ? 'Bekijk de samenvatting en publiceer de uren'
        : 'Beschikbaar zodra uren en handtekening zijn ingevuld',
    done: isCompleted,
    locked: !isCompleted && (totalUrenGeregistreerd == 0 || !hasSignature),
    onTap: isCompleted || (totalUrenGeregistreerd > 0 && hasSignature)
        ? onWerkAfronden
        : null,
  ),
];

class _TaskGrid extends StatelessWidget {
  final int aantalOpenPick;
  final bool partsConfirmed;
  final int extraCount;
  final double totalUrenGeregistreerd;
  final bool hasSignature;
  final bool isCompleted;
  final VoidCallback onPick;
  final VoidCallback onUren;
  final VoidCallback onExtra;
  final VoidCallback onDeclaraties;
  final VoidCallback onRapport;
  final VoidCallback onTekenen;
  final VoidCallback onWerkAfronden;

  const _TaskGrid({
    required this.aantalOpenPick,
    required this.partsConfirmed,
    required this.extraCount,
    required this.totalUrenGeregistreerd,
    required this.hasSignature,
    required this.isCompleted,
    required this.onPick,
    required this.onUren,
    required this.onExtra,
    required this.onDeclaraties,
    required this.onRapport,
    required this.onTekenen,
    required this.onWerkAfronden,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final bg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final divider = isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);

    final items = _buildTaskItems(
      aantalOpenPick: aantalOpenPick,
      partsConfirmed: partsConfirmed,
      extraCount: extraCount,
      totalUrenGeregistreerd: totalUrenGeregistreerd,
      hasSignature: hasSignature,
      isCompleted: isCompleted,
      onPick: onPick,
      onUren: onUren,
      onExtra: onExtra,
      onDeclaraties: onDeclaraties,
      onRapport: onRapport,
      onTekenen: onTekenen,
      onWerkAfronden: onWerkAfronden,
    );

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: divider),
      ),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) Container(height: 0.5, color: divider),
            items[i],
          ],
        ],
      ),
    );
  }
}

// ─── Task item ─────────────────────────────────────────────────────────────────

class _TaskItem extends StatelessWidget {
  final Color iconBg;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final int? badge;
  final bool done;
  final bool locked;
  final VoidCallback? onTap;

  const _TaskItem({
    required this.iconBg,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.done,
    required this.locked,
    this.badge,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final lockedIconBg = isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFEEEEEE);

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: locked ? lockedIconBg : iconBg,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              icon,
              size: 18,
              color: locked ? const Color(0xFFAAAAAA) : iconColor,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: locked
                        ? CupertinoColors.secondaryLabel.resolveFrom(context)
                        : CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: locked
                        ? CupertinoColors.tertiaryLabel.resolveFrom(context)
                        : CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.elasticOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: badge != null
                ? Container(
                    key: const ValueKey('badge'),
                    constraints: const BoxConstraints(minWidth: 22),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF9500),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(
                      '$badge',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFFFFFF),
                      ),
                    ),
                  )
                : done
                ? Container(
                    key: const ValueKey('done'),
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: Color(0xFF34C759),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      CupertinoIcons.checkmark,
                      size: 11,
                      color: Color(0xFFFFFFFF),
                    ),
                  )
                : locked
                ? const Icon(
                    CupertinoIcons.lock,
                    key: ValueKey('locked'),
                    size: 14,
                    color: Color(0xFFAAAAAA),
                  )
                : Icon(
                    CupertinoIcons.chevron_right,
                    key: const ValueKey('chevron'),
                    size: 14,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
          ),
        ],
      ),
    );

    if (locked) return Opacity(opacity: 0.5, child: row);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: row,
    );
  }
}

// ─── Info card ─────────────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  final Color bg;
  final Color border;
  final List<Widget> children;

  const _InfoCard({
    required this.bg,
    required this.border,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: Container(height: 0.5, color: border),
              ),
          ],
        ],
      ),
    );
  }
}

// ─── Info row ──────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Nav row ───────────────────────────────────────────────────────────────────

class _NavRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _NavRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 20,
          vertical: subtitle != null ? 14 : 13,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: subtitle != null
                          ? FontWeight.w500
                          : FontWeight.w400,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
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

// ─── Object section ──────────────────────────────────────────────────────────

/// The "Object" card on the bon detail screen — the service object (e.g. a
/// motor or ketel) linked to this klus. The header renders instantly from
/// data already present on [order] (no extra call); the rest of the card
/// (objectnr/serienr, locatie, garantie) comes from a single
/// `/service/serviceobjects/{id}` call fired in [initState], so it only
/// happens once this section is actually being rendered — not for every
/// order in a list. "Volgend onderhoud" and the document count are lazier
/// still: fetched after the first frame, so they never hold up this
/// section's own initial paint either.
class _ObjectSection extends StatefulWidget {
  final ServiceOrder order;
  final Color cardBg;
  final Color border;
  final ValueChanged<String> onShowComingSoon;

  const _ObjectSection({
    required this.order,
    required this.cardBg,
    required this.border,
    required this.onShowComingSoon,
  });

  @override
  State<_ObjectSection> createState() => _ObjectSectionState();
}

class _ObjectSectionState extends State<_ObjectSection> {
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

  Map<String, dynamic>? _detail;
  bool _detailLoading = true;

  List<Map<String, dynamic>>? _intervals;
  int? _documentCount;

  @override
  void initState() {
    super.initState();
    _loadDetail();
    // Deferred to after the first frame is painted, so these two calls
    // fire once this section is actually visible rather than as part of
    // the screen's initial load.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLazyExtras());
  }

  Future<void> _loadDetail() async {
    final detail = await PlanningRepository.instance.fetchServiceObject(
      widget.order.serviceObjectId!,
    );
    if (mounted) {
      setState(() {
        _detail = detail;
        _detailLoading = false;
      });
    }
  }

  Future<void> _loadLazyExtras() async {
    final id = widget.order.serviceObjectId!;
    final results = await Future.wait([
      PlanningRepository.instance.fetchServiceIntervals(id),
      PlanningRepository.instance.fetchServiceObjectDocumentCount(id),
    ]);
    if (!mounted) return;
    setState(() {
      _intervals = results[0] as List<Map<String, dynamic>>;
      _documentCount = results[1] as int?;
    });
  }

  String _fmtDate(DateTime? d) {
    if (d == null) return '—';
    return '${d.day} ${_months[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final detail = _detail;
    final title = order.serviceObjectDescription.isNotEmpty
        ? order.serviceObjectDescription
        : order.serviceObjectTag;

    final objectNumber = detail?['objectnumber']?.toString() ?? '';
    final serialNumber = detail?['serialnumber']?.toString() ?? '';
    final subtitle = [
      if (objectNumber.isNotEmpty) 'Objectnr. $objectNumber',
      if (serialNumber.isNotEmpty) 'Serienr. $serialNumber',
    ].join(' · ');

    final objectLocationJson =
        detail?['objectlocation'] as Map<String, dynamic>?;
    final objectLocationName =
        objectLocationJson?['name'] as String? ??
        objectLocationJson?['code'] as String? ??
        '';
    final showLocation =
        objectLocationName.trim().isNotEmpty &&
        objectLocationName.trim().toLowerCase() !=
            order.location.trim().toLowerCase();

    final warrantyDate = parseServiceApiDate(detail?['ourwarrantydate']);
    final nextMaintenance = _intervals != null
        ? nextMaintenanceDateFrom(_intervals!)
        : null;

    return _InfoCard(
      bg: widget.cardBg,
      border: widget.border,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (_detailLoading) ...[
                const SizedBox(width: 10),
                const CupertinoActivityIndicator(radius: 8),
              ],
            ],
          ),
        ),
        if (showLocation)
          _InfoRow(
            icon: CupertinoIcons.location,
            label: 'Locatie',
            value: objectLocationName,
          ),
        if (warrantyDate != null)
          _InfoRow(
            icon: CupertinoIcons.shield,
            label: 'Garantie',
            value: 'tot ${_fmtDate(warrantyDate)}',
          ),
        if (nextMaintenance != null)
          _InfoRow(
            icon: CupertinoIcons.wrench_fill,
            label: 'Volgend onderhoud',
            value: _fmtDate(nextMaintenance),
          ),
        if (_documentCount != null)
          _NavRow(
            icon: CupertinoIcons.doc_on_doc,
            label: _documentCount == 1
                ? '1 document'
                : '$_documentCount documenten',
            onTap: () => widget.onShowComingSoon('Documenten'),
          ),
        _NavRow(
          icon: CupertinoIcons.clock,
          label: 'Bekijk servicehistorie',
          onTap: () => widget.onShowComingSoon('Servicehistorie'),
        ),
      ],
    );
  }
}

// ─── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String title;
  const _SectionLabel(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
    );
  }
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
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 44,
              color: CupertinoColors.systemRed,
            ),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            CupertinoButton(
              onPressed: onRetry,
              child: const Text('Opnieuw proberen'),
            ),
          ],
        ),
      ),
    );
  }
}
