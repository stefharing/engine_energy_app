import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:printing/printing.dart';

import '../../../core/theme/app_colors.dart';
import '../data/signature_draft_service.dart';
import '../data/visit_report_service.dart';
import '../models/job_order.dart';
import '../models/signature_capture.dart';
import '../models/visit_report.dart';
import '../models/work_report_draft.dart';
import 'signature_pad_screen.dart';
import 'visit_report_pdf_screen.dart';

const _accentOrange = Color(0xFFFF6B2B);
const _dagen = ['', 'ma', 'di', 'wo', 'do', 'vr', 'za', 'zo'];

String _datum(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.year}';

/// Het bezoekrapport zoals de klant het te zien krijgt: bon- en klantgegevens,
/// uitgevoerde werkzaamheden, uren, gebruikte materialen — en onderaan de
/// handtekening met naam en e-mailadres van wie namens de klant tekent.
///
/// Dezelfde gegevens gaan bij "Werk afronden" als HTML (`htmlFile`) naar
/// Ridder, dat er de pdf "Getekende werkbon" van maakt en die naar het
/// e-mailadres kan sturen. Geeft `true` terug als er een handtekening is.
class VisitReportScreen extends StatefulWidget {
  const VisitReportScreen({super.key, required this.order, this.contactName});

  final ServiceOrder order;

  /// Contactpersoon van de bon; voorinvulling voor de naam.
  final String? contactName;

  @override
  State<VisitReportScreen> createState() => _VisitReportScreenState();
}

class _VisitReportScreenState extends State<VisitReportScreen> {
  final _naamCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  VisitReportData? _data;
  SignatureCapture? _handtekening;
  bool _laden = true;
  String? _fout;
  bool _pdfBezig = false;

  String get _orderId => widget.order.id;

  bool get _emailGeldig {
    final e = _emailCtrl.text.trim();
    return e.isEmpty || RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e);
  }

  bool get _kanOpslaan =>
      _handtekening != null && _naamCtrl.text.trim().isNotEmpty && _emailGeldig;

  @override
  void initState() {
    super.initState();
    _naamCtrl.addListener(() => setState(() {}));
    _emailCtrl.addListener(() => setState(() {}));
    _laad();
  }

  @override
  void dispose() {
    _naamCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _laad() async {
    final service = VisitReportService.instance;
    final ondertekenaar = await service.laadOndertekenaar(_orderId);
    final handtekening = await SignatureDraftService.instance.load(_orderId);
    _naamCtrl.text = ondertekenaar?.name ?? widget.contactName ?? '';
    _emailCtrl.text = ondertekenaar?.email ?? '';
    if (mounted) setState(() => _handtekening = handtekening);
    try {
      final data = await service.verzamel(widget.order);
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _fout = e.toString());
    } finally {
      if (mounted) setState(() => _laden = false);
    }
  }

  Future<void> _teken() async {
    final capture = await Navigator.of(context).push<SignatureCapture>(
      CupertinoPageRoute<SignatureCapture>(
        builder: (_) => SignaturePadScreen(
          initialSignature: _handtekening?.png,
          initialPaths: _handtekening?.paths,
        ),
      ),
    );
    if (capture == null) return;
    await SignatureDraftService.instance.save(_orderId, capture);
    if (mounted) setState(() => _handtekening = capture);
  }

  String get _bestandsnaam =>
      'Bezoekrapport_${(_data?.bonNummer ?? _orderId).replaceAll(RegExp(r'[^\w-]'), '_')}.pdf';

  /// Pdf met de huidige stand: ingevulde naam/e-mail en — als die er al is
  /// — de handtekening. Kan dus ook vóór het tekenen.
  Future<Uint8List?> _maakPdf() async {
    final data = _data;
    if (data == null) return null;
    setState(() => _pdfBezig = true);
    try {
      return await VisitReportService.instance.maakPdf(
        data,
        handtekeningPng: _handtekening?.png,
        ondertekenaar: VisitReportSigner(
          name: _naamCtrl.text.trim(),
          email: _emailCtrl.text.trim(),
        ),
      );
    } catch (e) {
      if (mounted) {
        showCupertinoDialog<void>(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: const Text('Pdf maken mislukt'),
            content: Text('$e'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _pdfBezig = false);
    }
  }

  Future<void> _bekijkPdf() async {
    final pdf = await _maakPdf();
    if (pdf == null || !mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) =>
            VisitReportPdfScreen(pdf: pdf, bestandsnaam: _bestandsnaam),
      ),
    );
  }

  /// Deelmenu van het toestel: mailen (klant of zelf), opslaan, WhatsApp…
  Future<void> _deelPdf() async {
    final pdf = await _maakPdf();
    if (pdf == null) return;
    await Printing.sharePdf(bytes: pdf, filename: _bestandsnaam);
  }

  Future<void> _opslaan() async {
    await VisitReportService.instance.bewaarOndertekenaar(
      _orderId,
      VisitReportSigner(
        name: _naamCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
      ),
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        leading: CupertinoNavigationBarBackButton(
          color: AppColors.navForeground,
          onPressed: () => Navigator.of(context).pop(_handtekening != null),
        ),
        middle: Text(
          'Bezoekrapport',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.navForeground.resolveFrom(context),
          ),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _laden
                  ? const Center(child: CupertinoActivityIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [
                        if (_fout != null)
                          _Kaart(
                            isDark: isDark,
                            children: [
                              Text(
                                'Niet alle gegevens konden worden geladen. '
                                'De klant kan wel tekenen.\n$_fout',
                                style: const TextStyle(
                                  color: CupertinoColors.systemRed,
                                ),
                              ),
                            ],
                          ),
                        if (_data != null) ..._rapport(_data!, isDark),
                        if (_data != null) _pdfKaart(isDark),
                        _handtekeningKaart(isDark),
                      ],
                    ),
            ),
            _Voet(
              isDark: isDark,
              enabled: _kanOpslaan,
              hint: _handtekening == null
                  ? 'Laat de klant eerst tekenen'
                  : _naamCtrl.text.trim().isEmpty
                  ? 'Vul de naam van de ondertekenaar in'
                  : !_emailGeldig
                  ? 'Controleer het e-mailadres'
                  : null,
              onPressed: _opslaan,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _rapport(VisitReportData d, bool isDark) {
    final r = d.rapport;
    final bevindingen =
        r?.findings.where((f) => f.text.trim().isNotEmpty).toList() ??
        const <Finding>[];
    return [
      _Kaart(
        isDark: isDark,
        titel: 'Servicebon ${d.bonNummer}',
        tussen: 8,
        children: [
          for (final (label, waarde) in [
            ('Klant', d.klant),
            ('Adres', d.adres),
            ('Omschrijving', d.omschrijving),
            ('Object', d.object),
            ('Monteur', d.monteur),
            ('Datum', _datum(d.datum)),
          ])
            if (waarde.trim().isNotEmpty) _InfoRij(label, waarde),
        ],
      ),
      if (r != null &&
          (r.workDescription.trim().isNotEmpty ||
              r.startingSituation.trim().isNotEmpty ||
              bevindingen.isNotEmpty ||
              r.recommendations.trim().isNotEmpty))
        _Kaart(
          isDark: isDark,
          titel: 'Werkzaamheden',
          tussen: 16,
          children: [
            for (final (kop, tekst) in [
              ('Uitgevoerd', r.workDescription),
              ('Beginsituatie', r.startingSituation),
              (
                'Bevindingen',
                bevindingen.map((f) => '•  ${f.text.trim()}').join('\n'),
              ),
              ('Aanbevelingen', r.recommendations),
            ])
              if (tekst.trim().isNotEmpty) _TekstBlok(kop, tekst),
          ],
        ),
      if (d.uren.isNotEmpty)
        _Kaart(
          isDark: isDark,
          titel: 'Uren',
          children: [
            for (final (i, u) in d.uren.indexed)
              _LijstRij(
                eerste: i == 0,
                links: u.soort,
                onder: [
                  '${_dagen[u.datum.weekday]} ${_datum(u.datum)}',
                  if ((u.memo ?? '').trim().isNotEmpty) u.memo!.trim(),
                ].join('\n'),
                rechts: u.isKm ? '${u.km} km' : formatUrenMinuten(u.minuten),
              ),
            _LijstRij(
              links: 'Totaal',
              rechts:
                  '${formatUrenMinuten(d.totaalMinuten)}'
                  '${d.totaalKm > 0 ? ' · ${d.totaalKm} km' : ''}',
              vet: true,
              laatste: true,
            ),
          ],
        ),
      if (d.materialen.isNotEmpty)
        _Kaart(
          isDark: isDark,
          titel: 'Gebruikte materialen',
          children: [
            for (var i = 0; i < d.materialen.length; i++)
              _LijstRij(
                eerste: i == 0,
                links: d.materialen[i].omschrijving,
                onder: d.materialen[i].code.isEmpty
                    ? null
                    : d.materialen[i].code,
                rechts: '${d.materialen[i].aantal} ${d.materialen[i].eenheid}',
                laatste: i == d.materialen.length - 1,
              ),
          ],
        ),
    ];
  }

  Widget _pdfKaart(bool isDark) => _Kaart(
    isDark: isDark,
    titel: 'Rapport als pdf',
    children: [
      Text(
        'Bekijk het rapport of deel het, bijvoorbeeld per mail naar de klant '
        'of jezelf. Is er al getekend, dan staat de handtekening erin.',
        style: _Tekst.sub(context),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _PdfKnop(
              icoon: CupertinoIcons.doc_text_search,
              label: 'Bekijken',
              bezig: _pdfBezig,
              onPressed: _bekijkPdf,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _PdfKnop(
              icoon: CupertinoIcons.share,
              label: 'Delen / mailen',
              bezig: _pdfBezig,
              onPressed: _deelPdf,
            ),
          ),
        ],
      ),
    ],
  );

  Widget _handtekeningKaart(bool isDark) {
    final veldKleur = isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFF2F2F7);
    return _Kaart(
      isDark: isDark,
      titel: 'Akkoord klant',
      children: [
        Text(
          'Door te tekenen gaat de klant akkoord met de hierboven vermelde '
          'werkzaamheden en materialen.',
          style: _Tekst.sub(context),
        ),
        const SizedBox(height: 12),
        CupertinoTextField(
          controller: _naamCtrl,
          placeholder: 'Naam ondertekenaar',
          textCapitalization: TextCapitalization.words,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: veldKleur,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        const SizedBox(height: 8),
        CupertinoTextField(
          controller: _emailCtrl,
          placeholder: 'E-mailadres (voor het rapport per mail)',
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: veldKleur,
            borderRadius: BorderRadius.circular(10),
            border: _emailGeldig
                ? null
                : Border.all(color: CupertinoColors.systemRed),
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _teken,
          child: Container(
            height: 150,
            width: double.infinity,
            decoration: BoxDecoration(
              color: CupertinoColors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFD1D1D6)),
            ),
            child: _handtekening == null
                ? const Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.signature, color: _accentOrange),
                        SizedBox(width: 8),
                        Text(
                          'Tik om te tekenen',
                          style: TextStyle(
                            color: _accentOrange,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(8),
                    child: Image.memory(_handtekening!.png, fit: BoxFit.contain),
                  ),
          ),
        ),
        if (_handtekening != null)
          Align(
            alignment: Alignment.centerRight,
            child: CupertinoButton(
              padding: const EdgeInsets.only(top: 8),
              onPressed: _teken,
              child: const Text(
                'Opnieuw tekenen',
                style: TextStyle(color: _accentOrange, fontSize: 15),
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Bouwstenen ───────────────────────────────────────────────────────────

/// Eén typografische schaal voor het hele rapport, zodat alle kaarten
/// hetzelfde ritme hebben: titel 17, tekst 15, labels/subregels 13.
abstract final class _Tekst {
  static const titel = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  static const body = TextStyle(fontSize: 15, height: 1.35);

  static TextStyle label(BuildContext context) => TextStyle(
    fontSize: 13,
    height: 1.35,
    color: CupertinoColors.secondaryLabel.resolveFrom(context),
  );

  static TextStyle sub(BuildContext context) => TextStyle(
    fontSize: 13,
    height: 1.35,
    color: CupertinoColors.secondaryLabel.resolveFrom(context),
  );

  static const waarde = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Vaste afstanden.
abstract final class _Ruimte {
  static const kaartPadding = 16.0;
  static const tussenKaarten = 12.0;
  static const onderTitel = 12.0;
  static const tussenRegels = 10.0;
}

class _Kaart extends StatelessWidget {
  const _Kaart({
    required this.isDark,
    required this.children,
    this.titel,
    this.tussen = 0,
  });

  final bool isDark;
  final String? titel;
  final List<Widget> children;

  /// Ruimte tussen de kinderen (niet erboven of eronder).
  final double tussen;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: _Ruimte.tussenKaarten),
    padding: const EdgeInsets.all(_Ruimte.kaartPadding),
    decoration: BoxDecoration(
      color: isDark ? const Color(0xFF1C1C1E) : CupertinoColors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (titel != null) ...[
          Text(titel!, style: _Tekst.titel),
          const SizedBox(height: _Ruimte.onderTitel),
        ],
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0 && tussen > 0) SizedBox(height: tussen),
          children[i],
        ],
      ],
    ),
  );
}

/// Label links (vaste breedte), waarde rechts ernaast.
class _InfoRij extends StatelessWidget {
  const _InfoRij(this.label, this.waarde);

  final String label;
  final String waarde;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: _Tekst.label(context).copyWith(fontSize: 15),
            ),
          ),
          Expanded(child: Text(waarde, style: _Tekst.body)),
        ],
      ),
    );
  }
}

/// Klein label met een tekstblok eronder.
class _TekstBlok extends StatelessWidget {
  const _TekstBlok(this.kop, this.tekst);

  final String kop;
  final String tekst;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            kop,
            style: _Tekst.label(context).copyWith(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(tekst.trim(), style: _Tekst.body),
        ],
      ),
    );
  }
}

/// Regel in een lijst (uren, materialen): hoofdregel + subregel links,
/// waarde rechts, met een dunne lijn eronder (behalve de laatste).
class _LijstRij extends StatelessWidget {
  const _LijstRij({
    required this.links,
    required this.rechts,
    this.onder,
    this.vet = false,
    this.eerste = false,
    this.laatste = false,
  });

  /// Eerste regel direct onder de kaarttitel: geen extra ruimte erboven.
  final bool eerste;
  final String links;
  final String rechts;
  final String? onder;
  final bool vet;
  final bool laatste;

  @override
  Widget build(BuildContext context) {
    final lijn = CupertinoColors.separator.resolveFrom(context);
    return Container(
      padding: EdgeInsets.only(
        top: eerste
            ? 0
            : vet
            ? _Ruimte.tussenRegels + 2
            : _Ruimte.tussenRegels,
        bottom: laatste ? 0 : _Ruimte.tussenRegels,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: vet ? BorderSide(color: lijn) : BorderSide.none,
          bottom: laatste || vet
              ? BorderSide.none
              : BorderSide(color: lijn, width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  links,
                  style: vet
                      ? _Tekst.body.copyWith(fontWeight: FontWeight.w600)
                      : _Tekst.body,
                ),
                if ((onder ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(onder!.trim(), style: _Tekst.sub(context)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text(
            rechts,
            style: vet
                ? _Tekst.waarde.copyWith(fontWeight: FontWeight.w700)
                : _Tekst.waarde,
          ),
        ],
      ),
    );
  }
}

class _PdfKnop extends StatelessWidget {
  const _PdfKnop({
    required this.icoon,
    required this.label,
    required this.onPressed,
    this.bezig = false,
  });

  final IconData icoon;
  final String label;
  final bool bezig;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.symmetric(vertical: 11),
    color: _accentOrange.withValues(alpha: 0.12),
    borderRadius: BorderRadius.circular(10),
    onPressed: bezig ? null : onPressed,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icoon, size: 18, color: _accentOrange),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: _accentOrange,
          ),
        ),
      ],
    ),
  );
}

class _Voet extends StatelessWidget {
  const _Voet({
    required this.isDark,
    required this.enabled,
    required this.onPressed,
    this.hint,
  });

  final bool isDark;
  final bool enabled;
  final String? hint;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
    decoration: BoxDecoration(
      color: isDark ? const Color(0xFF1C1C1E) : CupertinoColors.white,
      border: Border(
        top: BorderSide(
          color: isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA),
        ),
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hint != null) ...[
          Text(
            hint!,
            style: TextStyle(
              fontSize: 13,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          width: double.infinity,
          child: CupertinoButton(
            color: _accentOrange,
            disabledColor: CupertinoColors.systemGrey4,
            borderRadius: BorderRadius.circular(12),
            onPressed: enabled ? onPressed : null,
            child: const Text(
              'Rapport getekend – opslaan',
              style: TextStyle(
                color: CupertinoColors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
