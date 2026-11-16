import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../core/theme/app_colors.dart';
import '../../planning/data/hours_draft_service.dart';
import '../../planning/screens/hours_week_screen.dart';
import '../data/uren_overzicht_service.dart';
import '../models/uren_formaat.dart';
import '../models/uren_overzicht.dart';
import '../widgets/uren_widgets.dart';
import '../../../widgets/nav_border.dart';

/// Urenoverzicht (opent vanaf het hoofdscherm): overzicht van gewerkte en geregistreerde uren
/// per week (standaard) of maand, met een knop om uren en km te registreren.
class UrenOverzichtScreen extends StatefulWidget {
  const UrenOverzichtScreen({super.key});

  @override
  State<UrenOverzichtScreen> createState() => _UrenOverzichtScreenState();
}

class _UrenOverzichtScreenState extends State<UrenOverzichtScreen>
    with WidgetsBindingObserver {
  static const _weekNorm = 40 * 60;

  bool _maand = false;
  DateTime _anker = alleenDatum(DateTime.now());
  DateTime _gekozen = alleenDatum(DateTime.now());
  PeriodeOverzicht? _periode;
  bool _loading = true;
  String? _error;
  bool _versturen = false;
  int _laadNummer = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load(stil: true));
  }

  DateTime get _start => _maand
      ? maandagVan(DateTime(_anker.year, _anker.month, 1))
      : maandagVan(_anker);

  DateTime get _eindExcl {
    if (!_maand) return _start.add(const Duration(days: 7));
    final laatste = DateTime(_anker.year, _anker.month + 1, 0);
    final m = maandagVan(laatste);
    return DateTime(m.year, m.month, m.day + 7);
  }

  /// Laadt de periode. Bij [stil] blijft de huidige inhoud staan tot de
  /// nieuwe klaar is.
  Future<void> _load({bool stil = false}) async {
    final nummer = ++_laadNummer;
    if (!stil) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final p = await UrenOverzichtService.instance.laad(
        start: _start,
        eindExcl: _eindExcl,
      );
      if (!mounted || nummer != _laadNummer) return;
      setState(() {
        _periode = p;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || nummer != _laadNummer) return;
      setState(() {
        if (!stil || _periode == null) _error = e.toString();
        _loading = false;
      });
    }
  }

  void _verschuif(int stap) {
    setState(() {
      _anker = _maand
          ? DateTime(_anker.year, _anker.month + stap, 1)
          : DateTime(_anker.year, _anker.month, _anker.day + 7 * stap);
      _gekozen = _maand ? _anker : _start;
      _periode = null;
    });
    _load();
  }

  void _naarVandaag() {
    final nu = alleenDatum(DateTime.now());
    setState(() {
      _anker = nu;
      _gekozen = nu;
      _periode = null;
    });
    _load();
  }

  void _wisselModus(bool maand) {
    if (maand == _maand) return;
    final nu = alleenDatum(DateTime.now());
    setState(() {
      _maand = maand;
      _gekozen = nu;
      _anker = nu;
      _periode = null;
    });
    _load();
  }

  bool get _isHuidig {
    final nu = DateTime.now();
    return _maand
        ? (_anker.year == nu.year && _anker.month == nu.month)
        : maandagVan(_anker) == maandagVan(nu);
  }

  Future<void> _registreer([DateTime? datum]) async {
    await HoursWeekScreen.registreer(context, dag: datum ?? _gekozen);
    if (mounted) unawaited(_load(stil: true));
  }

  /// Verstuurt alle niet-verstuurde uren van de getoonde periode, na
  /// bevestiging.
  Future<void> _verstuur(PeriodeOverzicht p) async {
    final minuten = p.conceptMinuten;
    final akkoord = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Uren versturen?'),
        content: Text(
          '${urenMetU(minuten)} gaat naar kantoor ter goedkeuring. '
          'Daarna kun je ze niet meer aanpassen.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuleren'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Versturen'),
          ),
        ],
      ),
    );
    if (akkoord != true || !mounted) return;

    setState(() => _versturen = true);
    final bonIds = {
      for (final r in p.conceptRegels)
        if (r.bonId != null && int.tryParse(r.bonId!) != null) r.bonId!,
    };
    var weken = 0;
    final fouten = <String>[];
    for (final id in bonIds) {
      try {
        final r = await HoursDraftService.instance.verstuurWeken(id);
        weken += r.weken.length;
      } catch (e) {
        fouten.add('Bon $id: $e');
      }
    }
    if (!mounted) return;
    setState(() => _versturen = false);
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(
          fouten.isNotEmpty
              ? 'Niet alles verstuurd'
              : weken == 0
              ? 'Niets te versturen'
              : 'Uren verstuurd',
        ),
        content: Text(
          fouten.isNotEmpty
              ? fouten.join('\n')
              : weken == 0
              ? 'Er stonden geen uren klaar op dit toestel.'
              : 'Kantoor ziet je uren nu staan.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (mounted) unawaited(_load(stil: true));
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.page,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        middle: const Text('Mijn uren'),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const NavBorder(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _inhoud()),
                  Positioned(
                    right: 16,
                    bottom: 16 + MediaQuery.paddingOf(context).bottom,
                    child: CupertinoButton(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(28),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      onPressed: _registreer,
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
                            'Registreren',
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inhoud() {
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
            110 + MediaQuery.paddingOf(context).bottom,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _WeekMaandKiezer(maand: _maand, onKies: _wisselModus),
                const SizedBox(height: 8),
                _periodeNav(),
                const SizedBox(height: 4),
                if (_loading && _periode == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 80),
                    child: Center(child: CupertinoActivityIndicator()),
                  )
                else if (_error != null && _periode == null)
                  _foutBlok()
                else if (_periode != null)
                  ..._periodeInhoud(_periode!),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _periodeNav() {
    final titel = _maand ? maandTitel(_anker) : weekTitel(maandagVan(_anker));
    final zwart = CupertinoColors.label.resolveFrom(context);
    return Row(
      children: [
        CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          onPressed: () => _verschuif(-1),
          child: Icon(CupertinoIcons.chevron_left, size: 20, color: zwart),
        ),
        Expanded(
          child: GestureDetector(
            onTap: _isHuidig ? null : _naarVandaag,
            child: Column(
              children: [
                Text(
                  titel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          onPressed: () => _verschuif(1),
          child: Icon(CupertinoIcons.chevron_right, size: 20, color: zwart),
        ),
      ],
    );
  }

  Widget _foutBlok() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
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
    );
  }

  /// Alleen de dagen van de gekozen maand (voor het maandtotaal).
  PeriodeOverzicht _alleenMaand(PeriodeOverzicht p) {
    final dagen = [
      for (final d in p.dagen)
        if (d.datum.month == _anker.month) d,
    ];
    return PeriodeOverzicht(
      start: dagen.first.datum,
      eindExcl: p.eindExcl,
      dagen: dagen,
      ridderBekend: p.ridderBekend,
    );
  }

  List<Widget> _periodeInhoud(PeriodeOverzicht p) {
    final samen = _maand ? _alleenMaand(p) : p;
    final dag = p.dag(_gekozen) ?? p.dagen.first;
    return [
      SamenvattingKaart(
        periode: samen,
        normMinuten: _maand ? maandNormMinuten(_anker) : _weekNorm,
      ),
      const SizedBox(height: 12),
      if (_maand)
        MaandKalender(
          periode: p,
          maand: _anker,
          geselecteerd: _gekozen,
          onKies: (d) => setState(() => _gekozen = d),
        )
      else
        WeekGrafiek(
          periode: p,
          geselecteerd: _gekozen,
          onKies: (d) => setState(() => _gekozen = d),
        ),
      if (samen.conceptMinuten > 0) ...[
        const SizedBox(height: 12),
        _verstuurStrook(samen),
      ],
      const SizedBox(height: 12),
      DagDetail(dag: dag, onToevoegen: () => _registreer(dag.datum)),
    ];
  }

  Widget _verstuurStrook(PeriodeOverzicht p) {
    return KaartVlak(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          const StatusStip(UrenStatus.concept),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${urenMetU(p.conceptMinuten)} nog niet verstuurd',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          _versturen
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CupertinoActivityIndicator(),
                )
              : CupertinoButton(
                  minimumSize: const Size(44, 44),
                  onPressed: () => _verstuur(p),
                  child: const Text(
                    'Verstuur',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
        ],
      ),
    );
  }
}

/// Afgeronde "Week | Maand"-kiezer: een hoge pil met een gleed-pilletje.
class _WeekMaandKiezer extends StatelessWidget {
  const _WeekMaandKiezer({required this.maand, required this.onKies});

  final bool maand;
  final ValueChanged<bool> onKies;

  @override
  Widget build(BuildContext context) {
    Widget optie(String tekst, bool isMaand) {
      final actief = maand == isMaand;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onKies(isMaand),
          child: Center(
            child: Text(
              tekst,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: actief
                    ? CupertinoColors.white
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.card.resolveFrom(context),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: CupertinoColors.separator.resolveFrom(context),
          width: 0.5,
        ),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: maand ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
            ),
          ),
          Row(children: [optie('Week', false), optie('Maand', true)]),
        ],
      ),
    );
  }
}
