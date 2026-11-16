import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../core/auth/auth_service.dart';
import '../core/theme/app_colors.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/planning/screens/week_afsluiten_screen.dart';
import '../features/uren_overzicht/data/uren_overzicht_service.dart';
import '../features/uren_overzicht/models/uren_formaat.dart';
import '../features/uren_overzicht/models/uren_overzicht.dart';
import '../features/uren_overzicht/screens/uren_overzicht_screen.dart';
import '../features/uren_overzicht/widgets/uren_widgets.dart';
import '../widgets/engine_logo.dart';
import '../widgets/nav_border.dart';

/// Hoofdscherm: de week in één oogopslag als ring. Tikken op de ring of de
/// dagen opent het volledige urenoverzicht (week en maand).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  static const _weekNorm = 40 * 60;

  PeriodeOverzicht? _periode;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load().then((_) => _controleerVorigeWeek());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _controleerVorigeWeek();
  }

  /// Vanaf maandag: staan er nog niet verstuurde uren uit een afgelopen week
  /// op het toestel, dan opent "Uren vorige week" (deadline zondag).
  Future<void> _controleerVorigeWeek() async {
    if (!mounted) return;
    await WeekAfsluitenScreen.toonAlsNodig(context);
    if (mounted) unawaited(_load(stil: true));
  }

  Future<void> _load({bool stil = false}) async {
    if (!stil) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final start = maandagVan(DateTime.now());
      final p = await UrenOverzichtService.instance.laad(
        start: start,
        eindExcl: start.add(const Duration(days: 7)),
      );
      if (!mounted) return;
      setState(() {
        _periode = p;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (!stil || _periode == null) _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openOverzicht() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => const UrenOverzichtScreen()),
    );
    if (mounted) unawaited(_load(stil: true));
  }

  /// Toont de welkomstuitleg opnieuw, schermvullend boven de tabbalk.
  void _openUitleg() {
    Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute<void>(
        fullscreenDialog: true,
        builder: (routeContext) =>
            OnboardingScreen(onKlaar: () => Navigator.of(routeContext).pop()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.page,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 20),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _openUitleg,
          child: const Icon(CupertinoIcons.question_circle),
        ),
        middle: const EngineLogo(),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => AuthService.instance.logout(),
          child: const Icon(CupertinoIcons.square_arrow_right),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const NavBorder(),
            Expanded(
              child: _inhoud(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inhoud() {
    final start = maandagVan(DateTime.now());
    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        CupertinoSliverRefreshControl(onRefresh: () => _load(stil: true)),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Dashboard',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  weekTitel(start),
                  style: TextStyle(fontSize: 15, color: subKleur(context)),
                ),
                const SizedBox(height: 16),
                if (_loading && _periode == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 80),
                    child: Center(child: CupertinoActivityIndicator()),
                  )
                else if (_error != null && _periode == null)
                  _foutBlok()
                else if (_periode != null)
                  ..._weekInhoud(_periode!),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _foutBlok() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          children: [
            Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 44,
              color: CupertinoColors.systemRed.resolveFrom(context),
            ),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            CupertinoButton(
              onPressed: _load,
              child: const Text('Opnieuw proberen'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _weekInhoud(PeriodeOverzicht p) {
    final fractie = (p.totaalMinuten / _weekNorm).clamp(0.0, 1.0);
    return [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openOverzicht,
        child: KaartVlak(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Column(
            children: [
              SizedBox(
                width: 200,
                height: 200,
                child: CustomPaint(
                  painter: _RingPainter(
                    projectFractie: (p.projectMinuten / _weekNorm).clamp(
                      0.0,
                      1.0,
                    ),
                    indirectFractie: (p.indirectMinuten / _weekNorm).clamp(
                      0.0,
                      1.0,
                    ),
                    spoor: CupertinoColors.systemFill.resolveFrom(context),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          urenTekst(p.totaalMinuten),
                          style: const TextStyle(
                            fontSize: 44,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -1,
                          ),
                        ),
                        Text(
                          'van ${_weekNorm ~/ 60} uur',
                          style: TextStyle(
                            fontSize: 15,
                            color: subKleur(context),
                          ),
                        ),
                        if (fractie >= 1)
                          const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Text(
                              'Week vol',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: urenGroen,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SoortVlak(
                    soort: UrenSoort.project,
                    breedte: 12,
                    hoogte: 12,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Project ${urenTekst(p.projectMinuten)}',
                    style: TextStyle(fontSize: 13, color: subKleur(context)),
                  ),
                  const SizedBox(width: 18),
                  const SoortVlak(
                    soort: UrenSoort.indirect,
                    breedte: 12,
                    hoogte: 12,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Indirect ${urenTekst(p.indirectMinuten)}',
                    style: TextStyle(fontSize: 13, color: subKleur(context)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                kmTekst(p.km),
                style: TextStyle(fontSize: 13, color: subKleur(context)),
              ),
              const SizedBox(height: 14),
              Container(
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Bekijk urenoverzicht',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
                    SizedBox(width: 6),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 14,
                      color: AppColors.accent,
                    ),
                  ],
                ),
              ),
              if (!p.ridderBekend) ...[
                const SizedBox(height: 8),
                Text(
                  'Ridder was niet bereikbaar: alleen de uren uit de app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openOverzicht,
        child: KaartVlak(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [for (final d in p.dagen.take(5)) _dagRij(d)],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        'Groen = goedgekeurd · oranje = wacht op kantoor · holle stip = nog niet verstuurd',
        style: TextStyle(fontSize: 13, color: subKleur(context)),
      ),
    ];
  }

  Widget _dagRij(DagOverzicht d) {
    final totaal = d.totaalMinuten;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              dagNamenKort[d.datum.weekday - 1],
              style: TextStyle(fontSize: 15, color: subKleur(context)),
            ),
          ),
          Expanded(
            child: totaal == 0
                ? const SizedBox()
                : LayoutBuilder(
                    builder: (context, c) {
                      // Een volle balk is 10 uur.
                      final breedte =
                          c.maxWidth * (totaal / 600).clamp(0.0, 1.0);
                      final p = totaal == 0 ? 0.0 : d.projectMinuten / totaal;
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: breedte,
                          height: 14,
                          child: Row(
                            children: [
                              if (d.projectMinuten > 0)
                                Expanded(
                                  flex: (p * 1000).round().clamp(1, 1000),
                                  child: const SoortVlak(
                                    soort: UrenSoort.project,
                                    hoogte: 14,
                                    radius: 4,
                                  ),
                                ),
                              if (d.projectMinuten > 0 && d.indirectMinuten > 0)
                                const SizedBox(width: 2),
                              if (d.indirectMinuten > 0)
                                Expanded(
                                  flex: ((1 - p) * 1000).round().clamp(1, 1000),
                                  child: const SoortVlak(
                                    soort: UrenSoort.indirect,
                                    hoogte: 14,
                                    radius: 4,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              totaal == 0 ? '–' : urenTekst(totaal),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          StatusStip(d.status),
        ],
      ),
    );
  }
}

/// Voortgangsring: project egaal, indirect als streepjes erachter.
class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.projectFractie,
    required this.indirectFractie,
    required this.spoor,
  });

  final double projectFractie;
  final double indirectFractie;
  final Color spoor;

  @override
  void paint(Canvas canvas, Size size) {
    const dikte = 16.0;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.width / 2 - dikte / 2,
    );
    final basis = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = dikte;
    canvas.drawArc(rect, 0, 2 * math.pi, false, basis..color = spoor);

    const begin = -math.pi / 2;
    final project = 2 * math.pi * projectFractie;
    if (project > 0) {
      canvas.drawArc(
        rect,
        begin,
        project,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = dikte
          ..strokeCap = StrokeCap.butt
          ..color = urenOranje,
      );
    }
    // Indirect: korte streepjes in dezelfde kleur.
    final indirect = 2 * math.pi * indirectFractie;
    if (indirect > 0) {
      final streep = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = dikte
        ..strokeCap = StrokeCap.butt
        ..color = urenOranje;
      const stap = 0.09;
      const lengte = 0.05;
      final eind = begin + project + indirect;
      for (var a = begin + project; a < eind; a += stap) {
        canvas.drawArc(rect, a, math.min(lengte, eind - a), false, streep);
      }
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.projectFractie != projectFractie ||
      old.indirectFractie != indirectFractie ||
      old.spoor != spoor;
}
