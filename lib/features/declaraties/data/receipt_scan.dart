import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    show InputImage;
import 'package:receipt_recognition/receipt_recognition.dart';

/// Wat uit een kassabon is gehaald. Alles is een voorstel: de monteur
/// controleert het in het formulier.
class BonGegevens {
  final double? totaal;
  final DateTime? datum;
  final String omschrijving;
  final int aantalRegels;

  const BonGegevens({
    this.totaal,
    this.datum,
    this.omschrijving = '',
    this.aantalRegels = 0,
  });

  bool get isLeeg => totaal == null && datum == null && omschrijving.isEmpty;
}

/// Leest bedrag, datum en winkel/omschrijving van een foto van een bon.
class ReceiptScan {
  static ReceiptOptions get opties => ReceiptOptions.fromLayeredJson({
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

  /// Scant een foto op schijf. Gooit bij een mislukte herkenning.
  static Future<BonGegevens> scanFoto(String pad) async {
    final recognizer = ReceiptRecognizer(singleScan: true, options: opties);
    try {
      final receipt = await recognizer.processImage(
        InputImage.fromFilePath(pad),
      );
      return uitBon(receipt);
    } finally {
      await recognizer.close();
    }
  }

  static BonGegevens uitBon(RecognizedReceipt receipt) {
    double? totaal = receipt.total?.value;
    if (totaal == null && receipt.positions.isNotEmpty) {
      final som = receipt.positions.fold<double>(
        0,
        (a, b) => a + b.price.value,
      );
      if (som > 0) totaal = som;
    }
    return BonGegevens(
      totaal: totaal,
      datum: receipt.purchaseDate?.value,
      omschrijving: _omschrijving(receipt),
      aantalRegels: receipt.positions.length,
    );
  }

  static final _alleenCijfers = RegExp(r'^\d[\d\s.,€%\-]*$');

  static String _omschrijving(RecognizedReceipt receipt) {
    // 1. Winkelnaam uit gestructureerde herkenning
    final winkel = receipt.store?.value;
    if (winkel != null && winkel.isNotEmpty) return winkel;

    // 2. Productnamen uit herkende regels
    final producten = receipt.positions
        .map((p) => p.product.value.trim())
        .where((s) => s.length > 2)
        .take(2)
        .join(', ');
    if (producten.isNotEmpty) return producten;

    // 3. Eerste bruikbare tekstregel uit ruwe OCR-entiteiten
    return (receipt.entities ?? [])
        .whereType<RecognizedUnknown>()
        .map((e) => e.value.trim())
        .where((s) => s.length > 2 && !_alleenCijfers.hasMatch(s))
        .take(3)
        .join(', ');
  }
}
