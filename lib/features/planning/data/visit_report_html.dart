import 'dart:convert';
import 'dart:typed_data';

import '../models/visit_report.dart';
import '../models/work_report_draft.dart';

const _dagen = ['', 'ma', 'di', 'wo', 'do', 'vr', 'za', 'zo'];

String _datum(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.year}';

String _datumTijd(DateTime d) =>
    '${_datum(d)} ${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';

/// Tekst veilig in HTML zetten (ook regeleinden als `<br>`).
String _e(String? s) => const HtmlEscape()
    .convert(s ?? '')
    .replaceAll('\n', '<br>');

String _urgentie(FindingSeverity s) => switch (s) {
  FindingSeverity.laag => 'Laag',
  FindingSeverity.aandacht => 'Aandacht',
  FindingSeverity.urgent => 'Urgent',
};

/// Bouwt het bezoekrapport als één complete, op zichzelf staande HTML-pagina
/// (inline CSS, handtekening als data-URI, geen externe bestanden). Dit gaat
/// als `htmlFile` mee naar Ridder, dat er de pdf "Getekende werkbon" van
/// maakt — net als de Service Remote-app.
String buildVisitReportHtml(
  VisitReportData d, {
  Uint8List? handtekeningPng,
  VisitReportSigner? ondertekenaar,
  DateTime? getekendOp,
  String bedrijfsnaam = 'Engine Energy',
  Uint8List? logoPng,
}) {
  final b = StringBuffer()
    ..write('<!DOCTYPE html><html lang="nl"><head><meta charset="utf-8">')
    ..write('<title>Bezoekrapport ${_e(d.bonNummer)}</title><style>')
    ..write(
      'body{font-family:Arial,Helvetica,sans-serif;font-size:11pt;'
      'color:#1c1c1e;margin:24px}'
      'h1{font-size:18pt;margin:0 0 4px}'
      'h2{font-size:12pt;margin:20px 0 6px;padding-bottom:3px;'
      'border-bottom:1px solid #c7c7cc}'
      '.sub{color:#636366;margin:0 0 12px}'
      'table{width:100%;border-collapse:collapse}'
      'td,th{text-align:left;vertical-align:top;padding:4px 6px}'
      'th{background:#f2f2f7;font-weight:bold}'
      '.info td:first-child{width:28%;color:#636366}'
      '.r{text-align:right}'
      '.lijst td,.lijst th{border-bottom:1px solid #e5e5ea}'
      '.totaal td{font-weight:bold;border-top:1px solid #8e8e93}'
      '.memo{color:#636366;font-size:10pt}'
      '.logo{margin:0 0 16px}'
      '.akkoord{page-break-inside:avoid}'
      '.sig{margin:8px 0 0}'
      '.sig img{border-bottom:1px solid #8e8e93}',
    )
    ..write('</style></head><body>');
  if (logoPng != null && logoPng.isNotEmpty) {
    // Vaste breedte als attribuut: de pdf-omzetter van Ridder negeert
    // max-width, waardoor afbeeldingen anders op ware grootte komen.
    b.write(
      '<div class="logo"><img alt="${_e(bedrijfsnaam)}" width="200" '
      'style="width:200px;height:auto" '
      'src="data:image/png;base64,${base64Encode(logoPng)}"></div>',
    );
  }
  b
    ..write('<h1>Bezoekrapport</h1>')
    ..write('<p class="sub">${_e(bedrijfsnaam)} · Servicebon ${_e(d.bonNummer)}</p>');

  // ── Algemeen ──────────────────────────────────────────────────────────
  b.write('<table class="info">');
  void rij(String label, String waarde) {
    if (waarde.trim().isEmpty) return;
    b.write('<tr><td>${_e(label)}</td><td>${_e(waarde)}</td></tr>');
  }

  rij('Klant', d.klant);
  rij('Adres', d.adres);
  rij('Omschrijving', d.omschrijving);
  rij('Object', d.object);
  rij('Servicetype', d.serviceType);
  rij('Monteur', d.monteur);
  rij('Datum', _datum(d.datum));
  b.write('</table>');

  // ── Werkrapport ───────────────────────────────────────────────────────
  final r = d.rapport;
  if (r != null) {
    void tekst(String kop, String inhoud) {
      if (inhoud.trim().isEmpty) return;
      b.write('<h2>${_e(kop)}</h2><p>${_e(inhoud.trim())}</p>');
    }

    tekst('Uitgevoerde werkzaamheden', r.workDescription);
    tekst('Beginsituatie', r.startingSituation);
    final bevindingen = r.findings.where((f) => f.text.trim().isNotEmpty);
    if (bevindingen.isNotEmpty) {
      b.write('<h2>Bevindingen</h2><table class="lijst">');
      for (final f in bevindingen) {
        b.write(
          '<tr><td>${_e(f.text.trim())}</td>'
          '<td class="r">${_urgentie(f.severity)}</td></tr>',
        );
      }
      b.write('</table>');
    }
    tekst('Aanbevelingen', r.recommendations);
  }

  // ── Uren ──────────────────────────────────────────────────────────────
  if (d.uren.isNotEmpty) {
    b.write(
      '<h2>Uren</h2><table class="lijst"><tr><th>Datum</th><th>Soort</th>'
      '<th class="r">Tijd / km</th></tr>',
    );
    for (final u in d.uren) {
      b.write(
        '<tr><td>${_dagen[u.datum.weekday]} ${_datum(u.datum)}</td>'
        '<td>${_e(u.soort)}'
        '${(u.memo ?? '').trim().isEmpty ? '' : '<div class="memo">${_e(u.memo!.trim())}</div>'}'
        '</td><td class="r">'
        '${u.isKm ? '${u.km} km' : formatUrenMinuten(u.minuten)}</td></tr>',
      );
    }
    b.write(
      '<tr class="totaal"><td colspan="2">Totaal</td><td class="r">'
      '${formatUrenMinuten(d.totaalMinuten)}'
      '${d.totaalKm > 0 ? ' · ${d.totaalKm} km' : ''}</td></tr></table>',
    );
  }

  // ── Materialen ────────────────────────────────────────────────────────
  if (d.materialen.isNotEmpty) {
    b.write(
      '<h2>Gebruikte materialen</h2><table class="lijst"><tr><th>Artikel</th>'
      '<th>Code</th><th class="r">Aantal</th></tr>',
    );
    for (final m in d.materialen) {
      b.write(
        '<tr><td>${_e(m.omschrijving)}</td><td>${_e(m.code)}</td>'
        '<td class="r">${m.aantal} ${_e(m.eenheid)}</td></tr>',
      );
    }
    b.write('</table>');
  }

  // ── Handtekening ──────────────────────────────────────────────────────
  // Samen houden, zodat de handtekening niet los op een volgende pagina
  // belandt.
  b.write('<div class="akkoord"><h2>Akkoord klant</h2><table class="info">');
  if (ondertekenaar != null) {
    rij('Naam', ondertekenaar.name);
    rij('E-mail', ondertekenaar.email);
  }
  if (getekendOp != null) rij('Getekend op', _datumTijd(getekendOp));
  b.write('</table>');
  if (handtekeningPng != null && handtekeningPng.isNotEmpty) {
    b.write(
      '<p class="sig"><img alt="Handtekening" width="220" '
      'style="width:220px;height:auto" '
      'src="data:image/png;base64,${base64Encode(handtekeningPng)}"></p>',
    );
  }
  b.write('</div>');

  b.write('</body></html>');
  return b.toString();
}
