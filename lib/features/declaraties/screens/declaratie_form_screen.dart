import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/app_colors.dart';
import '../../planning/models/job_order.dart' show ServiceOrder;
import '../../planning/screens/live_receipt_scanner_screen.dart';
import '../data/declaratie_service.dart';
import '../data/receipt_scan.dart';
import '../models/declaratie.dart';

/// Nieuwe declaratie op een servicebon: foto/scan van het bonnetje vult
/// bedrag, datum en omschrijving voor; de monteur controleert, kiest de
/// betaalwijze en dient in. Sluit met `true` als er iets is bewaard.
class DeclaratieFormScreen extends StatefulWidget {
  final ServiceOrder order;

  /// Uit de scanner: gegevens en foto waarmee het formulier voorgevuld opent.
  final BonGegevens? beginGegevens;
  final File? beginFoto;

  const DeclaratieFormScreen({
    super.key,
    required this.order,
    this.beginGegevens,
    this.beginFoto,
  });

  @override
  State<DeclaratieFormScreen> createState() => _DeclaratieFormScreenState();
}

class _DeclaratieFormScreenState extends State<DeclaratieFormScreen> {
  final _omschrijving = TextEditingController();
  final _bedrag = TextEditingController();
  DateTime _datum = DateTime.now();
  Betaalwijze _betaalwijze = Betaalwijze.betaalpas;
  File? _foto;

  bool _scant = false;
  bool _bezig = false;
  String? _scanMelding;
  String? _fout;

  @override
  void initState() {
    super.initState();
    final g = widget.beginGegevens;
    if (g != null || widget.beginFoto != null) {
      _pasToe(g ?? const BonGegevens(), widget.beginFoto);
    }
  }

  @override
  void dispose() {
    _omschrijving.dispose();
    _bedrag.dispose();
    super.dispose();
  }

  double? get _bedragWaarde {
    final v = double.tryParse(_bedrag.text.trim().replaceAll(',', '.'));
    return (v != null && v > 0) ? v : null;
  }

  bool get _kanIndienen =>
      !_bezig && !_scant && _omschrijving.text.trim().isNotEmpty && _bedragWaarde != null;

  // ------------------------------------------------------------- scannen

  /// Opent de schermvullende scanner; daar kies je scannen, fotoarchief of
  /// handmatig (dan blijft alles zoals het is).
  Future<void> _kiesBron() async {
    final r = await Navigator.of(context).push<LiveReceiptScanResult>(
      CupertinoPageRoute(
        fullscreenDialog: true,
        builder: (_) => const LiveReceiptScannerScreen(),
      ),
    );
    if (r == null || !mounted) return;
    switch (r.bron) {
      case BonScanBron.handmatig:
        return;
      case BonScanBron.galerij:
        await _scanFoto(ImageSource.gallery);
      case BonScanBron.scan:
        final foto = r.imageFile;
        final receipt = r.receipt;
        var gegevens = receipt == null
            ? const BonGegevens()
            : ReceiptScan.uitBon(receipt);
        if (gegevens.isLeeg && foto != null) {
          setState(() => _scant = true);
          try {
            gegevens = await ReceiptScan.scanFoto(foto.path);
          } catch (_) {
            // Foto is gelukt; invullen kan ook handmatig.
          }
        }
        if (mounted) _pasToe(gegevens, foto);
    }
  }

  Future<void> _scanFoto(ImageSource bron) async {
    setState(() {
      _scant = true;
      _fout = null;
      _scanMelding = null;
    });
    try {
      final beeld = await ImagePicker().pickImage(
        source: bron,
        imageQuality: 90,
      );
      if (beeld == null) {
        if (mounted) setState(() => _scant = false);
        return;
      }
      final foto = File(beeld.path);
      BonGegevens gegevens;
      try {
        gegevens = await ReceiptScan.scanFoto(beeld.path);
      } catch (_) {
        // Foto is wel gelukt; alleen de herkenning niet.
        gegevens = const BonGegevens();
      }
      if (mounted) _pasToe(gegevens, foto);
    } catch (_) {
      if (mounted) {
        setState(() {
          _scant = false;
          _fout = 'Foto maken mislukt. Vul de gegevens handmatig in.';
        });
      }
    }
  }

  /// Zet de herkende gegevens in het formulier, zonder wat de monteur zelf
  /// al heeft ingevuld te overschrijven.
  void _pasToe(BonGegevens g, File? foto) {
    setState(() {
      _scant = false;
      if (foto != null) _foto = foto;
      if (g.totaal != null && _bedrag.text.trim().isEmpty) {
        _bedrag.text = g.totaal!.toStringAsFixed(2).replaceAll('.', ',');
      }
      if (g.datum != null) _datum = g.datum!;
      if (g.omschrijving.isNotEmpty && _omschrijving.text.trim().isEmpty) {
        _omschrijving.text = g.omschrijving;
      }
      _scanMelding = g.isLeeg
          ? 'Foto toegevoegd, maar er is niets herkend. Vul de gegevens in.'
          : 'Gegevens uit de bon ingevuld. Controleer ze even.';
    });
  }

  // ------------------------------------------------------------ keuzes

  Future<void> _kiesBetaalwijze() async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Hoe heb je betaald?'),
        actions: [
          for (final b in Betaalwijze.values)
            CupertinoActionSheetAction(
              isDefaultAction: b == _betaalwijze,
              onPressed: () {
                setState(() => _betaalwijze = b);
                Navigator.of(ctx).pop();
              },
              child: Text(b.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
  }

  Future<void> _kiesDatum() async {
    var tijdelijk = _datum;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 340,
        color: CupertinoColors.systemBackground.resolveFrom(ctx),
        child: Column(
          children: [
            SizedBox(
              height: 260,
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _datum,
                maximumDate: DateTime.now().add(const Duration(days: 1)),
                onDateTimeChanged: (d) => tijdelijk = d,
              ),
            ),
            CupertinoButton(
              child: const Text('Klaar'),
              onPressed: () {
                setState(() => _datum = tijdelijk);
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- indienen

  Future<void> _indienen() async {
    final bedrag = _bedragWaarde;
    if (bedrag == null) return;
    setState(() {
      _bezig = true;
      _fout = null;
    });
    final service = DeclaratieService.instance;
    try {
      final id = const Uuid().v4();
      final fotoPad = _foto == null
          ? null
          : await service.bewaarFoto(_foto!, id);
      final declaratie = Declaratie(
        id: id,
        datum: _datum,
        omschrijving: _omschrijving.text.trim(),
        bedrag: bedrag,
        betaalwijze: _betaalwijze,
        bonId: widget.order.id,
        bonNummer: widget.order.orderNumber,
        fotoPad: fotoPad,
        aangemaaktOp: DateTime.now(),
      );
      // Eerst lokaal vastleggen: een mislukte verzending raakt de bon niet kwijt.
      await service.bewaar(declaratie);
      final fout = await service.verstuur(declaratie);
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text(fout == null ? 'Declaratie ingediend' : 'Opgeslagen'),
          content: Text(
            fout == null
                ? 'De declaratie staat klaar in Ridder.'
                : 'Versturen lukte nu niet: $fout\n\nDe declaratie staat '
                      'bewaard en wordt later opnieuw verstuurd.',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _bezig = false;
          _fout = 'Bewaren mislukt: ${e.toString().replaceFirst('Exception: ', '')}';
        });
      }
    }
  }

  // ------------------------------------------------------------------ UI

  String _fmtDatum(DateTime d) {
    const m = ['jan', 'feb', 'mrt', 'apr', 'mei', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }

  Widget _kopje(String tekst) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
    child: Text(
      tekst.toUpperCase(),
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    ),
  );

  Widget _rij(String label, Widget waarde, {VoidCallback? onTap, bool rand = true}) {
    final lijn = CupertinoColors.separator.resolveFrom(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: rand ? Border(bottom: BorderSide(color: lijn, width: 0.5)) : null,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ),
            Expanded(child: waarde),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final kaart = CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final lijn = CupertinoColors.separator.resolveFrom(context);
    final vlak = CupertinoColors.systemGrey5.resolveFrom(context);
    final groen = CupertinoColors.systemGreen.resolveFrom(context);
    final onderkant = MediaQuery.paddingOf(context).bottom;
    final bedrag = _bedragWaarde;
    final heeftFoto = _foto != null;

    BoxDecoration kaartVlak() => BoxDecoration(
      color: kaart,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: lijn, width: 0.5),
    );

    return CupertinoPageScaffold(
      backgroundColor: AppColors.page,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        middle: const Text('Nieuwe declaratie'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _bezig ? null : () => Navigator.of(context).pop(false),
          child: const Text('Annuleer'),
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => FocusScope.of(context).unfocus(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    // Bedrag groot bovenaan.
                    Column(
                      children: [
                        Text('Bedrag (incl. btw)', style: TextStyle(fontSize: 13, color: secundair)),
                        CupertinoTextField(
                          controller: _bedrag,
                          textAlign: TextAlign.center,
                          placeholder: '0,00',
                          prefix: const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Text('€', style: TextStyle(fontSize: 48, fontWeight: FontWeight.w700)),
                          ),
                          style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w700, letterSpacing: -1.5),
                          placeholderStyle: TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.w700,
                            color: CupertinoColors.placeholderText.resolveFrom(context),
                          ),
                          decoration: null,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                          onChanged: (_) => setState(() {}),
                        ),
                        if (_scanMelding != null && !_scant)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(CupertinoIcons.checkmark_circle, size: 16, color: groen),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(_scanMelding!, style: TextStyle(fontSize: 13, color: groen)),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    // Bon / scan.
                    GestureDetector(
                      onTap: _scant || _bezig ? null : _kiesBron,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: kaartVlak(),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 58,
                              decoration: BoxDecoration(
                                color: vlak,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: heeftFoto
                                  ? Image.file(_foto!, fit: BoxFit.cover, cacheWidth: 200)
                                  : Icon(CupertinoIcons.doc_text_viewfinder, color: secundair),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    heeftFoto ? 'Bon toegevoegd' : 'Foto of scan van bon',
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                  ),
                                  Text(
                                    heeftFoto
                                        ? 'Wordt als bijlage meegestuurd'
                                        : 'Vult bedrag en datum voor je in',
                                    style: TextStyle(fontSize: 13, color: secundair),
                                  ),
                                ],
                              ),
                            ),
                            if (_scant)
                              const CupertinoActivityIndicator()
                            else
                              Text(
                                heeftFoto ? 'Opnieuw' : 'Scan',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.accent,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    _kopje('Hoe heb je betaald?'),
                    _BetaalKiezer(
                      waarde: _betaalwijze,
                      onKies: (b) => setState(() => _betaalwijze = b),
                    ),
                    if (_betaalwijze == Betaalwijze.prive)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                        child: Text(
                          'Privé betaald: dit bedrag wordt aan jou terugbetaald.',
                          style: TextStyle(fontSize: 13, color: secundair),
                        ),
                      ),
                    const SizedBox(height: 22),
                    Container(
                      decoration: kaartVlak(),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          _rij(
                            'Omschrijving',
                            CupertinoTextField(
                              controller: _omschrijving,
                              placeholder: 'Bijv. tanken, lunch',
                              decoration: null,
                              padding: EdgeInsets.zero,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                              textCapitalization: TextCapitalization.sentences,
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          _rij(
                            'Datum',
                            Row(
                              children: [
                                Text(
                                  _fmtDatum(_datum),
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                                ),
                                const Spacer(),
                                Icon(CupertinoIcons.chevron_right, size: 14, color: secundair),
                              ],
                            ),
                            onTap: _kiesDatum,
                          ),
                          _rij(
                            'Op bon',
                            Text(
                              widget.order.description.isNotEmpty
                                  ? '${widget.order.orderNumber} · ${widget.order.description}'
                                  : '${widget.order.orderNumber}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                            ),
                            rand: false,
                          ),
                        ],
                      ),
                    ),
                    if (_fout != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                        child: Text(
                          _fout!,
                          style: const TextStyle(fontSize: 13, color: CupertinoColors.systemRed),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + onderkant),
            color: CupertinoDynamicColor.resolve(AppColors.page, context),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoButton(
                color: AppColors.accent,
                disabledColor: CupertinoColors.systemFill.resolveFrom(context),
                borderRadius: BorderRadius.circular(16),
                padding: const EdgeInsets.symmetric(vertical: 16),
                onPressed: _kanIndienen ? _indienen : null,
                child: _bezig
                    ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                    : Text(
                        bedrag == null
                            ? 'Indienen'
                            : 'Indienen · € ${bedrag.toStringAsFixed(2).replaceAll('.', ',')}',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: CupertinoColors.white,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pil-vormige keuzeknop (zelfde stijl als Week | Maand in het urenoverzicht).
class _BetaalKiezer extends StatelessWidget {
  const _BetaalKiezer({required this.waarde, required this.onKies});

  final Betaalwijze waarde;
  final ValueChanged<Betaalwijze> onKies;

  @override
  Widget build(BuildContext context) {
    final opties = Betaalwijze.values;
    final index = opties.indexOf(waarde);

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
            alignment: Alignment(
              opties.length == 1 ? 0 : -1 + 2 * index / (opties.length - 1),
              0,
            ),
            child: FractionallySizedBox(
              widthFactor: 1 / opties.length,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final b in opties)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onKies(b),
                    child: Center(
                      child: Text(
                        b.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: b == waarde
                              ? CupertinoColors.white
                              : CupertinoColors.secondaryLabel.resolveFrom(context),
                        ),
                      ),
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
