import 'package:flutter/cupertino.dart';

import '../../core/theme/app_colors.dart';
import 'onboarding_illustraties.dart';

/// Welkomstuitleg die bij de eerste start van de app getoond wordt (zie
/// `AuthGate` in main.dart) en later terug te kijken is via het vraagteken
/// op het Dashboard.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onKlaar});

  /// Aangeroepen bij "Overslaan" en "Aan de slag".
  final VoidCallback onKlaar;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _pagina = 0;

  bool get _laatste => _pagina == _paginas.length - 1;

  void _volgende() {
    if (_laatste) {
      widget.onKlaar();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  void _vorige() {
    _controller.previousPage(
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);

    return CupertinoPageScaffold(
      backgroundColor: AppColors.page,
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  AnimatedOpacity(
                    opacity: _pagina == 0 ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      onPressed: _pagina == 0 ? null : _vorige,
                      child: Icon(
                        CupertinoIcons.chevron_left,
                        color: secundair,
                        size: 22,
                      ),
                    ),
                  ),
                  const Spacer(),
                  AnimatedOpacity(
                    opacity: _laatste ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      onPressed: _laatste ? null : widget.onKlaar,
                      child: Text(
                        'Overslaan',
                        style: TextStyle(fontSize: 16, color: secundair),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _paginas.length,
                onPageChanged: (i) => setState(() => _pagina = i),
                itemBuilder: (context, i) =>
                    _PaginaWeergave(pagina: _paginas[i], actief: i == _pagina),
              ),
            ),
            const SizedBox(height: 8),
            _Stippen(aantal: _paginas.length, huidig: _pagina),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(14),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  onPressed: _volgende,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _laatste ? 'Aan de slag' : 'Volgende',
                      key: ValueKey(_laatste),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Inhoud ───────────────────────────────────────────────────────────────

/// Een regel op een uitlegpagina: een genummerde stap, of een punt met een
/// eigen icoon (zoals de taken van een bon).
class _Punt {
  const _Punt(this.tekst, {this.titel, this.icon, this.kleur});

  final String? titel;
  final String tekst;
  final IconData? icon;
  final Color? kleur;
}

class _Pagina {
  const _Pagina({
    required this.label,
    required this.titel,
    required this.intro,
    required this.illustratie,
    this.punten = const [],
    this.genummerd = false,
    this.tip,
  });

  final String label;
  final String titel;
  final String intro;
  final Widget Function(bool actief) illustratie;
  final List<_Punt> punten;
  final bool genummerd;
  final String? tip;
}

const _oranje = AppColors.accent;
const _groen = Color(0xFF34C759);
const _blauw = Color(0xFF007AFF);
const _indigo = Color(0xFF5856D6);
const _amber = Color(0xFFFF9500);

final _paginas = <_Pagina>[
  _Pagina(
    label: 'WELKOM',
    titel: 'Moh! Welkom bij de Engine Energy app',
    intro:
        'In een paar korte stappen laten we zien hoe de app werkt. '
        'Onderaan het scherm vind je drie tabbladen:',
    illustratie: (actief) => WelkomIllustratie(actief: actief),
    punten: const [
      _Punt(
        'Je uren van deze week en het registreren van indirecte uren.',
        titel: 'Dashboard',
        icon: CupertinoIcons.house,
        kleur: _oranje,
      ),
      _Punt(
        'Wie waar aan werkt, per monteur en per dag.',
        titel: 'Planning',
        icon: CupertinoIcons.calendar,
        kleur: _blauw,
      ),
      _Punt(
        'Je werkbonnen: van artikelen picken tot het werk afronden.',
        titel: 'Bonnen',
        icon: CupertinoIcons.folder,
        kleur: _groen,
      ),
    ],
  ),
  _Pagina(
    label: 'DASHBOARD',
    titel: 'Indirecte uren registreren',
    intro: 'Uren die niet bij een bon horen, registreer je als indirecte uren.',
    illustratie: (actief) => IndirecteUrenIllustratie(actief: actief),
    genummerd: true,
    punten: const [
      _Punt('Tik op het Dashboard op "Uren & km registreren".'),
      _Punt(
        'Tik bovenin op "Selecteer een bon" en kies '
        '"Indirecte uren (geen bon)".',
      ),
      _Punt(
        'Kies de dag en tik op + om je uren toe te voegen, eventueel met '
        'een omschrijving.',
      ),
      _Punt(
        'Overnachting? Kies na + het tabblad "Overnachting". Indirecte uren '
        'en overnachtingen worden meteen in Ridder geboekt.',
      ),
    ],
    tip:
        'Op het Dashboard zie je per week hoeveel uur is goedgekeurd, '
        'verstuurd en nog niet verstuurd.',
  ),
  _Pagina(
    label: 'PLANNING',
    titel: 'De planning',
    intro: 'Alle bonnen en afspraken op een rij, per monteur en per dag.',
    illustratie: (actief) => PlanningIllustratie(actief: actief),
    punten: const [
      _Punt(
        'Elke rij is een monteur, elke kolom een dag. De planning opent '
        'bij vandaag.',
        icon: CupertinoIcons.calendar,
        kleur: _blauw,
      ),
      _Punt(
        'Swipe naar links of rechts voor eerdere of latere dagen.',
        icon: CupertinoIcons.arrow_left_right,
        kleur: _blauw,
      ),
      _Punt(
        'Tik op een van jouw bonnen om hem te openen.',
        icon: CupertinoIcons.hand_point_right,
        kleur: _oranje,
      ),
      _Punt(
        'Met ↻ ververs je de planning. Via ••• kies je welke collega\'s je '
        'ziet en in welke volgorde.',
        icon: CupertinoIcons.slider_horizontal_3,
        kleur: _indigo,
      ),
    ],
  ),
  _Pagina(
    label: 'BONNEN',
    titel: 'Je bonnen',
    intro: 'Op het tabblad Bonnen staan je werkbonnen, gegroepeerd per dag.',
    illustratie: (actief) => BonnenIllustratie(actief: actief),
    punten: const [
      _Punt(
        'Zoek op klant, omschrijving, bonnummer, locatie of monteur.',
        icon: CupertinoIcons.search,
        kleur: _blauw,
      ),
      _Punt(
        'Mag je alle bonnen zien? Wissel dan bovenin tussen "Mijn bonnen" '
        'en "Alle bonnen".',
        icon: CupertinoIcons.person_2,
        kleur: _indigo,
      ),
      _Punt(
        'Staan er meer monteurs op een bon, dan zie je hun initialen '
        'rechts op de kaart.',
        icon: CupertinoIcons.person_crop_circle,
        kleur: _groen,
      ),
      _Punt(
        'Tik op een bon om hem te openen.',
        icon: CupertinoIcons.hand_point_right,
        kleur: _oranje,
      ),
    ],
  ),
  _Pagina(
    label: 'BONNEN',
    titel: 'Een bon openen',
    intro:
        'Bovenaan zie je de status van de bon, de datum en hoeveel taken al '
        'klaar zijn. Daaronder:',
    illustratie: (actief) => BonDetailIllustratie(actief: actief),
    punten: const [
      _Punt(
        'De stappen die je tijdens en na het werk doorloopt. Hierover meer '
        'op de volgende pagina\'s.',
        titel: 'Taken',
        icon: CupertinoIcons.checkmark_square,
        kleur: _oranje,
      ),
      _Punt(
        'Type service, ordernummer en de monteurs op de bon.',
        titel: 'Klus',
        icon: CupertinoIcons.wrench,
        kleur: _blauw,
      ),
      _Punt(
        'De machine of installatie: serienummer, locatie, garantie, '
        'volgend onderhoud en documenten.',
        titel: 'Object',
        icon: CupertinoIcons.gear_alt,
        kleur: _indigo,
      ),
      _Punt(
        'Start de route in je navigatie-app of bel de contactpersoon '
        'direct.',
        titel: 'Adres & contact',
        icon: CupertinoIcons.location,
        kleur: _groen,
      ),
    ],
  ),
  _Pagina(
    label: 'TAKEN · TIJDENS HET WERK',
    titel: 'Artikelen, uren en materiaal',
    intro:
        'Een groen vinkje betekent dat een taak klaar is. Deze drie taken '
        'kun je in elke volgorde doen.',
    illustratie: (actief) => TakenIllustratie(
      actief: actief,
      taken: const [
        TaakVoorbeeld(CupertinoIcons.cube_box, _amber, 'Artikelen picken'),
        TaakVoorbeeld(CupertinoIcons.timer, _groen, 'Uren & km'),
        TaakVoorbeeld(CupertinoIcons.add_circled, _blauw, 'Gebruikt materiaal'),
      ],
    ),
    punten: const [
      _Punt(
        'Controleer de artikelen voor deze bon. Scan barcodes met de '
        'camera, pas aantallen aan en tik op "Bevestigen en afsluiten".',
        titel: 'Artikelen picken',
        icon: CupertinoIcons.cube_box,
        kleur: _amber,
      ),
      _Punt(
        'Vul per dag je uren, reistijd en kilometers in en tik op '
        '"Uren & km opslaan". Een overnachting voeg je toe via '
        '"Uren & km registreren" op het Dashboard.',
        titel: 'Uren & km',
        icon: CupertinoIcons.timer,
        kleur: _groen,
      ),
      _Punt(
        'Registreer wat je extra hebt gebruikt: uit het magazijn, of maak '
        'zelf een artikel aan.',
        titel: 'Gebruikt materiaal',
        icon: CupertinoIcons.add_circled,
        kleur: _blauw,
      ),
    ],
  ),
  _Pagina(
    label: 'TAKEN · WERK AFRONDEN',
    titel: 'Rapport, handtekening en afronden',
    intro:
        'Is het werk klaar? Dan rond je de bon in drie stappen af. Een '
        'slotje betekent dat eerst een eerdere stap nodig is.',
    illustratie: (actief) => TakenIllustratie(
      actief: actief,
      opSlot: true,
      taken: const [
        TaakVoorbeeld(
          CupertinoIcons.pencil_outline,
          _indigo,
          'Rapport schrijven',
        ),
        TaakVoorbeeld(
          CupertinoIcons.signature,
          _groen,
          'Bezoekrapport tekenen',
        ),
        TaakVoorbeeld(CupertinoIcons.flag, _oranje, 'Werk afronden'),
      ],
    ),
    punten: const [
      _Punt(
        'Noteer werkomschrijving, beginsituatie, bevindingen en '
        'aanbevelingen, en voeg foto\'s toe. Dit komt op het bezoekrapport.',
        titel: 'Rapport schrijven',
        icon: CupertinoIcons.pencil_outline,
        kleur: _indigo,
      ),
      _Punt(
        'Beschikbaar zodra er uren zijn ingevuld. Neem het rapport door met '
        'de klant en laat hem tekenen. Je kunt het ook als pdf delen of '
        'mailen.',
        titel: 'Bezoekrapport tekenen',
        icon: CupertinoIcons.signature,
        kleur: _groen,
      ),
      _Punt(
        'Beschikbaar na uren én handtekening. Controleer de samenvatting en '
        'tik op "Werk publiceren"; alles gaat dan naar Ridder.',
        titel: 'Werk afronden',
        icon: CupertinoIcons.flag,
        kleur: _oranje,
      ),
    ],
    tip:
        'Wat je invult blijft bewaard, dus je kunt een bon later verder '
        'afmaken.',
  ),
  _Pagina(
    label: 'KLAAR',
    titel: 'Je bent er klaar voor',
    intro:
        'Deze uitleg vind je altijd terug via het vraagteken linksboven op '
        'het Dashboard.',
    illustratie: (actief) => KlaarIllustratie(actief: actief),
  ),
];

// ─── Weergave van één pagina ──────────────────────────────────────────────

class _PaginaWeergave extends StatefulWidget {
  const _PaginaWeergave({required this.pagina, required this.actief});

  final _Pagina pagina;
  final bool actief;

  @override
  State<_PaginaWeergave> createState() => _PaginaWeergaveState();
}

class _PaginaWeergaveState extends State<_PaginaWeergave>
    with SingleTickerProviderStateMixin {
  /// Laat de onderdelen van de pagina één voor één invliegen, de eerste
  /// keer dat de pagina in beeld komt.
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.actief) _start();
  }

  @override
  void didUpdateWidget(covariant _PaginaWeergave oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.actief && !oldWidget.actief) _start();
  }

  void _start() {
    if (!_intro.isDismissed) return;
    final bewegingUit = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    if (bewegingUit) {
      _intro.value = 1;
    } else {
      _intro.forward();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pagina;
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    var volgorde = 0;
    Widget verschijn(Widget child) =>
        _Verschijn(animatie: _intro, index: volgorde++, child: child);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          verschijn(
            Container(
              height: 210,
              width: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppColors.card.resolveFrom(context),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.border.resolveFrom(context),
                ),
              ),
              child: p.illustratie(widget.actief),
            ),
          ),
          const SizedBox(height: 24),
          verschijn(
            Text(
              p.label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: AppColors.accent,
              ),
            ),
          ),
          const SizedBox(height: 6),
          verschijn(
            Text(
              p.titel,
              style: const TextStyle(
                fontSize: 26,
                height: 1.15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 10),
          verschijn(
            Text(
              p.intro,
              style: TextStyle(fontSize: 16, height: 1.4, color: secundair),
            ),
          ),
          if (p.punten.isNotEmpty) const SizedBox(height: 18),
          for (var i = 0; i < p.punten.length; i++)
            verschijn(
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _PuntRij(
                  punt: p.punten[i],
                  nummer: p.genummerd ? i + 1 : null,
                ),
              ),
            ),
          if (p.tip != null) verschijn(_TipKaart(tekst: p.tip!)),
        ],
      ),
    );
  }
}

/// Laat [child] rustig omhoog invliegen; [index] bepaalt wanneer.
class _Verschijn extends StatelessWidget {
  const _Verschijn({
    required this.animatie,
    required this.index,
    required this.child,
  });

  final Animation<double> animatie;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final start = (index * 0.07).clamp(0.0, 0.6);
    final curve = CurveTween(
      curve: Interval(
        start,
        (start + 0.4).clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      ),
    );
    return FadeTransition(
      opacity: animatie.drive(curve),
      child: SlideTransition(
        position: animatie.drive(
          Tween(begin: const Offset(0, 0.12), end: Offset.zero).chain(curve),
        ),
        child: child,
      ),
    );
  }
}

class _PuntRij extends StatelessWidget {
  const _PuntRij({required this.punt, this.nummer});

  final _Punt punt;
  final int? nummer;

  @override
  Widget build(BuildContext context) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final kleur = punt.kleur ?? AppColors.accent;

    final Widget voor;
    if (nummer != null) {
      voor = Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.accent.withValues(alpha: 0.14),
        ),
        child: Text(
          '$nummer',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.accent,
          ),
        ),
      );
    } else {
      voor = Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: kleur.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          punt.icon ?? CupertinoIcons.circle_fill,
          size: 17,
          color: kleur,
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        voor,
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: punt.titel == null ? 4 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (punt.titel != null) ...[
                  Text(
                    punt.titel!,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  punt.tekst,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: punt.titel == null ? null : secundair,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TipKaart extends StatelessWidget {
  const _TipKaart({required this.tekst});

  final String tekst;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            CupertinoIcons.lightbulb,
            size: 18,
            color: AppColors.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tekst,
              style: const TextStyle(fontSize: 14, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stippen extends StatelessWidget {
  const _Stippen({required this.aantal, required this.huidig});

  final int aantal;
  final int huidig;

  @override
  Widget build(BuildContext context) {
    final grijs = CupertinoColors.systemGrey4.resolveFrom(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < aantal; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == huidig ? 22 : 7,
            height: 7,
            decoration: BoxDecoration(
              color: i == huidig ? AppColors.accent : grijs,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
