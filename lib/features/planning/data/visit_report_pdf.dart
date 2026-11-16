import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/visit_report.dart';
import '../models/work_report_draft.dart';

const _oranje = PdfColor.fromInt(0xFFFF9200);
const _grijs = PdfColor.fromInt(0xFF636366);
const _lijn = PdfColor.fromInt(0xFFD1D1D6);
const _vlak = PdfColor.fromInt(0xFFF2F2F7);

const _dagen = ['', 'ma', 'di', 'wo', 'do', 'vr', 'za', 'zo'];

String _datum(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.year}';

String _datumTijd(DateTime d) =>
    '${_datum(d)} ${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';

/// Tekens die het standaardlettertype (Helvetica, WinAnsi) kan tonen,
/// buiten Latin-1. Alles daarbuiten wordt '?', zodat een emoji of ander
/// bijzonder teken in een memo de pdf niet laat mislukken.
const _winAnsiExtra = {
  0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030,
  0x0160, 0x2039, 0x0152, 0x017D, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022,
  0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x017E, 0x0178,
};

String _t(String? s) {
  final b = StringBuffer();
  for (final c in (s ?? '').runes) {
    final ok =
        c == 0x0A ||
        (c >= 0x20 && c <= 0x7E) ||
        (c >= 0xA0 && c <= 0xFF) ||
        _winAnsiExtra.contains(c);
    b.writeCharCode(ok ? c : 0x3F);
  }
  return b.toString();
}

String _urgentie(FindingSeverity s) => switch (s) {
  FindingSeverity.laag => 'Laag',
  FindingSeverity.aandacht => 'Aandacht',
  FindingSeverity.urgent => 'Urgent',
};

/// Het bezoekrapport als pdf (A4), met dezelfde inhoud als het HTML-rapport
/// dat naar Ridder gaat. Voor bekijken, delen en mailen in de app — ook
/// al vóór het tekenen (dan zonder handtekening).
Future<Uint8List> buildVisitReportPdf(
  VisitReportData d, {
  Uint8List? handtekeningPng,
  VisitReportSigner? ondertekenaar,
  DateTime? getekendOp,
  Uint8List? logoPng,
}) async {
  final doc = pw.Document(
    title: 'Bezoekrapport ${d.bonNummer}',
    author: 'Engine Energy',
  );

  final basis = pw.TextStyle(fontSize: 10, lineSpacing: 1.5);
  final klein = pw.TextStyle(fontSize: 9, color: _grijs);
  final kop = pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold);

  pw.Widget sectie(String titel, List<pw.Widget> inhoud) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.SizedBox(height: 16),
      pw.Text(titel, style: kop),
      pw.Container(
        margin: const pw.EdgeInsets.only(top: 4, bottom: 8),
        height: 0.8,
        color: _lijn,
      ),
      ...inhoud,
    ],
  );

  pw.Widget info(List<(String, String)> rijen) => pw.Table(
    columnWidths: const {
      0: pw.FixedColumnWidth(110),
      1: pw.FlexColumnWidth(),
    },
    children: [
      for (final (label, waarde) in rijen)
        if (waarde.trim().isNotEmpty)
          pw.TableRow(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 4),
                child: pw.Text(_t(label), style: klein),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 4),
                child: pw.Text(_t(waarde), style: basis),
              ),
            ],
          ),
    ],
  );

  pw.Widget lijst(
    List<String> koppen,
    List<List<String>> rijen, {
    List<String>? subregels,
    List<String>? totaal,
  }) {
    pw.Widget cel(String tekst, int kolom, {pw.TextStyle? stijl}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: pw.Text(
        _t(tekst),
        style: stijl ?? basis,
        textAlign: kolom == koppen.length - 1
            ? pw.TextAlign.right
            : pw.TextAlign.left,
      ),
    );
    return pw.Table(
      columnWidths: {
        for (var i = 0; i < koppen.length; i++)
          i: i == 0
              ? const pw.FlexColumnWidth(3)
              : i == koppen.length - 1
              ? const pw.FixedColumnWidth(70)
              : const pw.FlexColumnWidth(2),
      },
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _lijn, width: 0.5),
      ),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _vlak),
          children: [
            for (var i = 0; i < koppen.length; i++)
              cel(koppen[i], i, stijl: basis.copyWith(fontWeight: pw.FontWeight.bold)),
          ],
        ),
        for (var r = 0; r < rijen.length; r++)
          pw.TableRow(
            children: [
              for (var i = 0; i < rijen[r].length; i++)
                i == 0 && (subregels?[r] ?? '').isNotEmpty
                    ? pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(
                          vertical: 5,
                          horizontal: 4,
                        ),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(_t(rijen[r][i]), style: basis),
                            pw.Text(_t(subregels![r]), style: klein),
                          ],
                        ),
                      )
                    : cel(rijen[r][i], i),
            ],
          ),
        if (totaal != null)
          pw.TableRow(
            children: [
              for (var i = 0; i < totaal.length; i++)
                cel(
                  totaal[i],
                  i,
                  stijl: basis.copyWith(fontWeight: pw.FontWeight.bold),
                ),
            ],
          ),
      ],
    );
  }

  final r = d.rapport;
  final bevindingen =
      r?.findings.where((f) => f.text.trim().isNotEmpty).toList() ??
      const <Finding>[];

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 40),
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(_t('Bezoekrapport ${d.bonNummer}'), style: klein),
          pw.Text('Pagina ${ctx.pageNumber} van ${ctx.pagesCount}', style: klein),
        ],
      ),
      build: (ctx) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            if (logoPng != null)
              pw.Image(pw.MemoryImage(logoPng), width: 150)
            else
              pw.Text('Engine Energy', style: kop.copyWith(color: _oranje)),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  'Bezoekrapport',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(_t('Servicebon ${d.bonNummer}'), style: klein),
              ],
            ),
          ],
        ),
        pw.Container(
          margin: const pw.EdgeInsets.only(top: 10, bottom: 4),
          height: 2,
          color: _oranje,
        ),
        pw.SizedBox(height: 8),
        info([
          ('Klant', d.klant),
          ('Adres', d.adres),
          ('Omschrijving', d.omschrijving),
          ('Object', d.object),
          ('Servicetype', d.serviceType),
          ('Monteur', d.monteur),
          ('Datum', _datum(d.datum)),
        ]),
        if (r != null && r.workDescription.trim().isNotEmpty)
          sectie('Uitgevoerde werkzaamheden', [
            pw.Text(_t(r.workDescription.trim()), style: basis),
          ]),
        if (r != null && r.startingSituation.trim().isNotEmpty)
          sectie('Beginsituatie', [
            pw.Text(_t(r.startingSituation.trim()), style: basis),
          ]),
        if (bevindingen.isNotEmpty)
          sectie('Bevindingen', [
            lijst(
              ['Bevinding', 'Urgentie'],
              [
                for (final f in bevindingen)
                  [f.text.trim(), _urgentie(f.severity)],
              ],
            ),
          ]),
        if (r != null && r.recommendations.trim().isNotEmpty)
          sectie('Aanbevelingen', [
            pw.Text(_t(r.recommendations.trim()), style: basis),
          ]),
        if (d.uren.isNotEmpty)
          sectie('Uren', [
            lijst(
              ['Soort', 'Datum', 'Tijd / km'],
              [
                for (final u in d.uren)
                  [
                    u.soort,
                    '${_dagen[u.datum.weekday]} ${_datum(u.datum)}',
                    u.isKm ? '${u.km} km' : formatUrenMinuten(u.minuten),
                  ],
              ],
              subregels: [for (final u in d.uren) (u.memo ?? '').trim()],
              totaal: [
                'Totaal',
                '',
                '${formatUrenMinuten(d.totaalMinuten)}'
                    '${d.totaalKm > 0 ? ' · ${d.totaalKm} km' : ''}',
              ],
            ),
          ]),
        if (d.materialen.isNotEmpty)
          sectie('Gebruikte materialen', [
            lijst(
              ['Artikel', 'Code', 'Aantal'],
              [
                for (final m in d.materialen)
                  [m.omschrijving, m.code, '${m.aantal} ${m.eenheid}'],
              ],
            ),
          ]),
        // Akkoord + handtekening bij elkaar houden.
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            sectie('Akkoord klant', [
              info([
                ('Naam', ondertekenaar?.name ?? ''),
                ('E-mail', ondertekenaar?.email ?? ''),
                if (getekendOp != null) ('Getekend op', _datumTijd(getekendOp)),
              ]),
              pw.SizedBox(height: 6),
              if (handtekeningPng != null && handtekeningPng.isNotEmpty)
                pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Container(
                    padding: const pw.EdgeInsets.only(bottom: 4),
                    decoration: const pw.BoxDecoration(
                      border: pw.Border(
                        bottom: pw.BorderSide(color: _grijs, width: 0.5),
                      ),
                    ),
                    child: pw.Image(
                      pw.MemoryImage(handtekeningPng),
                      width: 180,
                      height: 70,
                      fit: pw.BoxFit.contain,
                    ),
                  ),
                )
              else
                pw.Text(
                  'Nog niet getekend',
                  style: klein.copyWith(fontStyle: pw.FontStyle.italic),
                ),
            ]),
          ],
        ),
      ],
    ),
  );
  return doc.save();
}
