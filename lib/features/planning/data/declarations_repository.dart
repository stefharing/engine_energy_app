import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import 'declarations_config.dart';

class DeclarationLine {
  final String description;
  final int? miscCategoryId;
  final int? vatCodeId;
  final double amount;
  final double quantity;

  const DeclarationLine({
    required this.description,
    this.miscCategoryId,
    this.vatCodeId,
    required this.amount,
    required this.quantity,
  });
}

class DeclarationsRepository {
  static const _supplierPrefKey = 'decl_supplier_id_v2';

  static Future<int> getOverigSupplierId() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getInt(_supplierPrefKey);
    if (cached != null) return cached;

    final resp = await ApiClient.instance.dio.get(
      '/crm/creditors',
      queryParameters: {'filter': 'code[eq]"10000"', 'pagesize': 5},
    );
    final items =
        (resp.data['items'] as List?) ?? (resp.data['data'] as List?) ?? [];
    if (items.isNotEmpty) {
      final id = items.first['id'] as int;
      await prefs.setInt(_supplierPrefKey, id);
      return id;
    }
    throw Exception('Crediteur "Diverse debiteuren" (10000) niet gevonden');
  }

  static Future<List<Map<String, dynamic>>> getMiscCategories() async {
    // Probeer bekende RidderIQ-paden voor kostensoorten
    const candidates = [
      '/purchase/purchasemiscellaneous',
      '/purchase/miscellaneousitems',
      '/administration/miscellaneous',
      '/financial/costcenters',
    ];
    for (final path in candidates) {
      try {
        final resp = await ApiClient.instance.dio.get(
          path,
          queryParameters: {'page': 1, 'size': 200},
        );
        // ignore: avoid_print
        print('DEBUG getMiscCategories HIT: $path keys=${resp.data?.keys}');
        final list = (resp.data['data'] ?? resp.data['items']) as List?;
        if (list != null) return list.cast<Map<String, dynamic>>();
      } catch (_) {
        // ignore: avoid_print
        print('DEBUG getMiscCategories MISS: $path');
      }
    }
    return [];
  }

  static Future<List<Map<String, dynamic>>> getVatCodes() async {
    final resp = await ApiClient.instance.dio.get(
      '/financial/valueaddedtaxesvat',
      queryParameters: {'page': 1, 'size': 50},
    );
    // ignore: avoid_print
    print('DEBUG getVatCodes keys: ${resp.data?.keys}');
    final list =
        (resp.data['items'] ?? resp.data['data'] ?? resp.data['results'])
            as List?;
    // ignore: avoid_print
    print('DEBUG getVatCodes count: ${list?.length}');
    return (list ?? []).cast<Map<String, dynamic>>();
  }

  static Future<void> submitFullDeclaration({
    required int supplierId,
    required String employeeName,
    required String headerDescription,
    required DateTime date,
    required List<DeclarationLine> lines,
  }) async {
    final dio = ApiClient.instance.dio;
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    final invoiceBody = <String, dynamic>{
      'invoicedate': dateStr,
      'supplier': {'id': supplierId},
      'description':
          'Declaratie $employeeName${headerDescription.isNotEmpty ? ' – $headerDescription' : ''}',
      'externalinvoicenumber': employeeName,
      'payable': true,
      'exchangerate': DeclarationsConfig.exchangeRate,
    };

    void addRef(String key, int? id) {
      if (id != null) invoiceBody[key] = {'id': id};
    }

    addRef('daybook', DeclarationsConfig.daybookId);
    addRef('currency', DeclarationsConfig.currencyId);
    addRef('paymentterm', DeclarationsConfig.paymentTermId);
    addRef('paymentmethod', DeclarationsConfig.paymentMethodId);
    addRef('vatcompanygroup', DeclarationsConfig.vatCompanyGroupId);
    addRef('incoterm', DeclarationsConfig.incotermId);

    final invoiceResp = await dio.post(
      '/purchase/purchaseinvoices',
      data: invoiceBody,
    );
    final invoiceId = invoiceResp.data['id'];

    for (final line in lines) {
      final lineBody = <String, dynamic>{
        'purchaseinvoice': {'id': invoiceId},
        'description': line.description,
        'amount': line.amount,
        'quantity': line.quantity,
      };
      if (line.vatCodeId != null) {
        lineBody['valueaddedtax'] = {'id': line.vatCodeId};
      }
      if (line.miscCategoryId != null) {
        lineBody['miscellaneous'] = {'id': line.miscCategoryId};
      }
      if (DeclarationsConfig.purchaseUnitId != null) {
        lineBody['purchaseunit'] = {'id': DeclarationsConfig.purchaseUnitId};
      }
      await dio.post('/purchase/purchaseinvoicedetailsmisc', data: lineBody);
    }
  }
}
