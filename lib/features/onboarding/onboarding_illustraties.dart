import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../../core/theme/app_colors.dart';
import '../../widgets/engine_logo.dart';

// Kleine, nagebootste stukjes van de echte schermen voor de welkomstuitleg.
// Elke illustratie draait op een rustige lus (0 → 1) die alleen loopt
// zolang de pagina in beeld is, en staat stil (in de "eindstand") als
// "Beperk beweging" aan staat in de iOS-instellingen.

// ─── Basis ────────────────────────────────────────────────────────────────

/// Herhalende tijdlijn voor een illustratie. [builder] krijgt de positie
/// `t` (0..1) binnen de lus.
class LusAnimatie extends StatefulWidget {
  const LusAnimatie({
    super.key,
    required this.actief,
    required this.duur,
    required this.builder,
    this.stilstand = 0.75,
  });

  final bool actief;
  final Duration duur;
  final Widget Function(BuildContext context, double t) builder;

  /// Positie in de lus die getoond wordt als animaties uit staan.
  final double stilstand;

  @override
  State<LusAnimatie> createState() => _LusAnimatieState();
}

class _LusAnimatieState extends State<LusAnimatie>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duur,
  );

  bool get _bewegingUit => WidgetsBinding
      .instance
      .platformDispatcher
      .accessibilityFeatures
      .disableAnimations;

  @override
  void initState() {
    super.initState();
    _bijwerken();
  }

  @override
  void didUpdateWidget(covariant LusAnimatie oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actief != widget.actief) _bijwerken();
  }

  void _bijwerken() {
    if (_bewegingUit) {
      _c.value = widget.stilstand;
      return;
    }
    if (widget.actief) {
      _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => widget.builder(context, _c.value),
    );
  }
}

/// Voortgang (0..1) van [t] binnen het venster [van]..[tot].
double fase(
  double t,
  double van,
  double tot, [
  Curve curve = Curves.easeInOutCubic,
]) {
  if (t <= van) return 0;
  if (t >= tot) return 1;
  return curve.transform((t - van) / (tot - van));
}

/// 1 gedurende de lus, zakt naar 0 aan het eind zodat alles rustig
/// verdwijnt voordat de lus opnieuw begint.
double _uitfaden(double t) => 1 - fase(t, 0.9, 0.98);

/// Een "tik": een oranje ring die uitdijt en vervaagt, gecentreerd op
/// [child] (of op [uitlijning] binnen [child]).
class MetTik extends StatelessWidget {
  const MetTik({
    super.key,
    required this.p,
    required this.child,
    this.uitlijning = Alignment.center,
    this.grootte = 40,
  });

  /// Voortgang van de tik (0 of 1 = niet zichtbaar).
  final double p;
  final Widget child;
  final Alignment uitlijning;
  final double grootte;

  @override
  Widget build(BuildContext context) {
    final zichtbaar = p > 0 && p < 1;
    final sterkte = (1 - p).clamp(0.0, 1.0);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (zichtbaar)
          Positioned.fill(
            child: IgnorePointer(
              child: OverflowBox(
                alignment: uitlijning,
                minWidth: 0,
                minHeight: 0,
                maxWidth: grootte,
                maxHeight: grootte,
                child: Transform.scale(
                  scale: 0.45 + 0.75 * p,
                  child: Container(
                    width: grootte,
                    height: grootte,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.accent.withValues(alpha: 0.18 * sterkte),
                      border: Border.all(
                        color: AppColors.accent.withValues(
                          alpha: 0.7 * sterkte,
                        ),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Gekleurd vierkantje met icoon, zoals in de takenlijst van een bon.
class _IcoonTegel extends StatelessWidget {
  const _IcoonTegel(this.icon, this.kleur, {this.grootte = 28});

  final IconData icon;
  final Color kleur;
  final double grootte;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: grootte,
      height: grootte,
      decoration: BoxDecoration(
        color: kleur.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(grootte * 0.28),
      ),
      child: Icon(icon, size: grootte * 0.55, color: kleur),
    );
  }
}

TextStyle _klein(BuildContext context, {bool secundair = false}) => TextStyle(
  fontSize: 11,
  height: 1.2,
  color: secundair
      ? CupertinoColors.secondaryLabel.resolveFrom(context)
      : CupertinoColors.label.resolveFrom(context),
);

const _padding = EdgeInsets.all(14);

// ─── 1. Welkom ────────────────────────────────────────────────────────────

class WelkomIllustratie extends StatelessWidget {
  const WelkomIllustratie({super.key, required this.actief});

  final bool actief;

  static const _tabs = [
    (CupertinoIcons.house, 'Dashboard'),
    (CupertinoIcons.calendar, 'Planning'),
    (CupertinoIcons.folder, 'Bonnen'),
  ];

  @override
  Widget build(BuildContext context) {
    return LusAnimatie(
      actief: actief,
      duur: const Duration(milliseconds: 6000),
      stilstand: 0,
      builder: (context, t) {
        final gekozen = math.min((t * _tabs.length).floor(), _tabs.length - 1);
        final grijs = CupertinoColors.systemGrey.resolveFrom(context);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const EngineLogo(height: 34),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Transform.translate(
                    offset: Offset(
                      0,
                      -2.5 * math.sin(t * 2 * math.pi * 2 - i * 0.9),
                    ),
                    child: Column(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOut,
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i == gekozen
                                ? AppColors.accent.withValues(alpha: 0.14)
                                : AppColors.field.resolveFrom(context),
                          ),
                          child: Icon(
                            _tabs[i].$1,
                            size: 22,
                            color: i == gekozen ? AppColors.accent : grijs,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _tabs[i].$2,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: i == gekozen ? AppColors.accent : grijs,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

// ─── 2. Indirecte uren ────────────────────────────────────────────────────

class IndirecteUrenIllustratie extends StatelessWidget {
  const IndirecteUrenIllustratie({super.key, required this.actief});

  final bool actief;

  static const _indigo = Color(0xFF5856D6);
  static const _dagen = ['ma', 'di', 'wo', 'do', 'vr'];

  @override
  Widget build(BuildContext context) {
    return LusAnimatie(
      actief: actief,
      duur: const Duration(milliseconds: 5200),
      builder: (context, t) {
        final gekozen = t > 0.3 && t < 0.92;
        final dag = t > 0.38 && t < 0.92 ? 2 : 0;
        final kaart = fase(t, 0.52, 0.64) * _uitfaden(t);
        final veld = AppColors.field.resolveFrom(context);

        return Padding(
          padding: _padding,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Bonkiezer bovenin het scherm "Uren & KM".
                  MetTik(
                    p: fase(t, 0.1, 0.3, Curves.linear),
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: veld,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Row(
                          key: ValueKey(gekozen),
                          children: [
                            Icon(
                              gekozen
                                  ? CupertinoIcons.clock_fill
                                  : CupertinoIcons.doc_text,
                              size: 16,
                              color: gekozen
                                  ? _indigo
                                  : CupertinoColors.systemGrey.resolveFrom(
                                      context,
                                    ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                gekozen
                                    ? 'Indirecte uren'
                                    : 'Selecteer een bon',
                                style: _klein(context, secundair: !gekozen)
                                    .copyWith(
                                      fontSize: 13,
                                      fontWeight: gekozen
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                              ),
                            ),
                            Icon(
                              CupertinoIcons.chevron_down,
                              size: 13,
                              color: CupertinoColors.tertiaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Dagen van de week.
                  Row(
                    children: [
                      for (var i = 0; i < _dagen.length; i++)
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: i == dag ? AppColors.accent : veld,
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Text(
                              _dagen[i],
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: i == dag
                                    ? CupertinoColors.white
                                    : CupertinoColors.secondaryLabel
                                          .resolveFrom(context),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // De nieuwe urenkaart.
                  Opacity(
                    opacity: kaart,
                    child: Transform.translate(
                      offset: Offset(0, 10 * (1 - kaart)),
                      child: Container(
                        height: 50,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: AppColors.card.resolveFrom(context),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.border.resolveFrom(context),
                          ),
                        ),
                        child: Row(
                          children: [
                            const _IcoonTegel(
                              CupertinoIcons.clock_fill,
                              _indigo,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Indirecte uren',
                                    style: _klein(context).copyWith(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Omschrijving (optioneel)',
                                    style: _klein(context, secundair: true),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '2u',
                              style: _klein(context).copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // De +-knop rechtsonder.
              Positioned(
                right: 0,
                bottom: 0,
                child: MetTik(
                  p: fase(t, 0.4, 0.55, Curves.linear),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.accent,
                    ),
                    child: const Icon(
                      CupertinoIcons.add,
                      size: 20,
                      color: CupertinoColors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── 3. Planning ──────────────────────────────────────────────────────────

class PlanningIllustratie extends StatelessWidget {
  const PlanningIllustratie({super.key, required this.actief});

  final bool actief;

  static const _dagen = ['ma', 'di', 'wo', 'do', 'vr'];
  static const _vandaag = 2;

  /// (rij, eerste dag, aantal dagen, kleur, tekst)
  static const _blokken = [
    (0, 2, 2, AppColors.accent, 'Jouw bon'),
    (1, 0, 2, Color(0xFF007AFF), 'Onderhoud'),
    (2, 1, 1, Color(0xFF34C759), 'Storing'),
    (2, 3, 2, Color(0xFF8E8E93), 'Afspraak'),
  ];

  static const _namen = ['JIJ', 'WB', 'KD'];

  @override
  Widget build(BuildContext context) {
    return LusAnimatie(
      actief: actief,
      duur: const Duration(milliseconds: 5000),
      builder: (context, t) {
        final tik = fase(t, 0.55, 0.78, Curves.linear);
        final indruk = 1 - 0.04 * math.sin(math.pi * fase(t, 0.55, 0.65));
        // Heel licht heen en weer "scrollen" door de dagen.
        final schuif = -6 * math.sin(t * 2 * math.pi);
        final lijn = AppColors.separator.resolveFrom(context);

        return Padding(
          padding: _padding,
          child: LayoutBuilder(
            builder: (context, c) {
              const naamBreedte = 38.0;
              const kopHoogte = 26.0;
              final dagBreedte = (c.maxWidth - naamBreedte) / _dagen.length;
              final rijHoogte = (c.maxHeight - kopHoogte) / _namen.length;

              return ClipRect(
                child: Stack(
                  children: [
                    // Kolom van vandaag.
                    Positioned(
                      left: naamBreedte + _vandaag * dagBreedte + schuif,
                      top: 0,
                      width: dagBreedte,
                      bottom: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    // Dagkoppen.
                    for (var d = 0; d < _dagen.length; d++)
                      Positioned(
                        left: naamBreedte + d * dagBreedte + schuif,
                        top: 4,
                        width: dagBreedte,
                        child: Text(
                          _dagen[d],
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: d == _vandaag
                                ? AppColors.accent
                                : CupertinoColors.secondaryLabel.resolveFrom(
                                    context,
                                  ),
                          ),
                        ),
                      ),
                    // Rijlijnen.
                    for (var r = 1; r < _namen.length; r++)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: kopHoogte + r * rijHoogte,
                        child: Container(height: 0.5, color: lijn),
                      ),
                    // Blokken.
                    for (final b in _blokken)
                      Positioned(
                        left: naamBreedte + b.$2 * dagBreedte + 3 + schuif,
                        top: kopHoogte + b.$1 * rijHoogte + 6,
                        width: b.$3 * dagBreedte - 6,
                        height: rijHoogte - 12,
                        child: _PlanBlok(
                          kleur: b.$4,
                          tekst: b.$5,
                          tik: b.$1 == 0 ? tik : 0,
                          schaal: b.$1 == 0 ? indruk : 1,
                        ),
                      ),
                    // Namen/avatars (vast, scrollen niet mee).
                    for (var r = 0; r < _namen.length; r++)
                      Positioned(
                        left: 0,
                        top: kopHoogte + r * rijHoogte,
                        width: naamBreedte,
                        height: rijHoogte,
                        child: Container(
                          color: AppColors.card.resolveFrom(context),
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 30,
                            height: 30,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: r == 0
                                  ? AppColors.accent.withValues(alpha: 0.15)
                                  : AppColors.field.resolveFrom(context),
                            ),
                            child: Text(
                              _namen[r],
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: r == 0
                                    ? AppColors.accent
                                    : CupertinoColors.secondaryLabel
                                          .resolveFrom(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _PlanBlok extends StatelessWidget {
  const _PlanBlok({
    required this.kleur,
    required this.tekst,
    required this.tik,
    required this.schaal,
  });

  final Color kleur;
  final String tekst;
  final double tik;
  final double schaal;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: schaal,
      child: MetTik(
        p: tik,
        grootte: 34,
        child: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: kleur.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(6),
            border: Border(left: BorderSide(color: kleur, width: 3)),
          ),
          child: Text(
            tekst,
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: kleur,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 4. Bonnenlijst ───────────────────────────────────────────────────────

class BonnenIllustratie extends StatelessWidget {
  const BonnenIllustratie({super.key, required this.actief});

  final bool actief;

  /// (icoon, kleur, klant, regel, meerdere monteurs)
  static const _bonnen = [
    (
      CupertinoIcons.wrench_fill,
      AppColors.accent,
      'Endurance',
      'Onderhoud generator · 200027',
      true,
    ),
    (
      CupertinoIcons.bolt_fill,
      Color(0xFFFF3B30),
      'Junglestar',
      'Storing motor · 200031',
      false,
    ),
    (
      CupertinoIcons.cube_box_fill,
      Color(0xFF007AFF),
      'MY ALAIYA',
      'Levering onderdelen · 200035',
      false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return LusAnimatie(
      actief: actief,
      duur: const Duration(milliseconds: 5000),
      builder: (context, t) {
        final weg = _uitfaden(t);
        return Padding(
          padding: _padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'VANDAAG',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 6),
              for (var i = 0; i < _bonnen.length; i++) ...[
                if (i > 0) const SizedBox(height: 7),
                Builder(
                  builder: (context) {
                    final p = fase(t, 0.05 + i * 0.09, 0.3 + i * 0.09) * weg;
                    final b = _bonnen[i];
                    return Opacity(
                      opacity: p,
                      child: Transform.translate(
                        offset: Offset(0, 12 * (1 - p)),
                        child: MetTik(
                          p: i == 0 ? fase(t, 0.6, 0.82, Curves.linear) : 0,
                          child: _BonKaart(
                            icon: b.$1,
                            kleur: b.$2,
                            klant: b.$3,
                            regel: b.$4,
                            meerdere: b.$5,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _BonKaart extends StatelessWidget {
  const _BonKaart({
    required this.icon,
    required this.kleur,
    required this.klant,
    required this.regel,
    required this.meerdere,
  });

  final IconData icon;
  final Color kleur;
  final String klant;
  final String regel;
  final bool meerdere;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.card.resolveFrom(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border.resolveFrom(context)),
      ),
      child: Row(
        children: [
          _IcoonTegel(icon, kleur, grootte: 26),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  klant,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _klein(
                    context,
                  ).copyWith(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                Text(
                  regel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _klein(
                    context,
                    secundair: true,
                  ).copyWith(fontSize: 10.5),
                ),
              ],
            ),
          ),
          if (meerdere)
            SizedBox(
              width: 34,
              height: 20,
              child: Stack(
                children: [
                  Positioned(
                    right: 0,
                    child: _MiniAvatar(
                      'WB',
                      AppColors.field.resolveFrom(context),
                    ),
                  ),
                  Positioned(
                    right: 13,
                    child: _MiniAvatar(
                      'jij',
                      AppColors.accent.withValues(alpha: 0.2),
                      tekstKleur: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  const _MiniAvatar(this.tekst, this.kleur, {this.tekstKleur});

  final String tekst;
  final Color kleur;
  final Color? tekstKleur;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: kleur,
        border: Border.all(
          color: AppColors.card.resolveFrom(context),
          width: 1.5,
        ),
      ),
      child: Text(
        tekst,
        style: TextStyle(
          fontSize: 7.5,
          fontWeight: FontWeight.w700,
          color:
              tekstKleur ?? CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
    );
  }
}

// ─── 5. Een bon openen ────────────────────────────────────────────────────

class BonDetailIllustratie extends StatelessWidget {
  const BonDetailIllustratie({super.key, required this.actief});

  final bool actief;

  static const _secties = [
    (CupertinoIcons.checkmark_square, Color(0xFFFF6B2B), 'Taken'),
    (CupertinoIcons.wrench, Color(0xFF007AFF), 'Klus'),
    (CupertinoIcons.gear_alt, Color(0xFF5856D6), 'Object'),
    (CupertinoIcons.location, Color(0xFF34C759), 'Adres & contact'),
  ];

  @override
  Widget build(BuildContext context) {
    return LusAnimatie(
      actief: actief,
      duur: const Duration(milliseconds: 5200),
      builder: (context, t) {
        final weg = _uitfaden(t);
        final voortgang = 0.5 * fase(t, 0.08, 0.45) * weg;
        return Padding(
          padding: _padding,
          child: Column(
            children: [
              // Donkere kop met status, titel en voortgang.
              Container(
                height: 86,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF34C759).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Uitvoering',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF34C759),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Onderhoud generator',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: CupertinoColors.white,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: Stack(
                              children: [
                                Container(
                                  height: 5,
                                  color: CupertinoColors.white.withValues(
                                    alpha: 0.15,
                                  ),
                                ),
                                FractionallySizedBox(
                                  widthFactor: voortgang,
                                  child: Container(
                                    height: 5,
                                    color: AppColors.accent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(voortgang * 6).round()}/6 taken',
                          style: TextStyle(
                            fontSize: 10,
                            color: CupertinoColors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // De onderdelen eronder, in de volgorde van het scherm.
              for (final rij in const [
                [0, 1],
                [2, 3],
              ]) ...[
                if (rij.first > 0) const SizedBox(height: 7),
                Expanded(
                  child: Row(
                    children: [
                      for (final i in rij) ...[
                        if (i != rij.first) const SizedBox(width: 7),
                        Expanded(child: _sectie(context, t, weg, i)),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _sectie(BuildContext context, double t, double weg, int i) {
    final p = fase(t, 0.3 + i * 0.08, 0.5 + i * 0.08) * weg;
    final s = _secties[i];
    return Opacity(
      opacity: p,
      child: Transform.translate(
        offset: Offset(0, 8 * (1 - p)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: AppColors.card.resolveFrom(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border.resolveFrom(context)),
          ),
          child: Row(
            children: [
              _IcoonTegel(s.$1, s.$2, grootte: 22),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  s.$3,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _klein(context).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 6. Taken ─────────────────────────────────────────────────────────────

/// Eén taak in [TakenIllustratie].
class TaakVoorbeeld {
  const TaakVoorbeeld(this.icon, this.kleur, this.titel);

  final IconData icon;
  final Color kleur;
  final String titel;
}

/// Een stukje van de takenlijst waarin de taken één voor één afgevinkt
/// worden. Met [opSlot] zijn de taken na de eerste vergrendeld tot de
/// vorige klaar is — zoals "Bezoekrapport tekenen" en "Werk afronden".
class TakenIllustratie extends StatelessWidget {
  const TakenIllustratie({
    super.key,
    required this.actief,
    required this.taken,
    this.opSlot = false,
  });

  final bool actief;
  final List<TaakVoorbeeld> taken;
  final bool opSlot;

  @override
  Widget build(BuildContext context) {
    return LusAnimatie(
      actief: actief,
      duur: const Duration(milliseconds: 5600),
      stilstand: 0.8,
      builder: (context, t) {
        final weg = _uitfaden(t);
        final lijn = AppColors.border.resolveFrom(context);
        return Padding(
          padding: _padding,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.card.resolveFrom(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: lijn),
            ),
            child: Column(
              children: [
                for (var i = 0; i < taken.length; i++) ...[
                  if (i > 0) Container(height: 0.5, color: lijn),
                  Expanded(
                    child: _TaakRij(
                      taak: taken[i],
                      klaar: fase(t, 0.18 + i * 0.22, 0.28 + i * 0.22) * weg,
                      ontgrendeld: !opSlot || i == 0
                          ? 1.0
                          : fase(
                                  t,
                                  0.18 + (i - 1) * 0.22,
                                  0.28 + (i - 1) * 0.22,
                                ) *
                                weg,
                      tik: fase(
                        t,
                        0.08 + i * 0.22,
                        0.26 + i * 0.22,
                        Curves.linear,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TaakRij extends StatelessWidget {
  const _TaakRij({
    required this.taak,
    required this.klaar,
    required this.ontgrendeld,
    required this.tik,
  });

  final TaakVoorbeeld taak;

  /// 0 = open, 1 = afgevinkt.
  final double klaar;

  /// 0 = op slot, 1 = beschikbaar.
  final double ontgrendeld;
  final double tik;

  @override
  Widget build(BuildContext context) {
    final groen = CupertinoColors.systemGreen.resolveFrom(context);
    final grijs = CupertinoColors.systemGrey3.resolveFrom(context);
    final opSlot = ontgrendeld < 0.5;
    return Opacity(
      opacity: 0.45 + 0.55 * ontgrendeld,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            _IcoonTegel(taak.icon, taak.kleur),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                taak.titel,
                style: _klein(
                  context,
                ).copyWith(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            MetTik(
              p: opSlot ? 0 : tik,
              grootte: 32,
              child: SizedBox(
                width: 22,
                height: 22,
                child: opSlot
                    ? Icon(CupertinoIcons.lock_fill, size: 15, color: grijs)
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: grijs, width: 1.5),
                            ),
                          ),
                          Transform.scale(
                            scale: Curves.easeOutBack.transform(klaar),
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: groen,
                              ),
                              child: const Icon(
                                CupertinoIcons.checkmark,
                                size: 13,
                                color: CupertinoColors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 7. Klaar ─────────────────────────────────────────────────────────────

class KlaarIllustratie extends StatelessWidget {
  const KlaarIllustratie({super.key, required this.actief});

  final bool actief;

  @override
  Widget build(BuildContext context) {
    return LusAnimatie(
      actief: actief,
      duur: const Duration(milliseconds: 3200),
      stilstand: 0,
      builder: (context, t) {
        return Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Twee zachte golven die uitdijen.
              for (final verschuiving in const [0.0, 0.5])
                Builder(
                  builder: (context) {
                    final p = (t + verschuiving) % 1.0;
                    return Container(
                      width: 70 + 70 * p,
                      height: 70 + 70 * p,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.accent.withValues(
                            alpha: 0.35 * (1 - p),
                          ),
                          width: 1.5,
                        ),
                      ),
                    );
                  },
                ),
              Transform.scale(
                scale: 1 + 0.03 * math.sin(t * 2 * math.pi),
                child: Container(
                  width: 70,
                  height: 70,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.accent,
                  ),
                  child: const Icon(
                    CupertinoIcons.checkmark_alt,
                    size: 36,
                    color: CupertinoColors.white,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
