import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    show InputImage;
import 'package:image_picker/image_picker.dart';
import 'package:receipt_recognition/receipt_recognition.dart';

import '../data/declarations_repository.dart';
import '../models/job_order.dart';
import 'live_receipt_scanner_screen.dart';

class DeclarationsScreen extends StatefulWidget {
  final ServiceOrder order;
  const DeclarationsScreen({super.key, required this.order});

  @override
  State<DeclarationsScreen> createState() => _DeclarationsScreenState();
}

class _DeclarationsScreenState extends State<DeclarationsScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  String _paymentMethod = 'Betaalpas EE';
  File? _receiptImage;
  bool _isSubmitting = false;
  bool _isScanning = false;
  bool _showNavTitle = false;
  String? _errorMessage;
  String? _scanMessage;
  int _recognizedLineCount = 0;
  final _scrollCtrl = ScrollController();

  static const _accent = Color(0xFFFF9500);
  static const _months = [
    '',
    'jan',
    'feb',
    'mrt',
    'apr',
    'mei',
    'jun',
    'jul',
    'aug',
    'sep',
    'okt',
    'nov',
    'dec',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.order.mechanic != null) {
      _nameCtrl.text = widget.order.mechanic!.name;
    }
    _scrollCtrl.addListener(() {
      final show = _scrollCtrl.offset > 53;
      if (show != _showNavTitle) setState(() => _showNavTitle = show);
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPaymentMethod() async {
    const methods = ['Betaalpas EE', 'Creditcard', 'Privérekening'];
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => CupertinoActionSheet(
        title: const Text('Betaalwijze'),
        actions: [
          for (final method in methods)
            CupertinoActionSheetAction(
              isDefaultAction: _paymentMethod == method,
              onPressed: () {
                setState(() => _paymentMethod = method);
                Navigator.of(context).pop();
              },
              child: Text(method),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    DateTime temp = _date;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => Container(
        height: 340,
        color: CupertinoColors.systemBackground.resolveFrom(context),
        child: Column(
          children: [
            SizedBox(
              height: 260,
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _date,
                maximumDate: DateTime.now().add(const Duration(days: 1)),
                onDateTimeChanged: (dt) => temp = dt,
              ),
            ),
            CupertinoButton(
              child: const Text('Klaar'),
              onPressed: () {
                setState(() => _date = temp);
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanReceipt() async {
    String? mode;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => CupertinoActionSheet(
        title: const Text('Bon toevoegen'),
        actions: [
          CupertinoActionSheetAction(
            isDefaultAction: true,
            onPressed: () {
              mode = 'live';
              Navigator.of(context).pop();
            },
            child: const Text('Live scannen'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              mode = 'camera';
              Navigator.of(context).pop();
            },
            child: const Text('Foto maken'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              mode = 'gallery';
              Navigator.of(context).pop();
            },
            child: const Text('Fotoarchief'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );

    if (!mounted || mode == null) return;
    if (mode == 'live') {
      await _scanReceiptLive();
      return;
    }
    await _scanReceiptImage(
      mode == 'camera' ? ImageSource.camera : ImageSource.gallery,
    );
  }

  Future<void> _scanReceiptLive() async {
    final result = await Navigator.of(context).push<LiveReceiptScanResult>(
      CupertinoPageRoute(builder: (_) => const LiveReceiptScannerScreen()),
    );
    if (result == null || !mounted) return;
    _applyRecognizedReceipt(result.receipt, imageFile: result.imageFile);
  }

  Future<void> _scanReceiptImage(ImageSource source) async {
    setState(() {
      _isScanning = true;
      _errorMessage = null;
      _scanMessage = null;
    });
    try {
      final image = await ImagePicker().pickImage(
        source: source,
        imageQuality: 90,
      );
      if (image == null) {
        setState(() => _isScanning = false);
        return;
      }

      final options = ReceiptOptions.fromLayeredJson({
        'extend': {
          'totalLabels': {
            'Totaal': 'Totaal',
            'Subtotaal': 'Subtotaal',
            'Te betalen': 'Te betalen',
            'Totaalbedrag': 'Totaalbedrag',
            'Pinbedrag': 'Pinbedrag',
            'Totaal incl': 'Totaal incl',
            'Totaal excl': 'Totaal excl',
          },
          'stopKeywords': ['Wisselgeld', 'Teruggave', 'Terug'],
        },
      });
      final recognizer = ReceiptRecognizer(singleScan: true, options: options);
      final receipt = await recognizer.processImage(
        InputImage.fromFilePath(image.path),
      );
      await recognizer.close();

      _applyRecognizedReceipt(receipt, imageFile: File(image.path));
    } catch (e) {
      if (mounted) {
        setState(() {
          _isScanning = false;
          _errorMessage = 'Bon scannen mislukt. Vul de gegevens handmatig in.';
        });
      }
    }
  }

  void _applyRecognizedReceipt(RecognizedReceipt receipt, {File? imageFile}) {
    double? totalValue = receipt.total?.value;
    if (totalValue == null && receipt.positions.isNotEmpty) {
      final sum = receipt.positions.fold<double>(
        0,
        (a, b) => a + b.price.value,
      );
      if (sum > 0) totalValue = sum;
    }

    setState(() {
      _receiptImage = imageFile;
      _isScanning = false;
      _recognizedLineCount = receipt.positions.length;
      _scanMessage = totalValue != null
          ? 'Bedrag herkend uit kassabon'
          : 'Kassabon toegevoegd, controleer het bedrag';
      if (totalValue != null && _amountCtrl.text.isEmpty) {
        _amountCtrl.text = totalValue.toStringAsFixed(2).replaceAll('.', ',');
      }
      if (receipt.purchaseDate?.value != null) {
        _date = receipt.purchaseDate!.value;
      }
      if (_descCtrl.text.isEmpty) {
        _descCtrl.text = _extractDescription(receipt);
      }
    });
  }

  static final _numericOnly = RegExp(r'^\d[\d\s.,€%\-]*$');

  String _extractDescription(RecognizedReceipt receipt) {
    // 1. Winkelnaam uit gestructureerde herkenning
    if (receipt.store?.value != null) return receipt.store!.value;

    // 2. Productnamen uit herkende regels
    final products = receipt.positions
        .map((p) => p.product.value.trim())
        .where((s) => s.length > 2)
        .take(2)
        .join(', ');
    if (products.isNotEmpty) return products;

    // 3. Eerste bruikbare tekstregel uit ruwe OCR-entiteiten
    final raw = (receipt.entities ?? [])
        .whereType<RecognizedUnknown>()
        .map((e) => e.value.trim())
        .where((s) => s.length > 2 && !_numericOnly.hasMatch(s))
        .take(3)
        .join(', ');
    return raw;
  }

  bool get _canSubmit {
    if (_isSubmitting) return false;
    if (_nameCtrl.text.trim().isEmpty) return false;
    if (_descCtrl.text.trim().isEmpty) return false;
    final amount =
        double.tryParse(_amountCtrl.text.trim().replaceAll(',', '.')) ?? 0;
    return amount > 0;
  }

  Future<void> _submit() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final supplierId = await DeclarationsRepository.getOverigSupplierId();
      final amount = double.parse(_amountCtrl.text.trim().replaceAll(',', '.'));
      await DeclarationsRepository.submitFullDeclaration(
        supplierId: supplierId,
        employeeName: _nameCtrl.text.trim(),
        headerDescription: '${_descCtrl.text.trim()} · $_paymentMethod',
        date: _date,
        lines: [
          DeclarationLine(
            description: _descCtrl.text.trim(),
            amount: amount,
            quantity: 1,
          ),
        ],
      );
      if (mounted) {
        await showCupertinoDialog<void>(
          context: context,
          builder: (_) => CupertinoAlertDialog(
            title: const Text('Declaratie ingediend'),
            content: const Text('De declaratie is succesvol aangemaakt.'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  String _fmtDate(DateTime d) => '${d.day} ${_months[d.month]} ${d.year}';

  String get _amountLabel {
    final raw = _amountCtrl.text.trim();
    return raw.isEmpty ? 'Nog geen bedrag' : 'EUR $raw';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final divider = isDark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6);
    final title = widget.order.description.isNotEmpty
        ? widget.order.description
        : widget.order.orderNumber;

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.systemBackground,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4),
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.label.resolveFrom(context),
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: AnimatedOpacity(
          opacity: _showNavTitle ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: const Text(
            'Kosten & bonnen',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      child: Stack(
        children: [
          CustomScrollView(
            controller: _scrollCtrl,
            slivers: [
              SliverToBoxAdapter(
                child: Container(
                  color: cardBg,
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Kosten & bonnen',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        title.isEmpty ? 'Declaratie op servicebon' : title,
                        style: TextStyle(
                          fontSize: 15,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _SummaryPill(
                            icon: CupertinoIcons.creditcard,
                            label: _paymentMethod,
                          ),
                          _SummaryPill(
                            icon: CupertinoIcons.money_euro_circle,
                            label: _amountLabel,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 20)),
              SliverToBoxAdapter(child: _SectionLabel('Kassabon')),
              SliverToBoxAdapter(
                child: _ScanCard(
                  image: _receiptImage,
                  isScanning: _isScanning,
                  lineCount: _recognizedLineCount,
                  message: _scanMessage,
                  onTap: _isScanning ? null : _scanReceipt,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
              SliverToBoxAdapter(child: _SectionLabel('Declaratie')),
              SliverToBoxAdapter(
                child: _InfoCard(
                  bg: cardBg,
                  border: borderColor,
                  children: [
                    _FormRow(
                      icon: CupertinoIcons.person,
                      label: 'Naam',
                      child: _PlainTextField(
                        controller: _nameCtrl,
                        placeholder: 'Medewerkersnaam',
                        onChanged: () => setState(() {}),
                      ),
                    ),
                    _Divider(borderColor),
                    _TappableRow(
                      icon: CupertinoIcons.calendar,
                      label: 'Datum',
                      value: _fmtDate(_date),
                      onTap: _pickDate,
                    ),
                    _Divider(borderColor),
                    _FormRow(
                      icon: CupertinoIcons.text_alignleft,
                      label: 'Omschrijving',
                      child: _PlainTextField(
                        controller: _descCtrl,
                        placeholder: 'Bijv. tankkosten Amsterdam',
                        onChanged: () => setState(() {}),
                      ),
                    ),
                    _Divider(borderColor),
                    _TappableRow(
                      icon: CupertinoIcons.creditcard,
                      label: 'Betaalwijze',
                      value: _paymentMethod,
                      onTap: _pickPaymentMethod,
                    ),
                    _Divider(borderColor),
                    _FormRow(
                      icon: CupertinoIcons.money_euro_circle,
                      label: 'Bedrag excl. BTW',
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            'EUR ',
                            style: TextStyle(
                              fontSize: 15,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                          Expanded(
                            child: _PlainTextField(
                              controller: _amountCtrl,
                              placeholder: '0,00',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[\d.,]'),
                                ),
                                _CommaDecimalFormatter(),
                              ],
                              onChanged: () => setState(() {}),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_errorMessage != null) ...[
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.destructiveRed,
                      ),
                    ),
                  ),
                ),
              ],
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 48),
                  child: CupertinoButton(
                    color: const Color(0xFF34C759),
                    borderRadius: BorderRadius.circular(14),
                    onPressed: _canSubmit ? _submit : null,
                    child: _isSubmitting
                        ? const CupertinoActivityIndicator(
                            color: CupertinoColors.white,
                          )
                        : const Text(
                            'Declaratie indienen',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: CupertinoColors.white,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 0.5,
            child: Container(color: divider),
          ),
        ],
      ),
    );
  }
}

// ─── Comma decimal formatter ──────────────────────────────────────────────────

class _CommaDecimalFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final replaced = newValue.text.replaceAll('.', ',');
    if (replaced == newValue.text) return newValue;
    return newValue.copyWith(text: replaced, selection: newValue.selection);
  }
}

// ─── Helper widgets ───────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SummaryPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final bg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);
    final color = CupertinoColors.label.resolveFrom(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanCard extends StatelessWidget {
  final File? image;
  final bool isScanning;
  final int lineCount;
  final String? message;
  final VoidCallback? onTap;

  const _ScanCard({
    required this.image,
    required this.isScanning,
    required this.lineCount,
    required this.message,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final bg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final border = isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
    final hasImage = image != null;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasImage)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(13),
                ),
                child: Image.file(image!, height: 176, fit: BoxFit.cover),
              )
            else
              Container(
                height: 136,
                decoration: BoxDecoration(
                  color: _DeclarationsScreenState._accent.withValues(
                    alpha: 0.10,
                  ),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(13),
                  ),
                ),
                child: Center(
                  child: isScanning
                      ? const CupertinoActivityIndicator(radius: 14)
                      : const Icon(
                          CupertinoIcons.camera_viewfinder,
                          size: 38,
                          color: _DeclarationsScreenState._accent,
                        ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _DeclarationsScreenState._accent.withValues(
                        alpha: 0.14,
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      hasImage
                          ? CupertinoIcons.doc_text_viewfinder
                          : CupertinoIcons.camera,
                      size: 18,
                      color: _DeclarationsScreenState._accent,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isScanning
                              ? 'Kassabon wordt gescand'
                              : hasImage
                              ? 'Kassabon toegevoegd'
                              : 'Kassabon scannen',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.label.resolveFrom(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          message ??
                              (hasImage
                                  ? 'Tik om een andere bon te kiezen'
                                  : 'Maak een foto of kies uit fotoarchief'),
                          style: TextStyle(
                            fontSize: 13,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (lineCount > 0) ...[
                    const SizedBox(width: 8),
                    _CountBadge(count: lineCount),
                  ],
                  const SizedBox(width: 8),
                  const Icon(
                    CupertinoIcons.chevron_right,
                    size: 14,
                    color: CupertinoColors.systemGrey3,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;

  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF34C759).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF34C759),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final Color bg;
  final Color border;
  final List<Widget> children;

  const _InfoCard({
    required this.bg,
    required this.border,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Column(children: children),
    );
  }
}

class _FormRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget child;
  const _FormRow({
    required this.icon,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 18,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(width: 13),
          Expanded(
            flex: 4,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(flex: 5, child: child),
        ],
      ),
    );
  }
}

class _TappableRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _TappableRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
            const SizedBox(width: 13),
            Expanded(
              flex: 4,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 5,
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 15,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              CupertinoIcons.chevron_right,
              size: 14,
              color: CupertinoColors.systemGrey3,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlainTextField extends StatelessWidget {
  final TextEditingController controller;
  final String placeholder;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final VoidCallback onChanged;

  const _PlainTextField({
    required this.controller,
    required this.placeholder,
    required this.onChanged,
    this.keyboardType,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoTextField(
      controller: controller,
      placeholder: placeholder,
      padding: EdgeInsets.zero,
      textAlign: TextAlign.right,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      decoration: const BoxDecoration(),
      style: TextStyle(
        fontSize: 15,
        color: CupertinoColors.label.resolveFrom(context),
      ),
      placeholderStyle: TextStyle(
        fontSize: 15,
        color: CupertinoColors.tertiaryLabel.resolveFrom(context),
      ),
      onChanged: (_) => onChanged(),
    );
  }
}

class _Divider extends StatelessWidget {
  final Color color;
  const _Divider(this.color);

  @override
  Widget build(BuildContext context) => Container(height: 0.5, color: color);
}
