import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_service.dart';
import '../models/job_order.dart';
import '../models/visit_report.dart';
import '../models/work_report_draft.dart';
import 'extras_draft_service.dart';
import 'hours_draft_service.dart';
import 'hours_sync_service.dart';
import 'picking_sync_service.dart';
import 'planning_repository.dart';
import 'signature_draft_service.dart';
import 'visit_report_pdf.dart';

/// Stelt het bezoekrapport van een bon samen uit wat er al in de app staat:
/// de eigen uren/km, de gebruikte materialen (extra artikelen van alle
/// monteurs plus gepickte geplande onderdelen) en het werkrapport uit
/// "Rapport schrijven". Bewaart ook wie namens de klant tekent.
class VisitReportService {
  VisitReportService._();
  static final instance = VisitReportService._();

  static String _ondertekenaarSleutel(String orderId) =>
      'visit_report_signer_$orderId';
  static String werkrapportSleutel(String orderId) =>
      'work_report_draft_$orderId';

  static const _logoAsset = 'assets/images/EngineEnergyLOGO_orange.png';
  static String _pdfSleutel(String orderId) => 'visit_report_pdf_$orderId';

  Uint8List? _logo;

  /// Het Engine Energy-logo (PNG) voor het rapport; `null` als het niet
  /// geladen kan worden (dan komt er tekst in de plaats).
  Future<Uint8List?> laadLogo() async {
    if (_logo != null) return _logo;
    try {
      final data = await rootBundle.load(_logoAsset);
      return _logo = data.buffer.asUint8List();
    } catch (e) {
      debugPrint('Logo voor bezoekrapport niet geladen: $e');
      return null;
    }
  }

  /// Maakt de pdf van het bezoekrapport met de huidige gegevens. Zonder
  /// handtekening (nog niet getekend) staat er "Nog niet getekend".
  Future<Uint8List> maakPdf(
    VisitReportData data, {
    Uint8List? handtekeningPng,
    VisitReportSigner? ondertekenaar,
    DateTime? getekendOp,
  }) async => buildVisitReportPdf(
    data,
    handtekeningPng: handtekeningPng,
    ondertekenaar: ondertekenaar,
    getekendOp: getekendOp,
    logoPng: await laadLogo(),
  );

  /// Verzamelt alles en maakt de pdf, met de opgeslagen handtekening en
  /// ondertekenaar als die er zijn.
  Future<Uint8List> maakPdfVoorBon(ServiceOrder order) async {
    final data = await verzamel(order);
    final handtekening = await SignatureDraftService.instance.load(order.id);
    return maakPdf(
      data,
      handtekeningPng: handtekening?.png,
      ondertekenaar: await laadOndertekenaar(order.id),
    );
  }

  /// Bewaart de pdf zoals hij bij "Werk afronden" is gepubliceerd, zodat
  /// het getekende rapport daarna in de app te bekijken blijft.
  Future<void> bewaarDefinitievePdf(String orderId, Uint8List pdf) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pdfSleutel(orderId), base64Encode(pdf));
  }

  Future<Uint8List?> laadDefinitievePdf(String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pdfSleutel(orderId));
    return raw == null ? null : base64Decode(raw);
  }

  Future<VisitReportSigner?> laadOndertekenaar(String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_ondertekenaarSleutel(orderId));
    if (raw == null) return null;
    return VisitReportSigner.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> bewaarOndertekenaar(
    String orderId,
    VisitReportSigner signer,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _ondertekenaarSleutel(orderId),
      jsonEncode(signer.toJson()),
    );
  }

  Future<WorkReportDraft?> laadWerkrapport(String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(werkrapportSleutel(orderId));
    if (raw == null) return null;
    try {
      return WorkReportDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Verzamelt alle gegevens. Onderdelen die niet opgehaald kunnen worden
  /// (bijv. geen verbinding) worden weggelaten in plaats van te falen.
  Future<VisitReportData> verzamel(ServiceOrder order) async {
    final orderId = order.id;

    await HoursSyncService.instance.haalOp(orderId);
    final dagen = await HoursDraftService.instance.localDailyBreakdown(orderId);
    final uren = <VisitReportHourLine>[
      for (final dag in dagen)
        for (final kaart in dag.cards)
          VisitReportHourLine(
            datum: dag.date,
            soort: kaart.label,
            minuten: kaart.minutes,
            km: kaart.km,
            memo: kaart.memo,
          ),
    ];

    return VisitReportData(
      bonNummer: order.orderNumber.isNotEmpty
          ? order.orderNumber
          : order.recordTag,
      omschrijving: order.description,
      klant: order.relationName,
      adres: await _adres(order),
      object: [
        order.serviceObjectTag,
        order.serviceObjectDescription,
      ].where((s) => s.trim().isNotEmpty).join(' – '),
      serviceType: order.serviceType,
      monteur: AuthService.instance.currentEmployee?.name ?? '',
      datum: DateTime.now(),
      uren: uren,
      materialen: await _materialen(orderId),
      rapport: await laadWerkrapport(orderId),
    );
  }

  Future<List<VisitReportMaterial>> _materialen(String orderId) async {
    final result = <VisitReportMaterial>[];
    final extraCodes = <String>{};

    try {
      for (final e in await ExtrasDraftService.instance.load(orderId)) {
        if (e.scannedCount <= 0) continue;
        extraCodes.add(e.code.toUpperCase());
        result.add(
          VisitReportMaterial(
            omschrijving: e.description,
            code: e.isManual ? '' : e.code,
            aantal: e.scannedCount,
            eenheid: e.unitLabel,
          ),
        );
      }
    } catch (e) {
      debugPrint('Bezoekrapport: extra artikelen niet geladen: $e');
    }

    // Gepickte, door kantoor geplande onderdelen — tenzij ze al als extra
    // artikel (met het werkelijk gebruikte aantal) op de lijst staan.
    try {
      await PickingSyncService.instance.haalOp(orderId);
      final prefs = await SharedPreferences.getInstance();
      final aantallen =
          (jsonDecode(
                    prefs.getString(PickingSyncService.countsKey(orderId)) ??
                        '{}',
                  )
                  as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, (v as num).toInt()));
      if (aantallen.values.any((v) => v > 0)) {
        final response = await ApiClient.instance.dio.get(
          '/production/joborderdetails',
          queryParameters: {
            'page': 1,
            'size': 200,
            'filter': 'joborder.id[eq]$orderId',
          },
        );
        final parts = (response.data['data'] as List)
            .cast<Map<String, dynamic>>()
            .where((p) => p['joborderdetailitem'] != null);
        for (final p in parts) {
          final aantal = aantallen[p['id'].toString()] ?? 0;
          if (aantal <= 0) continue;
          final item = p['item'] as Map<String, dynamic>?;
          final code = (item?['code'] as String? ?? p['code'] as String? ?? '')
              .trim();
          if (extraCodes.contains(code.toUpperCase())) continue;
          result.add(
            VisitReportMaterial(
              omschrijving:
                  item?['description'] as String? ??
                  p['description'] as String? ??
                  code,
              code: code,
              aantal: aantal,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Bezoekrapport: geplande onderdelen niet geladen: $e');
    }
    return result;
  }

  Future<String> _adres(ServiceOrder order) async {
    try {
      final id = order.serviceObjectId;
      if (id == null) return order.location;
      final repo = PlanningRepository.instance;
      final obj = await repo.fetchServiceObject(id);
      final locId = (obj?['objectlocation'] as Map<String, dynamic>?)?['id']
          ?.toString();
      if (locId == null) return order.location;
      final del = await repo.fetchDeliveryAddress(locId);
      final addrId = (del?['address'] as Map<String, dynamic>?)?['id']
          ?.toString();
      if (addrId == null) return order.location;
      final a = await repo.fetchAddress(addrId);
      if (a == null) return order.location;
      final regel1 = '${a['street'] ?? ''} ${a['housenumber'] ?? ''}'.trim();
      final regel2 = '${a['zipcode'] ?? ''} ${a['city'] ?? ''}'.trim();
      return [regel1, regel2].where((s) => s.isNotEmpty).join(', ');
    } catch (_) {
      return order.location;
    }
  }
}
