import 'package:flutter/cupertino.dart';

import '../../../core/theme/app_colors.dart';
import '../../planning/models/job_order.dart';
import '../data/uren_overzicht_service.dart';
import '../models/uren_formaat.dart';
import '../models/uren_overzicht.dart';
import 'uren_widgets.dart';

/// Wat de monteur in het registreer-sheet koos.
class RegistreerKeuze {
  const RegistreerKeuze({required this.datum, this.bon});
  final DateTime datum;

  /// `null` = indirect (zonder bon).
  final ServiceOrder? bon;
}

/// Sheet "Registreren": kies dag, bon of indirect, en ga verder naar het
/// urenscherm (dat ook de kilometers doet).
class RegistreerSheet extends StatefulWidget {
  const RegistreerSheet({super.key, required this.datum});
  final DateTime datum;

  @override
  State<RegistreerSheet> createState() => _RegistreerSheetState();
}

class _RegistreerSheetState extends State<RegistreerSheet> {
  late DateTime _datum = alleenDatum(widget.datum);
  bool _indirect = false;
  bool _alle = false;
  ServiceOrder? _gekozen;
  List<ServiceOrder>? _bonnen;

  @override
  void initState() {
    super.initState();
    UrenOverzichtService.instance.bonnen().then((b) {
      if (mounted) setState(() => _bonnen = b);
    });
  }

  List<ServiceOrder> get _gesorteerd {
    final lijst = [...?_bonnen];
    int afstand(ServiceOrder o) {
      final s = o.startDate;
      if (s == null) return 1 << 30;
      return alleenDatum(s).difference(_datum).inDays.abs();
    }

    lijst.sort((a, b) => afstand(a).compareTo(afstand(b)));
    return lijst;
  }

  String _bonOndertitel(ServiceOrder o) {
    final s = o.startDate;
    if (s == null) return o.workflowState;
    final d = alleenDatum(s);
    if (d == alleenDatum(DateTime.now())) return 'Gepland vandaag';
    if (d == _datum) return 'Gepland op ${dagKort(d)}';
    return 'Gepland ${dagKort(d)}';
  }

  Future<void> _kiesDatum() async {
    var tijdelijk = _datum;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 280,
        color: AppColors.card.resolveFrom(ctx),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Klaar'),
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _datum,
                maximumDate: DateTime.now().add(const Duration(days: 365)),
                onDateTimeChanged: (d) => tijdelijk = alleenDatum(d),
              ),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() => _datum = tijdelijk);
  }

  bool get _kanVerder => _indirect || _gekozen != null;

  void _verder() {
    Navigator.of(context).pop(
      RegistreerKeuze(datum: _datum, bon: _indirect ? null : _gekozen),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hoogte = MediaQuery.of(context).size.height - 100;
    final bonnen = _gesorteerd;
    final zichtbaar = _alle ? bonnen : bonnen.take(4).toList();
    return Container(
      height: hoogte,
      decoration: BoxDecoration(
        color: AppColors.page.resolveFrom(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: lijnKleur(context),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Registreren',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(44, 44),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Icon(CupertinoIcons.xmark, size: 20, color: subKleur(context)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(44, 44),
                      onPressed: _kiesDatum,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.card.resolveFrom(context),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: lijnKleur(context), width: 0.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.calendar, size: 16, color: tekstKleur(context)),
                            const SizedBox(width: 8),
                            Text(
                              _datum == alleenDatum(DateTime.now())
                                  ? 'Vandaag · ${dagKort(_datum)}'
                                  : dagKort(_datum),
                              style: TextStyle(fontSize: 15, color: tekstKleur(context)),
                            ),
                            const SizedBox(width: 6),
                            Icon(CupertinoIcons.chevron_down, size: 12, color: subKleur(context)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _kop('Waarvoor?'),
                  Row(
                    children: [
                      Expanded(
                        child: _KeuzeKaart(
                          soort: UrenSoort.project,
                          titel: 'Op een bon',
                          sub: 'Project',
                          actief: !_indirect,
                          onTap: () => setState(() => _indirect = false),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _KeuzeKaart(
                          soort: UrenSoort.indirect,
                          titel: 'Indirect',
                          sub: 'Zonder bon',
                          actief: _indirect,
                          onTap: () => setState(() => _indirect = true),
                        ),
                      ),
                    ],
                  ),
                  if (!_indirect) ...[
                    _kop('Kies een bon'),
                    if (_bonnen == null)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CupertinoActivityIndicator()),
                      )
                    else if (bonnen.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Geen bonnen gevonden.',
                          style: TextStyle(color: subKleur(context)),
                        ),
                      )
                    else
                      Container(
                        decoration: BoxDecoration(
                          color: AppColors.card.resolveFrom(context),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: lijnKleur(context), width: 0.5),
                        ),
                        child: Column(
                          children: [
                            for (final o in zichtbaar)
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setState(() => _gekozen = o),
                                child: Container(
                                  constraints: const BoxConstraints(minHeight: 60),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              o.relationName.trim().isEmpty
                                                  ? o.orderNumber
                                                  : '${o.orderNumber} · ${o.relationName}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            Text(
                                              _bonOndertitel(o),
                                              style: TextStyle(fontSize: 13, color: subKleur(context)),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Icon(
                                        _gekozen?.id == o.id
                                            ? CupertinoIcons.check_mark_circled_solid
                                            : CupertinoIcons.circle,
                                        size: 22,
                                        color: _gekozen?.id == o.id
                                            ? urenOranje
                                            : lijnKleur(context),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (!_alle && bonnen.length > zichtbaar.length)
                              CupertinoButton(
                                onPressed: () => setState(() => _alle = true),
                                child: const Text('Alle bonnen bekijken'),
                              ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  color: AppColors.accent,
                  disabledColor: CupertinoColors.systemFill.resolveFrom(context),
                  borderRadius: BorderRadius.circular(16),
                  onPressed: _kanVerder ? _verder : null,
                  child: const Text(
                    'Verder',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.white,
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

  Widget _kop(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
    child: Text(
      t.toUpperCase(),
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: subKleur(context),
      ),
    ),
  );
}

class _KeuzeKaart extends StatelessWidget {
  const _KeuzeKaart({
    required this.soort,
    required this.titel,
    required this.sub,
    required this.actief,
    required this.onTap,
  });

  final UrenSoort soort;
  final String titel;
  final String sub;
  final bool actief;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 84),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card.resolveFrom(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: actief ? AppColors.accent : lijnKleur(context),
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SoortVlak(soort: soort, breedte: 14, hoogte: 14),
            const SizedBox(height: 10),
            Text(titel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(sub, style: TextStyle(fontSize: 13, color: subKleur(context))),
          ],
        ),
      ),
    );
  }
}
