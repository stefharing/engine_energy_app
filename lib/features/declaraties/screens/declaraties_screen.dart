import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../../../core/theme/app_colors.dart';
import '../../planning/models/job_order.dart' show ServiceOrder;
import '../data/declaratie_service.dart';
import '../models/declaratie.dart';
import 'declaratie_form_screen.dart';

/// "Kosten & bonnen" van een servicebon: overzicht van de eigen declaraties
/// op deze bon en een grote knop voor een nieuwe. Declaraties die nog niet in
/// Ridder staan worden bij het openen (en bij omlaag trekken) automatisch
/// opnieuw verstuurd.
class DeclaratiesScreen extends StatefulWidget {
  final ServiceOrder order;
  const DeclaratiesScreen({super.key, required this.order});

  @override
  State<DeclaratiesScreen> createState() => _DeclaratiesScreenState();
}

class _DeclaratiesScreenState extends State<DeclaratiesScreen> {
  final _service = DeclaratieService.instance;
  List<Declaratie> _lijst = [];
  bool _geladen = false;
  bool _verstuurt = false;
  bool _leest = false;

  @override
  void initState() {
    super.initState();
    _laad().then((_) => _verstuurOpenstaande());
  }

  Future<void> _laad() async {
    final lijst = (await _service.laad())
        .where((d) => d.bonId == widget.order.id)
        .toList();
    if (mounted) {
      setState(() {
        _lijst = lijst;
        _geladen = true;
      });
    }
  }

  Future<void> _verstuurOpenstaande() async {
    if (_verstuurt || !_lijst.any((d) => !d.isVerstuurd)) return;
    setState(() => _verstuurt = true);
    await _service.verstuurOpenstaande();
    if (mounted) setState(() => _verstuurt = false);
    await _laad();
  }

  Future<void> _formulier() async {
    final bewaard = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => DeclaratieFormScreen(
          order: widget.order,
        ),
      ),
    );
    if (bewaard == true) await _laad();
  }

  Future<void> _acties(Declaratie d) async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(d.omschrijving),
        message: d.fout != null && !d.isVerstuurd ? Text(d.fout!) : null,
        actions: [
          if (!d.isVerstuurd)
            CupertinoActionSheetAction(
              onPressed: () async {
                Navigator.of(ctx).pop();
                setState(() => _verstuurt = true);
                await _service.verstuur(d);
                if (mounted) setState(() => _verstuurt = false);
                await _laad();
              },
              child: const Text('Opnieuw versturen'),
            ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _service.verwijder(d);
              await _laad();
            },
            child: Text(
              d.isVerstuurd ? 'Uit overzicht verwijderen' : 'Verwijderen (niet versturen)',
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Sluiten'),
        ),
      ),
    );
  }

  static String _bedrag(double v) => '€ ${v.toStringAsFixed(2).replaceAll('.', ',')}';

  static String _datum(DateTime d) {
    const m = ['jan', 'feb', 'mrt', 'apr', 'mei', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];
    return '${d.day} ${m[d.month - 1]}';
  }

  Widget _kaart(Declaratie d) {
    final wacht = !d.isVerstuurd;
    final kaart = CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final rand = CupertinoColors.separator.resolveFrom(context);
    final vlak = CupertinoColors.systemGrey5.resolveFrom(context);
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final heeftFoto = d.fotoPad != null && File(d.fotoPad!).existsSync();
    final chipKleur = wacht
        ? CupertinoColors.systemOrange.resolveFrom(context)
        : CupertinoColors.systemGreen.resolveFrom(context);

    return GestureDetector(
      onTap: () => _acties(d),
      child: Container(
        decoration: BoxDecoration(
          color: kaart,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: rand, width: 0.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 150,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: vlak),
                  if (heeftFoto)
                    Image.file(
                      File(d.fotoPad!),
                      fit: BoxFit.cover,
                      cacheWidth: 500,
                    )
                  else
                    Center(
                      child: Container(
                        width: 82,
                        height: 126,
                        padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                        decoration: BoxDecoration(
                          color: CupertinoColors.white,
                          borderRadius: BorderRadius.circular(3),
                          boxShadow: const [
                            BoxShadow(color: Color(0x26000000), blurRadius: 8, offset: Offset(0, 2)),
                          ],
                        ),
                        child: Column(
                          children: [
                            Container(height: 5, width: 49, color: const Color(0xFFD1D1D6)),
                            const SizedBox(height: 8),
                            for (final w in [1.0, 0.75, 0.85])
                              Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: FractionallySizedBox(
                                    widthFactor: w,
                                    child: Container(height: 3, color: const Color(0xFFD1D1D6)),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: kaart,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        wacht ? 'Wacht' : 'Verstuurd',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: chipKleur,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _bedrag(d.bedrag),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    d.omschrijving,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    '${_datum(d.datum)} · ${d.betaalwijze.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: secundair),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _samenvatting {
    if (_lijst.isEmpty) return 'Nog geen bonnen';
    final totaal = _lijst.fold<double>(0, (a, d) => a + d.bedrag);
    final wacht = _lijst.where((d) => !d.isVerstuurd).length;
    final delen = [
      '${_lijst.length} ${_lijst.length == 1 ? 'bon' : 'bonnen'}',
      _bedrag(totaal),
      if (wacht > 0) '$wacht ${wacht == 1 ? 'wacht' : 'wachten'} op verzenden',
    ];
    return delen.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final achtergrond = CupertinoDynamicColor.resolve(AppColors.page, context);
    final onderkant = MediaQuery.paddingOf(context).bottom;
    // Nieuwste bovenaan.
    final gesorteerd = [..._lijst]
      ..sort((a, b) => b.aangemaaktOp.compareTo(a.aangemaaktOp));

    return CupertinoPageScaffold(
      backgroundColor: AppColors.page,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        middle: Text('Bon ${widget.order.orderNumber}'),
      ),
      child: SafeArea(
        bottom: false,
        child: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                CupertinoSliverRefreshControl(
                  onRefresh: () async {
                    await _laad();
                    await _verstuurOpenstaande();
                  },
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Kosten & bonnen',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                _samenvatting,
                                style: TextStyle(fontSize: 15, color: secundair),
                              ),
                            ),
                            if (_verstuurt) ...[
                              const SizedBox(width: 8),
                              const CupertinoActivityIndicator(radius: 7),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (gesorteerd.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverGrid(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        mainAxisExtent: 232,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _kaart(gesorteerd[i]),
                        childCount: gesorteerd.length,
                      ),
                    ),
                  ),
                if (_geladen && _lijst.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(32, 0, 32, 120),
                        child: Text(
                          'Nog geen bonnen op deze servicebon.\nTik op Declaratie toevoegen om te beginnen.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: secundair),
                        ),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: 130 + onderkant)),
              ],
            ),
          ),
          // Vervaging onderaan, zodat de knop leesbaar blijft.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 100 + onderkant,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    stops: const [0.55, 1],
                    colors: [achtergrond, achtergrond.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16 + onderkant,
            child: CupertinoButton(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(28),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              onPressed: _formulier,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.add,
                    size: 18,
                    color: CupertinoColors.white,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Declaratie toevoegen',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_leest)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(child: CupertinoActivityIndicator(radius: 16)),
              ),
            ),
        ],
      ),
      ),
    );
  }
}
