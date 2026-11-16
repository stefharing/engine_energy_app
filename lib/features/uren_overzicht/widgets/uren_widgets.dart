import 'package:flutter/cupertino.dart';

import '../../../core/theme/app_colors.dart';
import '../models/uren_formaat.dart';
import '../models/uren_overzicht.dart';

const urenOranje = AppColors.accent;
const urenGroen = Color(0xFF34C759);
const urenAmber = Color(0xFFFF9500);

Color tekstKleur(BuildContext c) => CupertinoColors.label.resolveFrom(c);
Color subKleur(BuildContext c) => CupertinoColors.secondaryLabel.resolveFrom(c);
Color lijnKleur(BuildContext c) => CupertinoColors.separator.resolveFrom(c);

/// Schuine streepjes in een vlak: het teken voor indirecte uren.
class _SchaduwPainter extends CustomPainter {
  const _SchaduwPainter(this.kleur, this.radius);
  final Color kleur;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.save();
    canvas.clipRRect(rrect);
    final lijn = Paint()
      ..color = kleur
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    for (var x = -size.height; x < size.width + size.height; x += 6) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), lijn);
    }
    canvas.restore();
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..color = kleur
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_SchaduwPainter old) =>
      old.kleur != kleur || old.radius != radius;
}

/// Gevuld vlak (project) of gearceerd vlak (indirect).
class SoortVlak extends StatelessWidget {
  const SoortVlak({
    super.key,
    required this.soort,
    this.breedte,
    this.hoogte,
    this.radius = 3,
  });

  final UrenSoort soort;
  final double? breedte;
  final double? hoogte;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (soort == UrenSoort.project) {
      return Container(
        width: breedte,
        height: hoogte,
        decoration: BoxDecoration(
          color: urenOranje,
          borderRadius: BorderRadius.circular(radius),
        ),
      );
    }
    return SizedBox(
      width: breedte,
      height: hoogte,
      child: CustomPaint(painter: _SchaduwPainter(urenOranje, radius)),
    );
  }
}

/// Statusstip: groen = goedgekeurd, oranje = wacht, holle ring = concept.
class StatusStip extends StatelessWidget {
  const StatusStip(this.status, {super.key, this.maat = 8});
  final UrenStatus? status;
  final double maat;

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) return SizedBox(width: maat, height: maat);
    final kleur = switch (s) {
      UrenStatus.goedgekeurd => urenGroen,
      UrenStatus.wacht => urenAmber,
      UrenStatus.concept => subKleur(context),
    };
    return Container(
      width: maat,
      height: maat,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: s == UrenStatus.concept ? null : kleur,
        border: s == UrenStatus.concept
            ? Border.all(color: kleur, width: 1.5)
            : null,
      ),
    );
  }
}

class KaartVlak extends StatelessWidget {
  const KaartVlak({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card.resolveFrom(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: lijnKleur(context), width: 0.5),
      ),
      child: child,
    );
  }
}

/// Totaalkaart: uren van de norm, km, voortgangsbalk en legenda.
class SamenvattingKaart extends StatelessWidget {
  const SamenvattingKaart({
    super.key,
    required this.periode,
    required this.normMinuten,
  });

  final PeriodeOverzicht periode;
  final int normMinuten;

  @override
  Widget build(BuildContext context) {
    final norm = normMinuten <= 0 ? 1 : normMinuten;
    final project = (periode.projectMinuten / norm).clamp(0.0, 1.0);
    final indirect = (periode.indirectMinuten / norm).clamp(0.0, 1.0 - project);
    return KaartVlak(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                urenTekst(periode.totaalMinuten),
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '/ ${normMinuten ~/ 60} uur',
                  style: TextStyle(fontSize: 15, color: subKleur(context)),
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  kmTekst(periode.km),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: subKleur(context),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, c) => Container(
              height: 10,
              decoration: BoxDecoration(
                color: CupertinoColors.systemFill.resolveFrom(context),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                children: [
                  if (project > 0)
                    SoortVlak(
                      soort: UrenSoort.project,
                      breedte: c.maxWidth * project,
                      hoogte: 10,
                      radius: 5,
                    ),
                  if (indirect > 0)
                    SoortVlak(
                      soort: UrenSoort.indirect,
                      breedte: c.maxWidth * indirect,
                      hoogte: 10,
                      radius: 5,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const SoortVlak(soort: UrenSoort.project, breedte: 12, hoogte: 12),
              const SizedBox(width: 6),
              Text(
                'Project ${urenMetU(periode.projectMinuten)}',
                style: TextStyle(fontSize: 13, color: subKleur(context)),
              ),
              const SizedBox(width: 16),
              const SoortVlak(soort: UrenSoort.indirect, breedte: 12, hoogte: 12),
              const SizedBox(width: 6),
              Text(
                'Indirect ${urenMetU(periode.indirectMinuten)}',
                style: TextStyle(fontSize: 13, color: subKleur(context)),
              ),
            ],
          ),
          if (!periode.ridderBekend) ...[
            const SizedBox(height: 10),
            Text(
              'Ridder was niet bereikbaar: goedgekeurde en indirecte uren '
              'ontbreken. Alleen de uren uit de app worden getoond.',
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Gestapelde dagbalk: project onderaan, indirect (gearceerd) erboven.
class DagBalk extends StatelessWidget {
  const DagBalk({
    super.key,
    required this.dag,
    required this.pxPerUur,
    required this.breedte,
  });

  final DagOverzicht dag;
  final double pxPerUur;
  final double breedte;

  @override
  Widget build(BuildContext context) {
    final p = dag.projectMinuten / 60 * pxPerUur;
    final i = dag.indirectMinuten / 60 * pxPerUur;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (i > 0) SoortVlak(soort: UrenSoort.indirect, breedte: breedte, hoogte: i),
        if (i > 0 && p > 0) const SizedBox(height: 2),
        if (p > 0) SoortVlak(soort: UrenSoort.project, breedte: breedte, hoogte: p),
      ],
    );
  }
}

class _StreepjesLijn extends CustomPainter {
  const _StreepjesLijn(this.kleur);
  final Color kleur;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = kleur
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(x + 4, 0), p);
    }
  }

  @override
  bool shouldRepaint(_StreepjesLijn old) => old.kleur != kleur;
}

/// De zeven dagen van de week als staafgrafiek.
class WeekGrafiek extends StatelessWidget {
  const WeekGrafiek({
    super.key,
    required this.periode,
    required this.geselecteerd,
    required this.onKies,
  });

  final PeriodeOverzicht periode;
  final DateTime geselecteerd;
  final ValueChanged<DateTime> onKies;

  static const _basisPx = 12.0;
  static const _zone = 12 * _basisPx + 20;

  @override
  Widget build(BuildContext context) {
    final maxUren = periode.dagen
        .map((d) => d.totaalMinuten / 60)
        .fold<double>(0, (a, b) => a > b ? a : b);
    final px = maxUren > 12 ? (12 * _basisPx) / maxUren : _basisPx;
    final vandaag = alleenDatum(DateTime.now());
    final sel = alleenDatum(geselecteerd);

    return KaartVlak(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      child: Column(
        children: [
          SizedBox(
            height: _zone,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 8 * px,
                  child: CustomPaint(
                    size: const Size(double.infinity, 1),
                    painter: _StreepjesLijn(lijnKleur(context)),
                  ),
                ),
                Row(
                  children: [
                    for (final d in periode.dagen)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onKies(d.datum),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (d.totaalMinuten > 0)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 3),
                                  child: Text(
                                    urenTekst(d.totaalMinuten),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: subKleur(context),
                                    ),
                                  ),
                                ),
                              DagBalk(dag: d, pxPerUur: px, breedte: 26),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final d in periode.dagen)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onKies(d.datum),
                    child: Column(
                      children: [
                        StatusStip(d.status),
                        const SizedBox(height: 6),
                        Container(
                          constraints: const BoxConstraints(minHeight: 44),
                          alignment: Alignment.topCenter,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: d.datum == sel
                                  ? urenOranje.withValues(alpha: 0.15)
                                  : null,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  dagNamenKort[d.datum.weekday - 1],
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: subKleur(context),
                                  ),
                                ),
                                Text(
                                  '${d.datum.day}',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: d.datum == vandaag || d.datum == sel
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: d.datum == vandaag
                                        ? urenOranje
                                        : tekstKleur(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Wat er op één dag is geregistreerd, met knop om iets toe te voegen.
class DagDetail extends StatelessWidget {
  const DagDetail({
    super.key,
    required this.dag,
    required this.onToevoegen,
  });

  final DagOverzicht dag;
  final VoidCallback onToevoegen;

  @override
  Widget build(BuildContext context) {
    return KaartVlak(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Text(
                  dagKort(dag.datum),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  dag.totaalMinuten > 0 ? urenMetU(dag.totaalMinuten) : '',
                  style: TextStyle(fontSize: 15, color: subKleur(context)),
                ),
              ],
            ),
          ),
          if (dag.isLeeg)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                'Nog niets geregistreerd',
                style: TextStyle(fontSize: 15, color: subKleur(context)),
              ),
            ),
          for (final r in dag.uren)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  SoortVlak(soort: r.soort, breedte: 14, hoogte: 14),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.titel ?? (r.soort == UrenSoort.indirect ? 'Indirect' : 'Bon'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            StatusStip(r.status, maat: 7),
                            const SizedBox(width: 6),
                            Text(
                              statusTekst(r.status),
                              style: TextStyle(fontSize: 13, color: subKleur(context)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Text(
                    urenMetU(r.minuten),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          if (dag.km > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(CupertinoIcons.car_detailed, size: 16, color: subKleur(context)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Kilometers',
                      style: TextStyle(fontSize: 15, color: subKleur(context)),
                    ),
                  ),
                  Text(
                    kmTekst(dag.km),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            minimumSize: const Size(44, 44),
            onPressed: onToevoegen,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.add_circled, size: 18),
                SizedBox(width: 6),
                Text('Toevoegen aan deze dag'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Maandkalender: per dag het dagnummer, een staafje en de uren; rechts het
/// weektotaal.
class MaandKalender extends StatelessWidget {
  const MaandKalender({
    super.key,
    required this.periode,
    required this.maand,
    required this.geselecteerd,
    required this.onKies,
  });

  /// Periode van de maandag voor de 1e tot en met de zondag na de laatste.
  final PeriodeOverzicht periode;
  final DateTime maand;
  final DateTime geselecteerd;
  final ValueChanged<DateTime> onKies;

  static const _staafHoogte = 32.0;

  @override
  Widget build(BuildContext context) {
    final vandaag = alleenDatum(DateTime.now());
    final sel = alleenDatum(geselecteerd);
    final weken = <List<DagOverzicht>>[];
    for (var i = 0; i < periode.dagen.length; i += 7) {
      weken.add(periode.dagen.sublist(i, i + 7));
    }
    // Schaal zo dat de drukste dag precies in het staafvak past (maximaal
    // 3 px per uur, zodat rustige maanden niet opgeblazen worden).
    final maxUren = periode.dagen
        .map((d) => d.totaalMinuten / 60)
        .fold<double>(0, (a, b) => a > b ? a : b);
    final px = maxUren <= 0
        ? 3.0
        : (_staafHoogte / maxUren).clamp(0.5, 3.0).toDouble();

    return KaartVlak(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Column(
        children: [
          Row(
            children: [
              for (final n in dagNamenKort)
                Expanded(
                  child: Center(
                    child: Text(
                      n,
                      style: TextStyle(fontSize: 12, color: subKleur(context)),
                    ),
                  ),
                ),
              SizedBox(
                width: 48,
                child: Center(
                  child: Text(
                    'Week',
                    style: TextStyle(fontSize: 12, color: subKleur(context)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (var w = 0; w < weken.length; w++) ...[
            Container(height: 0.5, color: lijnKleur(context)),
            Row(
              children: [
                for (final d in weken[w])
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onKies(d.datum),
                      child: Opacity(
                        opacity: d.datum.month == maand.month ? 1 : 0.35,
                        child: Container(
                          height: 82,
                          margin: const EdgeInsets.symmetric(
                            horizontal: 1,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: d.datum == sel
                                ? urenOranje.withValues(alpha: 0.14)
                                : null,
                            borderRadius: BorderRadius.circular(10),
                            border: d.datum == sel
                                ? Border.all(color: urenOranje, width: 1.5)
                                : null,
                          ),
                          child: Column(
                            children: [
                              const SizedBox(height: 4),
                              Text(
                                '${d.datum.day}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: d.datum == vandaag
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: d.datum == vandaag
                                      ? urenOranje
                                      : tekstKleur(context),
                                ),
                              ),
                              const Spacer(),
                              SizedBox(
                                height: _staafHoogte,
                                child: ClipRect(
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: DagBalk(
                                      dag: d,
                                      pxPerUur: px,
                                      breedte: 16,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              SizedBox(
                                height: 14,
                                child: Text(
                                  d.totaalMinuten > 0
                                      ? urenTekst(d.totaalMinuten)
                                      : '',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: subKleur(context),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 3),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                SizedBox(
                  width: 48,
                  child: Center(
                    child: Text(
                      urenTekst(
                        weken[w].fold(0, (a, d) => a + d.totaalMinuten),
                      ),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
