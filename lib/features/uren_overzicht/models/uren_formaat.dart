import 'uren_overzicht.dart';

const dagNamenKort = ['ma', 'di', 'wo', 'do', 'vr', 'za', 'zo'];
const dagNamenLang = [
  'maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag',
  'zondag',
];
const maandNamenKort = [
  'jan', 'feb', 'mrt', 'apr', 'mei', 'jun', 'jul', 'aug', 'sep', 'okt',
  'nov', 'dec',
];
const maandNamenLang = [
  'januari', 'februari', 'maart', 'april', 'mei', 'juni', 'juli', 'augustus',
  'september', 'oktober', 'november', 'december',
];

/// Maandag van de week waarin [d] valt.
DateTime maandagVan(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - 1));

/// ISO-8601 weeknummer.
int isoWeek(DateTime d) {
  final dag = alleenDatum(d);
  final donderdag = DateTime(dag.year, dag.month, dag.day + 4 - dag.weekday);
  final jan1 = DateTime(donderdag.year, 1, 1);
  return (donderdag.difference(jan1).inDays / 7).floor() + 1;
}

/// 480 → "8,0", 450 → "7,5".
String urenTekst(int minuten) =>
    (minuten / 60).toStringAsFixed(1).replaceAll('.', ',');

/// 480 → "8,0 u".
String urenMetU(int minuten) => '${urenTekst(minuten)} u';

String kmTekst(int km) => '$km km';

/// "do 29 okt"
String dagKort(DateTime d) =>
    '${dagNamenKort[d.weekday - 1]} ${d.day} ${maandNamenKort[d.month - 1]}';

/// "Week 44 · 26 okt – 1 nov 2026"
String weekTitel(DateTime maandag) {
  final zondag = DateTime(maandag.year, maandag.month, maandag.day + 6);
  final links = maandag.month == zondag.month
      ? '${maandag.day}'
      : '${maandag.day} ${maandNamenKort[maandag.month - 1]}';
  return 'Week ${isoWeek(maandag)} · $links – ${zondag.day} '
      '${maandNamenKort[zondag.month - 1]} ${zondag.year}';
}

/// "Oktober 2026"
String maandTitel(DateTime d) {
  final naam = maandNamenLang[d.month - 1];
  return '${naam[0].toUpperCase()}${naam.substring(1)} ${d.year}';
}

/// Werkdagen (ma-vr) in de maand van [d], × 8 uur, in minuten.
int maandNormMinuten(DateTime d) {
  var werkdagen = 0;
  final dagen = DateTime(d.year, d.month + 1, 0).day;
  for (var i = 1; i <= dagen; i++) {
    if (DateTime(d.year, d.month, i).weekday <= 5) werkdagen++;
  }
  return werkdagen * 8 * 60;
}

String statusTekst(UrenStatus s) => switch (s) {
  UrenStatus.goedgekeurd => 'Goedgekeurd',
  UrenStatus.wacht => 'Wacht op kantoor',
  UrenStatus.concept => 'Nog niet verstuurd',
};
