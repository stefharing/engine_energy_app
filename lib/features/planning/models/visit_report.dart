import 'work_report_draft.dart';

/// Wie het bezoekrapport namens de klant tekent. Het e-mailadres gaat mee
/// naar Ridder (`signature.email`), zodat Ridder het rapport na verwerking
/// naar de klant kan mailen.
class VisitReportSigner {
  const VisitReportSigner({required this.name, this.email = ''});

  final String name;
  final String email;

  Map<String, dynamic> toJson() => {'name': name, 'email': email};

  factory VisitReportSigner.fromJson(Map<String, dynamic> j) =>
      VisitReportSigner(
        name: j['name'] as String? ?? '',
        email: j['email'] as String? ?? '',
      );
}

/// Eén regel "Gebruikte materialen" op het bezoekrapport.
class VisitReportMaterial {
  const VisitReportMaterial({
    required this.omschrijving,
    required this.aantal,
    this.code = '',
    this.eenheid = 'stuks',
  });

  final String omschrijving;
  final String code;
  final int aantal;
  final String eenheid;
}

/// Eén regel "Uren" op het bezoekrapport.
class VisitReportHourLine {
  const VisitReportHourLine({
    required this.datum,
    required this.soort,
    this.minuten = 0,
    this.km,
    this.memo,
  });

  final DateTime datum;
  final String soort;
  final int minuten;
  final int? km;
  final String? memo;

  bool get isKm => km != null;
}

/// Alles wat op het bezoekrapport staat, los van hoe het getoond wordt
/// (in de app als widgets, naar Ridder als HTML).
class VisitReportData {
  const VisitReportData({
    required this.bonNummer,
    required this.omschrijving,
    required this.klant,
    required this.monteur,
    required this.datum,
    this.adres = '',
    this.object = '',
    this.serviceType = '',
    this.uren = const [],
    this.materialen = const [],
    this.rapport,
  });

  final String bonNummer;
  final String omschrijving;
  final String klant;
  final String adres;
  final String object;
  final String serviceType;
  final String monteur;
  final DateTime datum;
  final List<VisitReportHourLine> uren;
  final List<VisitReportMaterial> materialen;

  /// Het werkrapport uit "Rapport schrijven", als dat is ingevuld.
  final WorkReportDraft? rapport;

  int get totaalMinuten =>
      uren.where((u) => !u.isKm).fold(0, (s, u) => s + u.minuten);
  int get totaalKm => uren.fold(0, (s, u) => s + (u.km ?? 0));
}

/// `8u00`-notatie, zoals Ridder uren toont.
String formatUrenMinuten(int minuten) =>
    '${minuten ~/ 60}u${(minuten % 60).toString().padLeft(2, '0')}';
