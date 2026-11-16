import 'package:flutter/cupertino.dart';

import '../../../core/theme/app_colors.dart';
import '../data/hours_draft_service.dart';
import '../data/planning_repository.dart';
import '../models/job_order.dart';
import 'hours_week_screen.dart';

/// "Uren vorige week": verschijnt (vanaf maandag) zolang de monteur nog niet
/// verstuurde uren of kilometers uit een afgelopen week op zijn toestel
/// heeft. Deadline is zondag; daarna moeten de uren zo snel mogelijk naar
/// kantoor (Brenda) voor de salarisadministratie.
///
/// Toont per dag wat er lokaal geregistreerd is, met per dag een knop om
/// aan te passen, en een knop om alles te versturen (één weekregistratie
/// per bon per week, zie `HoursDraftService.verstuurAfgelopenWekenOveral`).
/// Het scherm is te sluiten, maar zolang deze uren niet verstuurd zijn kan
/// de monteur geen uren voor de huidige week invullen (zie
/// `HoursWeekScreen`).
class WeekAfsluitenScreen extends StatefulWidget {
  const WeekAfsluitenScreen({super.key});

  static bool _isOpen = false;

  /// Opent het scherm schermvullend als er openstaande uren uit afgelopen
  /// weken zijn. Doet niets als het scherm al open is.
  static Future<void> toonAlsNodig(BuildContext context) async {
    if (_isOpen) return;
    final open = await HoursDraftService.instance.openKaartenAfgelopenWeken();
    if (open.isEmpty || !context.mounted || _isOpen) return;
    await openScherm(context);
  }

  /// Opent het scherm, ook als er (volgens de laatste stand) niets openstaat.
  static Future<void> openScherm(BuildContext context) async {
    if (_isOpen) return;
    _isOpen = true;
    try {
      await Navigator.of(context, rootNavigator: true).push(
        CupertinoPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => const WeekAfsluitenScreen(),
        ),
      );
    } finally {
      _isOpen = false;
    }
  }

  @override
  State<WeekAfsluitenScreen> createState() => _WeekAfsluitenScreenState();
}

class _WeekAfsluitenScreenState extends State<WeekAfsluitenScreen> {
  static const _groen = Color(0xFF34C759);
  static const _dagNamen = [
    '', 'Maandag', 'Dinsdag', 'Woensdag', 'Donderdag', 'Vrijdag',
    'Zaterdag', 'Zondag',
  ];
  static const _maanden = [
    '', 'jan', 'feb', 'mrt', 'apr', 'mei', 'jun',
    'jul', 'aug', 'sep', 'okt', 'nov', 'dec',
  ];

  /// Bonnen per id, voor de naam en om het urenscherm te openen. Blijft
  /// bewaard zolang de app draait.
  static Map<String, ServiceOrder>? _bonnenCache;

  bool _laden = true;
  bool _versturen = false;
  String? _fout;
  List<OpenKaart> _kaarten = const [];
  Map<String, ServiceOrder> _bonnen = const {};

  @override
  void initState() {
    super.initState();
    _laad();
  }

  Future<void> _laad() async {
    setState(() => _laden = true);
    final kaarten = await HoursDraftService.instance
        .openKaartenAfgelopenWeken();
    var bonnen = _bonnenCache;
    if (bonnen == null) {
      try {
        final lijst = await PlanningRepository.instance.fetchServiceOrders();
        bonnen = {for (final b in lijst) b.id: b};
        _bonnenCache = bonnen;
      } catch (_) {
        bonnen = const {};
      }
    }
    if (!mounted) return;
    setState(() {
      _kaarten = kaarten;
      _bonnen = bonnen!;
      _laden = false;
    });
  }

  String _bonNaam(String orderId) {
    final b = _bonnen[orderId];
    if (b == null) return 'Bon $orderId';
    return '${b.recordTag} · ${b.description}';
  }

  static String _uren(int minuten) {
    final u = minuten / 60;
    return u == u.truncateToDouble()
        ? '${u.toInt()}u'
        : '${u.toStringAsFixed(1).replaceAll('.', ',')}u';
  }

  static String _totaal(Iterable<OpenKaart> kaarten) {
    final minuten = kaarten.fold<int>(0, (s, k) => s + k.minuten);
    final km = kaarten.fold<int>(0, (s, k) => s + (k.km ?? 0));
    final delen = [
      if (minuten > 0) _uren(minuten),
      if (km > 0) '$km km',
    ];
    return delen.isEmpty ? '—' : delen.join(' · ');
  }

  static int _isoWeek(DateTime d) {
    final dag = DateTime.utc(d.year, d.month, d.day);
    final donderdag = dag.add(Duration(days: 4 - dag.weekday));
    final eersteJan = DateTime.utc(donderdag.year, 1, 1);
    return (donderdag.difference(eersteJan).inDays ~/ 7) + 1;
  }

  String _datum(DateTime d) => '${d.day} ${_maanden[d.month]}';

  Future<void> _aanpassen(DateTime dag, List<OpenKaart> kaartenVanDag) async {
    final bonIds = kaartenVanDag.map((k) => k.orderId).toSet().toList();
    String? gekozen;
    if (bonIds.length == 1) {
      gekozen = bonIds.single;
    } else if (bonIds.length > 1) {
      gekozen = await showCupertinoModalPopup<String>(
        context: context,
        builder: (ctx) => CupertinoActionSheet(
          title: Text('Welke bon wil je aanpassen?'),
          actions: [
            for (final id in bonIds)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(ctx).pop(id),
                child: Text(_bonNaam(id)),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuleren'),
          ),
        ),
      );
      if (gekozen == null) return;
    }
    if (!mounted) return;
    final bon = gekozen == null ? null : _bonnen[gekozen];
    if (gekozen != null && bon == null) {
      setState(
        () => _fout =
            'Deze bon kon niet worden geladen. Controleer je verbinding en '
            'probeer het opnieuw.',
      );
      return;
    }
    await Navigator.of(context).push(
      CupertinoPageRoute<bool>(
        builder: (_) => HoursWeekScreen(initialOrder: bon, initialDay: dag),
      ),
    );
    if (mounted) await _laad();
  }

  Future<void> _verstuur() async {
    setState(() {
      _versturen = true;
      _fout = null;
    });
    final r = await HoursDraftService.instance.verstuurAfgelopenWekenOveral();
    if (!mounted) return;
    if (r.fouten.isNotEmpty) {
      setState(() {
        _versturen = false;
        _fout = 'Niet alles kon worden verstuurd '
            '(${r.fouten.keys.map(_bonNaam).join(', ')}). Controleer je '
            'verbinding en probeer het opnieuw.\n${r.fouten.values.first}';
      });
      await _laad();
      return;
    }
    setState(() => _versturen = false);
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Uren verstuurd'),
        content: const Text(
          'Je uren van vorige week zijn naar kantoor gestuurd. Je kunt nu '
          'weer uren voor deze week invullen.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    return CupertinoPageScaffold(
      backgroundColor: AppColors.page,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        middle: const Text('Uren vorige week'),
      ),
      child: SafeArea(
        child: _laden
            ? const Center(child: CupertinoActivityIndicator())
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [
                        _Uitleg(secundair: secundair),
                        const SizedBox(height: 20),
                        if (_kaarten.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 24),
                            child: Text(
                              'Er staan geen uren van vorige week meer klaar. '
                              'Alles is verstuurd.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: secundair),
                            ),
                          )
                        else
                          ..._weken(secundair),
                      ],
                    ),
                  ),
                  _Voet(
                    totaal: _totaal(_kaarten),
                    fout: _fout,
                    bezig: _versturen,
                    kanVersturen: _kaarten.isNotEmpty && !_versturen,
                    onVersturen: _verstuur,
                  ),
                ],
              ),
      ),
    );
  }

  List<Widget> _weken(Color secundair) {
    final weken = <DateTime, List<OpenKaart>>{};
    for (final k in _kaarten) {
      weken.putIfAbsent(maandagVanWeek(k.dag), () => []).add(k);
    }
    final maandagen = weken.keys.toList()..sort();
    return [
      for (final maandag in maandagen) ...[
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'WEEK ${_isoWeek(maandag)} · ${_datum(maandag)} – '
            '${_datum(maandag.add(const Duration(days: 6)))}',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: secundair,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.card.resolveFrom(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border.resolveFrom(context)),
          ),
          child: Column(
            children: [
              for (var i = 0; i < 7; i++) ...[
                if (i > 0)
                  Container(
                    height: 0.5,
                    color: AppColors.separator.resolveFrom(context),
                  ),
                _dagRij(
                  DateTime(maandag.year, maandag.month, maandag.day + i),
                  weken[maandag]!,
                  secundair,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    ];
  }

  Widget _dagRij(DateTime dag, List<OpenKaart> weekKaarten, Color secundair) {
    final kaarten = weekKaarten
        .where(
          (k) =>
              k.dag.year == dag.year &&
              k.dag.month == dag.month &&
              k.dag.day == dag.day,
        )
        .toList();
    final perBon = <String, List<OpenKaart>>{};
    for (final k in kaarten) {
      perBon.putIfAbsent(k.orderId, () => []).add(k);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_dagNamen[dag.weekday]} ${_datum(dag)}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      kaarten.isEmpty ? 'Geen uren' : _totaal(kaarten),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: kaarten.isEmpty ? secundair : _groen,
                      ),
                    ),
                  ],
                ),
                for (final e in perBon.entries) ...[
                  const SizedBox(height: 4),
                  Text(
                    _bonNaam(e.key),
                    style: TextStyle(fontSize: 12.5, color: secundair),
                  ),
                  for (final k in e.value)
                    Text(
                      '  ${k.label}: ${k.km != null ? '${k.km} km' : _uren(k.minuten)}'
                      '${(k.memo ?? '').trim().isEmpty ? '' : ' · ${k.memo!.trim()}'}',
                      style: const TextStyle(fontSize: 13),
                    ),
                ],
              ],
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(36, 32),
            onPressed: _versturen ? null : () => _aanpassen(dag, kaarten),
            child: const Icon(CupertinoIcons.pencil, size: 20),
          ),
        ],
      ),
    );
  }
}

class _Uitleg extends StatelessWidget {
  const _Uitleg({required this.secundair});

  final Color secundair;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            CupertinoIcons.clock_fill,
            color: AppColors.accent,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Check je uren van vorige week',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Controleer voordat je verder gaat of je uren van vorige '
                  'week goed zijn ingevuld. Ze moeten zo snel mogelijk naar '
                  'Brenda voor de salarisadministratie. Uren voor deze week '
                  'kun je pas invullen als deze uren verstuurd zijn.',
                  style: TextStyle(fontSize: 14.5, height: 1.35, color: secundair),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Voet extends StatelessWidget {
  const _Voet({
    required this.totaal,
    required this.fout,
    required this.bezig,
    required this.kanVersturen,
    required this.onVersturen,
  });

  final String totaal;
  final String? fout;
  final bool bezig;
  final bool kanVersturen;
  final VoidCallback onVersturen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.card.resolveFrom(context),
        border: Border(
          top: BorderSide(color: AppColors.border.resolveFrom(context)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Totaal nog te versturen',
                style: TextStyle(fontSize: 14),
              ),
              const Spacer(),
              Text(
                totaal,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (fout != null) ...[
            const SizedBox(height: 8),
            Text(
              fout!,
              style: TextStyle(
                fontSize: 12.5,
                color: CupertinoColors.destructiveRed.resolveFrom(context),
              ),
            ),
          ],
          const SizedBox(height: 10),
          CupertinoButton(
            color: const Color(0xFF34C759),
            borderRadius: BorderRadius.circular(14),
            onPressed: kanVersturen ? onVersturen : null,
            child: bezig
                ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                : const Text(
                    'Uren versturen',
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
