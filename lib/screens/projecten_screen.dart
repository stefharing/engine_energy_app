import 'package:flutter/cupertino.dart';

import '../features/planning/data/planning_repository.dart';
import '../features/planning/models/job_order.dart' show ServiceOrder;
import '../features/planning/screens/bon_detail_screen.dart';
import '../widgets/engine_logo.dart';
import '../widgets/nav_border.dart';

// Simulated logged-in user — replace with real auth later.
const _currentUserName = 'Lex de Bruijn';

class ProjectenScreen extends StatefulWidget {
  const ProjectenScreen({super.key});

  @override
  State<ProjectenScreen> createState() => _ProjectenScreenState();
}

class _ProjectenScreenState extends State<ProjectenScreen> {
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
    await _fetch();
  }

  Future<void> _refresh() async {
    await _fetch();
  }

  Future<void> _fetch() async {
    try {
      final orders = await PlanningRepository.instance.fetchServiceOrders();
      final myId = orders
          .firstWhere(
            (o) =>
                o.mechanic?.name.toLowerCase() ==
                _currentUserName.toLowerCase(),
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
          return ad.compareTo(bd);
        });
      final ordersWithRelations = await _loadRelationNames(myOrders);
      setState(() {
        _orders = ordersWithRelations;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<List<ServiceOrder>> _loadRelationNames(List<ServiceOrder> orders) {
    return Future.wait(
      orders.map((order) async {
        if (order.relationName.isNotEmpty || order.productionOrderId == null) {
          return order;
        }

        final productionOrder = await PlanningRepository.instance
            .fetchProductionOrder(order.productionOrderId!);
        final relationRef =
            productionOrder?['relation'] as Map<String, dynamic>?;
        final relationId = relationRef?['id']?.toString();
        if (relationId == null) return order;

        final relation = await PlanningRepository.instance.fetchRelation(
          relationId,
        );
        final name =
            relation?['name']?.toString() ??
            relationRef?['name']?.toString() ??
            relationRef?['recordtag']?.toString() ??
            '';
        return name.isEmpty ? order : order.copyWith(relationName: name);
      }),
    );
  }

  List<ServiceOrder> get _filtered {
    if (_query.isEmpty) return _orders;
    final q = _query.toLowerCase();
    return _orders.where((o) {
      return o.description.toLowerCase().contains(q) ||
          o.orderNumber.toLowerCase().contains(q) ||
          o.relationName.toLowerCase().contains(q) ||
          o.location.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      resizeToAvoidBottomInset: false,
      navigationBar: const CupertinoNavigationBar(
        backgroundColor: Color(0xFFFFFFFF),
        border: null,
        padding: EdgeInsetsDirectional.symmetric(horizontal: 20),
        middle: EngineLogo(),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const NavBorder(),
            Expanded(
              child: _loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : _error != null
                  ? _ErrorView(error: _error!, onRetry: _load)
                  : _Body(
                      orders: _filtered,
                      query: _query,
                      onQueryChanged: (v) => setState(() => _query = v),
                      onRefresh: _refresh,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Body ──────────────────────────────────────────────────────────────────────

class _Body extends StatelessWidget {
  final List<ServiceOrder> orders;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final Future<void> Function() onRefresh;

  const _Body({
    required this.orders,
    required this.query,
    required this.onQueryChanged,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final upcoming = orders.where((o) {
      final d = o.planningDate;
      return d != null && !DateTime(d.year, d.month, d.day).isBefore(today);
    }).toList();

    final past =
        orders.where((o) {
          final d = o.planningDate;
          return d == null || DateTime(d.year, d.month, d.day).isBefore(today);
        }).toList()..sort((a, b) {
          final ad = a.planningDate;
          final bd = b.planningDate;
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return bd.compareTo(ad);
        });

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        CupertinoSliverRefreshControl(onRefresh: onRefresh),

        // Title
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              'Bonnen',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
          ),
        ),

        // Search bar
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: CupertinoSearchTextField(
              placeholder: 'Zoeken',
              onChanged: onQueryChanged,
            ),
          ),
        ),

        if (orders.isEmpty)
          SliverFillRemaining(
            child: Center(
              child: Text(
                query.isEmpty ? 'Geen projecten gevonden' : 'Geen resultaten',
                style: const TextStyle(color: CupertinoColors.secondaryLabel),
              ),
            ),
          )
        else ...[
          if (upcoming.isNotEmpty) ...[
            _SectionHeader(title: 'Aankomend', count: upcoming.length),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => BonDetailScreen(order: upcoming[i]),
                    ),
                  ),
                  child: _OrderCard(order: upcoming[i]),
                ),
                childCount: upcoming.length,
              ),
            ),
          ],
          if (past.isNotEmpty) ...[
            _SectionHeader(title: 'Afgelopen', count: past.length),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => BonDetailScreen(order: past[i]),
                    ),
                  ),
                  child: _OrderCard(order: past[i]),
                ),
                childCount: past.length,
              ),
            ),
          ],
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

// ─── Section header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;

  const _SectionHeader({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          children: [
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.secondaryLabel,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: CupertinoColors.secondaryLabel.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Order card ────────────────────────────────────────────────────────────────

class _OrderCard extends StatelessWidget {
  final ServiceOrder order;

  const _OrderCard({required this.order});

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
    final title = order.description.isNotEmpty
        ? order.description
        : order.orderNumber;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title + date row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatDate(order.planningDate),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFFFF6B2B),
                  ),
                ),
              ],
            ),

            if (order.serviceObjectTag.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                order.serviceObjectTag,
                style: TextStyle(
                  fontSize: 14,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],

            if (order.relationName.isNotEmpty || order.orderNumber.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (order.relationName.isNotEmpty) ...[
                    Icon(
                      CupertinoIcons.person_2,
                      size: 13,
                      color: CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        order.relationName,
                        style: TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ] else
                    const Spacer(),
                  if (order.orderNumber.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Text(
                      order.orderNumber,
                      style: TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.tertiaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
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
