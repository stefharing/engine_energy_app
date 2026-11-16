import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';

/// Wat er naar Ridder gaat voor één declaratie (één kostenregel).
class DeclarationLine {
  const DeclarationLine({
    required this.description,
    required this.amount,
    this.quantity = 1,
    this.jobOrderId,
  });

  final String description;

  /// Bedrag van de bon (zoals ingevoerd).
  final double amount;
  final double quantity;

  /// Ridder-id van de bon (job order) waarop de kosten komen; `null` =
  /// algemene kosten.
  final int? jobOrderId;
}

/// Maakt van een declaratie een inkoopfactuur in Ridder IQ:
/// `POST /purchase/purchaseinvoices` (kop) en
/// `POST /purchase/purchaseinvoicedetailsmisc` (regel, op de bon), met de
/// foto als document bij de factuur.
///
/// Kop- en regelinstellingen die kantoor later nog kan aanpassen (dagboek,
/// betaalconditie, btw-groep, diverse-artikel, btw-code) komen uit de
/// standaardwaarden van Ridder (`getdefaults`), niet uit de app.
class DeclarationsRepository {
  static const _supplierPrefKey = 'decl_supplier_id_v4';
  static const _miscPrefKey = 'decl_misc_id_v2';

  static Dio get _dio => ApiClient.instance.dio;

  static List<Map<String, dynamic>> _lijst(Object? data) {
    if (data is Map) {
      final l = data['data'] ?? data['items'];
      if (l is List) return l.cast<Map<String, dynamic>>();
    }
    return const [];
  }

  /// De crediteur voor declaraties: nummer 10000, anders een naam als "div. crediteuren" of
  /// "Diverse crediteuren". Zoekt in de crediteurenlijst zelf (filters werken
  /// per administratie anders).
  static Future<int> getOverigSupplierId() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getInt(_supplierPrefKey);
    if (cached != null) return cached;

    final alle = <Map<String, dynamic>>[];
    for (var page = 1; page <= 10; page++) {
      final resp = await _dio.get(
        '/crm/creditors',
        queryParameters: {'page': page, 'size': 200},
      );
      final items = _lijst(resp.data);
      alle.addAll(items);
      if (items.length < 200) break;
    }

    String naam(Map<String, dynamic> c) {
      final r = c['relation'];
      return r is Map
          ? (r['name'] ?? r['recordtag'] ?? '').toString()
          : (c['recordtag'] ?? '').toString();
    }

    final gekozen =
        alle
            .where((c) => '${c['creditornumber']}'.trim() == '10000')
            .firstOrNull ??
        alle
            .where(
              (c) => RegExp(
                r'div\w*\.?\s*crediteur',
              ).hasMatch(naam(c).toLowerCase()),
            )
            .firstOrNull ??
        alle
            .where((c) => naam(c).toLowerCase().contains('divers'))
            .firstOrNull;
    if (gekozen != null) {
      // Op de inkoopfactuur is de leverancier de *relatie* van de crediteur,
      // niet de crediteur zelf.
      final relatie = gekozen['relation'];
      if (relatie is! Map || relatie['id'] == null) {
        throw Exception('Crediteur ${naam(gekozen)} heeft geen relatie in Ridder');
      }
      final id = (relatie['id'] as num).toInt();
      await prefs.setInt(_supplierPrefKey, id);
      return id;
    }
    final voorbeeld = alle
        .take(5)
        .map((c) => '${c['creditornumber']} ${naam(c)}')
        .join('; ');
    throw Exception(
      'Geen crediteur "Diverse crediteuren" (10000) gevonden '
      '(${alle.length} crediteuren in Ridder${voorbeeld.isEmpty ? '' : ', o.a. $voorbeeld'}).',
    );
  }

  /// Het diverse-artikel voor declaraties: code DIVERS, anders het eerste
  /// artikel met "divers" in de omschrijving, anders het eerste artikel.
  /// Kantoor kan het in Ridder later aanpassen. Geeft ook de eenheid van het
  /// artikel (verplicht op de factuurregel).
  static Future<({int id, int? unitId})> getMisc() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getInt(_miscPrefKey);
    if (cached != null) {
      return (id: cached, unitId: prefs.getInt('${_miscPrefKey}_unit'));
    }

    final resp = await _dio.get(
      '/itemmanagement/miscellaneous',
      queryParameters: {'page': 1, 'size': 200},
    );
    final items = _lijst(resp.data);
    if (items.isEmpty) {
      throw Exception('Geen diverse-artikelen gevonden in Ridder');
    }
    bool code(Map<String, dynamic> m) =>
        (m['code'] as String? ?? '').trim().toUpperCase() == 'DIVERS';
    bool omschr(Map<String, dynamic> m) =>
        (m['description'] as String? ?? '').toLowerCase().contains('divers');
    final gekozen =
        items.where(code).firstOrNull ??
        items.where(omschr).firstOrNull ??
        items.first;
    final id = (gekozen['id'] as num).toInt();
    final unit = gekozen['unit'];
    final unitId = unit is Map ? (unit['id'] as num?)?.toInt() : null;
    await prefs.setInt(_miscPrefKey, id);
    if (unitId != null) await prefs.setInt('${_miscPrefKey}_unit', unitId);
    return (id: id, unitId: unitId);
  }

  static const _kopVerwijzingen = [
    'currency',
    'daybook',
    'incoterm',
    'paymentmethod',
    'paymentterm',
    'vatcompanygroup',
  ];

  static Map<String, dynamic> _verwijzing(Object? v) {
    if (v is Map && v['id'] != null) return {'id': v['id']};
    return const {};
  }

  /// De verplichte verwijzingen van de factuurkop. Eerst wat Ridder zelf
  /// invult als de crediteur gekozen wordt (`executedatachange/supplier`),
  /// daarna per ontbrekend veld een passende keuze uit de lijst van Ridder.
  /// Kantoor kan alles in Ridder nog aanpassen.
  static Future<Map<String, dynamic>> _kopDefaults(
    int supplierId,
    DateTime date,
  ) async {
    final uit = <String, dynamic>{};

    void neem(Object? data) {
      if (data is! Map) return;
      for (final k in _kopVerwijzingen) {
        final v = _verwijzing(data[k]);
        if (v.isNotEmpty) uit.putIfAbsent(k, () => v);
      }
      if (data['bookincurrency'] is bool) {
        uit.putIfAbsent('bookincurrency', () => data['bookincurrency']);
      }
      if (data['exchangerate'] is num) {
        uit.putIfAbsent('exchangerate', () => data['exchangerate']);
      }
    }

    try {
      final resp = await _dio.post(
        '/purchase/purchaseinvoices/executedatachange/supplier',
        data: {
          'supplier': {'id': supplierId},
          'invoicedate': _datum(date),
          'bookincurrency': false,
          'exchangerate': 1.0,
          'payable': true,
        },
      );
      neem(resp.data);
    } on DioException {
      // Val terug op de lijsten hieronder.
    }

    Future<void> vul(
      String veld,
      String pad, {
      bool Function(Map<String, dynamic>)? voorkeur,
    }) async {
      if (uit.containsKey(veld)) return;
      try {
        final resp = await _dio.get(pad, queryParameters: {'page': 1, 'size': 200});
        final items = _lijst(resp.data);
        if (items.isEmpty) return;
        final gekozen =
            (voorkeur == null ? null : items.where(voorkeur).firstOrNull) ??
            items.first;
        uit[veld] = {'id': gekozen['id']};
      } on DioException {
        // Ridder meldt bij het aanmaken welk veld nog ontbreekt.
      }
    }

    bool heeft(Map<String, dynamic> m, String sleutel, String tekst) =>
        (m[sleutel] ?? '').toString().toLowerCase().contains(tekst);

    await vul(
      'currency',
      '/financial/currencies',
      voorkeur: (m) => (m['code'] ?? '').toString().toUpperCase() == 'EUR',
    );
    if (!uit.containsKey('daybook')) {
      // De crediteur kan zijn eigen inkoopdagboek hebben.
      try {
        final rel = await _dio.get('/crm/relations/$supplierId');
        final crediteurId = ((rel.data as Map)['creditor'] as Map?)?['id'];
        if (crediteurId == null) throw StateError('geen crediteur');
        final c = await _dio.get('/crm/creditors/$crediteurId');
        final v = _verwijzing((c.data as Map)['purchasedaybook']);
        if (v.isNotEmpty) uit['daybook'] = v;
      } on Object {
        // Zie hierboven.
      }
    }
    await vul(
      'daybook',
      '/financial/daybooks',
      voorkeur: (m) =>
          heeft(m, 'description', 'inkoop') || heeft(m, 'daybooktype', 'purchase'),
    );
    await vul('paymentterm', '/financial/paymentterms');
    await vul('vatcompanygroup', '/financial/vatcompanygroups');
    await vul('paymentmethod', '/sales/paymentmethods');
    await vul('incoterm', '/sales/incoterms');
    return uit;
  }

  /// Verplichte en voorgestelde velden van de regel: wat Ridder zelf invult
  /// zodra het artikel gekozen is (eenheid, btw-code, ...), met de eenheid van
  /// het artikel als vangnet.
  static Future<Map<String, dynamic>> _regelDefaults(
    int invoiceId,
    int miscId,
    int? unitId,
  ) async {
    final uit = <String, dynamic>{};
    try {
      final resp = await _dio.post(
        '/purchase/purchaseinvoicedetailsmisc/executedatachange/misc',
        data: {
          'purchaseinvoice': {'id': invoiceId},
          'misc': {'id': miscId},
          'directtoorder': false,
        },
      );
      final data = resp.data;
      if (data is Map) {
        for (final k in const [
          'purchaseunit',
          'vatcode',
          'costcenter',
          'costunit',
          'generalledgeraccount',
        ]) {
          final v = _verwijzing(data[k]);
          if (v.isNotEmpty) uit[k] = v;
        }
      }
    } on DioException {
      // Val terug op de eenheid van het artikel.
    }
    if (!uit.containsKey('purchaseunit') && unitId != null) {
      uit['purchaseunit'] = {'id': unitId};
    }
    if (!uit.containsKey('vatcode')) {
      final btw = await _kiesBtwCode(invoiceId);
      if (btw != null) uit['vatcode'] = {'id': btw};
    }
    return uit;
  }

  /// Een btw-code voor inkopen: bij voorkeur 21% in de btw-bedrijfsgroep van
  /// de factuur. Kantoor past dit in Ridder aan als de bon een ander tarief
  /// heeft.
  static Future<int?> _kiesBtwCode(int invoiceId) async {
    try {
      int? groep;
      try {
        final inv = await _dio.get('/purchase/purchaseinvoices/$invoiceId');
        final g = (inv.data as Map)['vatcompanygroup'];
        groep = g is Map ? (g['id'] as num?)?.toInt() : null;
      } on DioException {
        // Zonder groep kiezen we op tarief.
      }
      final resp = await _dio.get(
        '/financial/valueaddedtaxesvat',
        queryParameters: {'page': 1, 'size': 200},
      );
      final alle = _lijst(resp.data);
      var kandidaten = alle.where((v) => v['allowpurchases'] != false).toList();
      if (kandidaten.isEmpty) kandidaten = alle;
      if (groep != null) {
        final inGroep = kandidaten.where((v) {
          final g = v['vatcompanygroup'];
          return g is Map && (g['id'] as num?)?.toInt() == groep;
        }).toList();
        if (inGroep.isNotEmpty) kandidaten = inGroep;
      }
      final hoog = kandidaten.where((v) {
        final pct = v['vatpercentage'];
        return pct is num && pct.round() == 21;
      });
      final gekozen = hoog.firstOrNull ?? kandidaten.firstOrNull;
      return (gekozen?['id'] as num?)?.toInt();
    } on DioException {
      return null;
    }
  }

  /// Maakt de factuurkop aan en geeft het factuur-id.
  static Future<int> maakKop({
    required int supplierId,
    required String reference,
    required DateTime date,
  }) async {
    final body = <String, dynamic>{
      'bookincurrency': false,
      'exchangerate': 1.0,
      ...await _kopDefaults(supplierId, date),
      'supplier': {'id': supplierId},
      'invoicedate': _datum(date),
      'externalinvoicenumber': reference,
      'payable': true,
    };
    final resp = await _dio.post('/purchase/purchaseinvoices', data: body);
    return (resp.data['id'] as num).toInt();
  }

  /// Boekt één kostenregel op de factuur (op de bon als [DeclarationLine.jobOrderId]
  /// is gezet).
  static Future<void> boekRegel({
    required int invoiceId,
    required DeclarationLine line,
  }) async {
    final misc = await getMisc();
    final defaults = await _regelDefaults(invoiceId, misc.id, misc.unitId);

    // Het bedrag op de bon is inclusief btw. Ridder wil netto + btw = totaal.
    final btwId = (defaults['vatcode'] as Map?)?['id'] as int?;
    final pct = btwId == null ? 0.0 : await _btwPercentage(btwId);
    final totaalCenten = (line.amount * 100).round();
    final nettoCenten = (totaalCenten / (1 + pct / 100)).round();
    final btwCenten = totaalCenten - nettoCenten;

    final orderId = line.jobOrderId == null
        ? null
        : await _orderIdVanBon(line.jobOrderId!);

    final body = <String, dynamic>{
      ...defaults,
      'purchaseinvoice': {'id': invoiceId},
      'misc': {'id': misc.id},
      'description': line.description,
      'quantity': line.quantity,
      'netpurchaseprice': nettoCenten / 100,
      'vatamount': btwCenten / 100,
      'totalamount': totaalCenten / 100,
      'directtoorder': line.jobOrderId != null,
      if (line.jobOrderId != null) 'joborder': {'id': line.jobOrderId},
      'order': ?(orderId == null ? null : {'id': orderId}),
    };
    await _dio.post('/purchase/purchaseinvoicedetailsmisc', data: body);
  }

  /// Btw-percentage van een btw-code (0 als dat niet op te halen is).
  static Future<double> _btwPercentage(int vatCodeId) async {
    try {
      final resp = await _dio.get('/financial/valueaddedtaxesvat/$vatCodeId');
      final p = (resp.data as Map)['vatpercentage'];
      return p is num ? p.toDouble() : 0;
    } on DioException {
      return 0;
    }
  }

  /// De order (project) van een bon: verplicht als de regel rechtstreeks op
  /// de order wordt geboekt.
  static Future<int?> _orderIdVanBon(int jobOrderId) async {
    try {
      final resp = await _dio.get('/production/joborders/$jobOrderId');
      final o = (resp.data as Map)['order'];
      return o is Map ? (o['id'] as num?)?.toInt() : null;
    } on DioException {
      return null;
    }
  }

  /// Hangt de foto van de bon als document aan de factuur.
  static Future<void> uploadFoto({
    required int invoiceId,
    required String path,
    required String fileName,
  }) async {
    final form = FormData.fromMap({
      'fileName': await MultipartFile.fromFile(path, filename: fileName),
    });
    await _dio.post(
      '/purchase/purchaseinvoices/$invoiceId/documents/document',
      data: form,
    );
  }

  static String _datum(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
