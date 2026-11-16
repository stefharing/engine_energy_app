import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/auth/auth_service.dart';
import '../features/planning/data/planning_repository.dart';
import '../features/planning/models/job_order.dart'
    show ServiceOrder, ServicePerson;
import '../features/planning/screens/bon_detail_screen.dart';
import '../features/planning/screens/work_completion_screen.dart'
    show bonCompletedKey;
import '../widgets/engine_logo.dart';
import '../widgets/nav_border.dart';
import '../core/theme/app_colors.dart';

class ProjectenScreen extends StatefulWidget {
  const ProjectenScreen({super.key});

  @override
  State<ProjectenScreen> createState() => _ProjectenScreenState();
}

class _ProjectenScreenState extends State<ProjectenScreen> {
  List<ServiceOrder> _orders = [];
  String _query = '';

  /// Alleen voor medewerkers die alle bonnen mogen zien: false = alleen mijn
  /// eigen bonnen tonen.
  bool _alleBonnen = true;
  bool _loading = true;
  String? _error;

  Set<String> _completedIds = {};
  bool _showCompletedBanner = false;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadCompletedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = <String>{
      for (final o in _orders)
        if (prefs.getBool(bonCompletedKey(o.id)) ?? false) o.id,
    };
    if (mounted) setState(() => _completedIds = ids);
  }

  Future<void> _openBon(ServiceOrder order) async {
    final published = await Navigator.of(context).push<bool>(
      CupertinoPageRoute<bool>(builder: (_) => BonDetailScreen(order: order)),
    );
    if (published != true || !mounted) return;
    setState(() => _completedIds = {..._completedIds, order.id});
    _bannerTimer?.cancel();
    setState(() => _showCompletedBanner = true);
    _bannerTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showCompletedBanner = false);
    });
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
      final myId = AuthService.instance.currentMechanicId;
      if (myId == null) {
        setState(() {
          _error = 'Je bent niet ingelogd.';
          _loading = false;
        });
        return;
      }
      final orders = await PlanningRepository.instance.fetchServiceOrders();
      // Wim en Jos krijgen alle bonnen; iedereen anders alleen de eigen.
      final zichtbaar = AuthService.instance.seesAllBonnen
          ? orders
          : orders.where((o) => o.isAssignedTo(myId)).toList();
      final myOrders = zichtbaar.toList()
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
      _loadCompletedIds();
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
    final myId = AuthService.instance.currentMechanicId;
    final basis =
        AuthService.instance.seesAllBonnen || myId == null
        ? (_alleBonnen || myId == null
              ? _orders
              : _orders.where((o) => o.isAssignedTo(myId)).toList())
        : _orders;
    if (_query.isEmpty) return basis;
    final q = _query.toLowerCase();
    return basis.where((o) {
      return o.description.toLowerCase().contains(q) ||
          o.orderNumber.toLowerCase().contains(q) ||
          o.relationName.toLowerCase().contains(q) ||
          o.location.toLowerCase().contains(q) ||
          o.assignedMechanics.any((m) => m.name.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.page,
      resizeToAvoidBottomInset: false,
      navigationBar: const CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        padding: EdgeInsetsDirectional.symmetric(horizontal: 20),
        middle: EngineLogo(),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Column(
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
                          toonAlleSchakelaar: AuthService.instance.seesAllBonnen,
                          alleBonnen: _alleBonnen,
                          onAlleBonnen: (v) => setState(() => _alleBonnen = v),
                          completedIds: _completedIds,
                          onQueryChanged: (v) => setState(() => _query = v),
                          onRefresh: _refresh,
                          onOpenBon: _openBon,
                        ),
                ),
              ],
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
              top: _showCompletedBanner ? 12 : -80,
              left: 16,
              right: 16,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _showCompletedBanner ? 1 : 0,
                child: const _CompletedBanner(text: 'Werk gepubliceerd'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Completed banner ──────────────────────────────────────────────────────────

class _CompletedBanner extends StatelessWidget {
  final String text;
  const _CompletedBanner({required this.text});

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

// ─── Body ──────────────────────────────────────────────────────────────────────

class _Body extends StatelessWidget {
  final List<ServiceOrder> orders;
  final String query;
  final bool toonAlleSchakelaar;
  final bool alleBonnen;
  final ValueChanged<bool> onAlleBonnen;
  final Set<String> completedIds;
  final ValueChanged<String> onQueryChanged;
  final Future<void> Function() onRefresh;
  final ValueChanged<ServiceOrder> onOpenBon;

  const _Body({
    required this.orders,
    required this.query,
    required this.toonAlleSchakelaar,
    required this.alleBonnen,
    required this.onAlleBonnen,
    required this.completedIds,
    required this.onQueryChanged,
    required this.onRefresh,
    required this.onOpenBon,
  });

  static const _dagAfk = ['ma', 'di', 'wo', 'do', 'vr', 'za', 'zo'];
  static const _maandAfk = [
    '', 'jan', 'feb', 'mrt', 'apr', 'mei', 'jun',
    'jul', 'aug', 'sep', 'okt', 'nov', 'dec',
  ];

  /// "Vandaag", "Morgen", "wo 2 okt" (binnen een week), anders "2 okt";
  /// in een ander jaar met het jaartal erbij.
  static String _dagLabel(DateTime? d, DateTime today) {
    if (d == null) return 'Geen datum';
    final verschil = DateTime(d.year, d.month, d.day).difference(today).inDays;
    if (verschil == 0) return 'Vandaag';
    if (verschil == 1) return 'Morgen';
    if (verschil == -1) return 'Gisteren';
    final datum = '${d.day} ${_maandAfk[d.month]}';
    final jaar = d.year != today.year ? ' ${d.year}' : '';
    if (verschil.abs() <= 6) {
      return '${_dagAfk[d.weekday - 1]} $datum$jaar';
    }
    return '$datum$jaar';
  }

  /// De bonnen gegroepeerd per startdag, met een daglabel boven elke groep.
  Widget _dagGroepen(
    List<ServiceOrder> bonnen,
    DateTime today, {
    required bool oplopend,
    required double eersteRuimte,
  }) {
    final groepen = <DateTime?, List<ServiceOrder>>{};
    for (final o in bonnen) {
      final d = o.planningDate;
      final dag = d == null ? null : DateTime(d.year, d.month, d.day);
      groepen.putIfAbsent(dag, () => []).add(o);
    }
    final dagen = groepen.keys.toList()
      ..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        return oplopend ? a.compareTo(b) : b.compareTo(a);
      });

    final rijen = <Widget>[];
    for (var g = 0; g < dagen.length; g++) {
      final dag = dagen[g];
      rijen.add(
        Builder(
          builder: (context) => Padding(
            padding: EdgeInsets.fromLTRB(20, g == 0 ? eersteRuimte : 10, 20, 6),
            child: Text(
              _dagLabel(dag, today),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _dagLabel(dag, today) == 'Vandaag'
                    ? const Color(0xFFFF6B2B)
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ),
        ),
      );
      for (final o in groepen[dag]!) {
        rijen.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _OrderCard(
              order: o,
              completed: completedIds.contains(o.id),
              onTap: () => onOpenBon(o),
            ),
          ),
        );
      }
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => rijen[i],
        childCount: rijen.length,
      ),
    );
  }

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

        if (toonAlleSchakelaar)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: CupertinoSlidingSegmentedControl<bool>(
                groupValue: alleBonnen,
                onValueChanged: (v) {
                  if (v != null) onAlleBonnen(v);
                },
                children: const {
                  true: Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Text('Alle bonnen', style: TextStyle(fontSize: 13)),
                  ),
                  false: Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Text('Mijn bonnen', style: TextStyle(fontSize: 13)),
                  ),
                },
              ),
            ),
          ),

        if (orders.isEmpty)
          SliverFillRemaining(
            child: Center(
              child: Text(
                query.isEmpty ? 'Geen projecten gevonden' : 'Geen resultaten',
                style: TextStyle(
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ),
          )
        else ...[
          if (upcoming.isNotEmpty) ...[
            _dagGroepen(upcoming, today, oplopend: true, eersteRuimte: 12),
          ],
          if (past.isNotEmpty) ...[
            _dagGroepen(past, today, oplopend: false, eersteRuimte: 20),
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
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: CupertinoColors.secondaryLabel
                    .resolveFrom(context)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
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

/// Kaart in de bonnenlijst (ontwerp 6c): de klant voorop, een type-icoon
/// links, het werk als titel, object- en bonnummer in één grijze regel, en
/// avatars van de monteurs rechts als er meerdere op de bon staan.
class _OrderCard extends StatefulWidget {
  final ServiceOrder order;
  final bool completed;
  final VoidCallback onTap;

  const _OrderCard({
    required this.order,
    required this.onTap,
    this.completed = false,
  });

  @override
  State<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<_OrderCard> {
  bool _ingedrukt = false;

  static const _accent = Color(0xFFFF6B2B);

  /// (achtergrond, iconkleur, icoon) op basis van het type van de bon.
  static (Color, Color, IconData) _typeIcoon(ServiceOrder o, bool geenOmschrijving) {
    final t = o.serviceType.toLowerCase();
    if (t.contains('storing')) {
      return (const Color(0xFFFFE5E5), const Color(0xFFD70015), CupertinoIcons.bolt_fill);
    }
    if (t.contains('lever')) {
      return (const Color(0xFFE6F9EC), const Color(0xFF248A3D), CupertinoIcons.cube_box);
    }
    if (geenOmschrijving) {
      return (const Color(0xFFF2F2F7), const Color(0x733C3C43), CupertinoIcons.doc_text);
    }
    return (const Color(0xFFFFE9DE), _accent, CupertinoIcons.wrench);
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final completed = widget.completed;
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    const completedColor = Color(0xFF34C759);

    final kaartKleur = completed
        ? completedColor.withValues(alpha: isDark ? 0.14 : 0.08)
        : isDark
        ? (_ingedrukt ? const Color(0xFF232324) : const Color(0xFF1C1C1E))
        : (_ingedrukt ? const Color(0xFFF7F7F9) : CupertinoColors.white);

    final omschrijving = order.description.trim();
    final geenOmschrijving = omschrijving.isEmpty || omschrijving == order.orderNumber;
    final (tegelBg, tegelFg, icoon) = _typeIcoon(order, geenOmschrijving);

    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final meta = [
      if (order.serviceObjectTag.isNotEmpty) order.serviceObjectTag,
      if (order.orderNumber.isNotEmpty) '#${order.orderNumber}',
    ].join(' · ');

    final ik = AuthService.instance.currentMechanicId;
    final monteurs = order.assignedMechanics;
    final ikStaatErop = monteurs.any((m) => m.id == ik);
    // Avatars: bij meerdere monteurs. Kijk ik naar een bon waar ik zelf niet
    // op sta (Wim/Jos), dan ook bij één monteur, met de namen eronder.
    final toonAvatars = monteurs.length > 1 || (!ikStaatErop && monteurs.isNotEmpty);
    final anderen = [
      for (final m in monteurs)
        if (m.id != ik && m.name.trim().isNotEmpty) m,
    ];
    final namenRegel = ikStaatErop || anderen.isEmpty
        ? null
        : anderen.map((m) => m.name.trim()).join(', ');

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _ingedrukt = true),
      onTapUp: (_) => setState(() => _ingedrukt = false),
      onTapCancel: () => setState(() => _ingedrukt = false),
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _ingedrukt ? 0.98 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kaartKleur,
            borderRadius: BorderRadius.circular(18),
            border: completed
                ? Border.all(color: completedColor.withValues(alpha: 0.4), width: 1.5)
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isDark ? tegelFg.withValues(alpha: 0.2) : tegelBg,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icoon, size: 20, color: tegelFg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (order.relationName.isNotEmpty)
                      Row(
                        children: [
                          if (completed) ...[
                            const Icon(
                              CupertinoIcons.checkmark_alt_circle_fill,
                              size: 13,
                              color: completedColor,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              order.relationName.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                                color: secundair,
                              ),
                            ),
                          ),
                        ],
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        geenOmschrijving ? 'Geen omschrijving' : omschrijving,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: geenOmschrijving
                              ? secundair
                              : CupertinoColors.label.resolveFrom(context),
                        ),
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? const Color(0x73EBEBF5) : const Color(0x733C3C43),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    if (namenRegel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Met $namenRegel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: secundair),
                        ),
                      ),
                  ],
                ),
              ),
              if (toonAvatars) ...[
                const SizedBox(width: 8),
                _MonteurAvatars(
                  monteurs: monteurs,
                  ikId: ik,
                  ringKleur: kaartKleur,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Overlappende avatars van de monteurs (max. 3, daarna "+n"). De ingelogde
/// gebruiker staat eerst als "jij" in oranje.
class _MonteurAvatars extends StatelessWidget {
  final List<ServicePerson> monteurs;
  final int? ikId;
  final Color ringKleur;

  const _MonteurAvatars({
    required this.monteurs,
    required this.ikId,
    required this.ringKleur,
  });

  static const _kleuren = [
    Color(0xFF007AFF),
    Color(0xFF34C759),
    Color(0xFF5856D6),
  ];

  static String _initialen(String naam) {
    final delen = naam.trim().split(RegExp(r'\s+')).where((d) => d.isNotEmpty);
    if (delen.isEmpty) return '?';
    final eerste = delen.first[0];
    final laatste = delen.length > 1 ? delen.last[0] : '';
    return (eerste + laatste).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final jij = monteurs.where((m) => m.id == ikId).toList();
    final anderen = monteurs.where((m) => m.id != ikId).toList();
    final gesorteerd = [...jij, ...anderen];
    const max = 3;
    final getoond = gesorteerd.take(max).toList();
    final rest = gesorteerd.length - getoond.length;

    Widget cirkel(String tekst, Color bg, {Color fg = CupertinoColors.white, double fs = 10}) =>
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: bg,
            border: Border.all(color: ringKleur, width: 2),
          ),
          child: Text(
            tekst,
            style: TextStyle(fontSize: fs, fontWeight: FontWeight.w700, color: fg),
          ),
        );

    final items = <Widget>[];
    var kleurIndex = 0;
    for (final m in getoond) {
      if (m.id == ikId) {
        items.add(cirkel('jij', const Color(0xFFFF6B2B)));
      } else {
        items.add(
          cirkel(_initialen(m.name), _kleuren[kleurIndex % _kleuren.length]),
        );
        kleurIndex++;
      }
    }
    if (rest > 0) {
      items.add(
        cirkel(
          '+$rest',
          const Color(0xFFE5E5EA),
          fg: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      );
    }

    // Overlap van 6px tussen de cirkels.
    const stap = 20.0;
    return SizedBox(
      width: 26 + stap * (items.length - 1),
      height: 26,
      child: Stack(
        children: [
          for (var i = 0; i < items.length; i++)
            Positioned(left: stap * i, child: items[i]),
        ],
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
            Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 40,
              color: CupertinoColors.destructiveRed.resolveFrom(context),
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
