import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Material, Theme, ThemeData, Colors;
import 'package:printing/printing.dart';

import '../../../core/theme/app_colors.dart';

/// Toont een pdf (het bezoekrapport) met onderaan acties om te printen en
/// te delen. Delen opent het deelmenu van het toestel — daarmee kan de
/// monteur de pdf mailen (naar de klant of zichzelf), opslaan in
/// Bestanden, of via WhatsApp versturen. In de webversie wordt de pdf
/// gedownload.
class VisitReportPdfScreen extends StatelessWidget {
  const VisitReportPdfScreen({
    super.key,
    required this.pdf,
    required this.bestandsnaam,
    this.titel = 'Bezoekrapport',
  });

  final Uint8List pdf;
  final String bestandsnaam;
  final String titel;

  Future<void> _deel() =>
      Printing.sharePdf(bytes: pdf, filename: bestandsnaam);

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
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: Text(
          titel,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.navForeground.resolveFrom(context),
          ),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _deel,
          child: Icon(
            CupertinoIcons.share,
            color: AppColors.navForeground.resolveFrom(context),
          ),
        ),
      ),
      // PdfPreview is een Material-widget; de app is Cupertino.
      child: SafeArea(
        child: Theme(
          data: ThemeData(
            brightness: isDark ? Brightness.dark : Brightness.light,
            colorSchemeSeed: const Color(0xFFFF6B2B),
          ),
          child: Material(
            color: Colors.transparent,
            child: PdfPreview(
              build: (_) async => pdf,
              pdfFileName: bestandsnaam,
              canChangePageFormat: false,
              canChangeOrientation: false,
              canDebug: false,
              allowPrinting: true,
              allowSharing: true,
            ),
          ),
        ),
      ),
    );
  }
}
