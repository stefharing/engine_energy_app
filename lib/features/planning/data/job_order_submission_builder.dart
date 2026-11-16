import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/hours_entry.dart';
import '../models/scanned_extra.dart';
import '../models/service_remote_format.dart';
import '../models/signature_capture.dart';

const _uuid = Uuid();

/// Builds the exact JSON body `POST /ServiceRemote/JobOrder/{id}` needs to
/// submit a job order's worked hours.
///
/// General principle (confirmed via a live curl session against job order
/// 79, 2026-08): the POST body is the full `GET` response, round-tripped,
/// with the fields below patched in — never a hand-built minimal object.
/// Every rule here came out of that session; do not "clean up" or simplify
/// any of it without re-confirming against the live API.
///
///  - [uniqueId] (a fresh GUID, one per submission) MUST be present at the
///    top level.
///  - [appointmentId] MUST be present at the top level as `appointment`.
///  - `finishTime`, `followup`, `onHold`, `readyForSignature`, and the
///    nested `contact`/`signature`/`alternativeServiceAddress`/
///    `changedServiceObject`/`order.delete` fields must be non-null or the
///    server 500s with "Nullable object must have a value." — see the
///    per-field comments below for the confirmed rule for each.
///  - `htmlFile` is never copied over from the source job order response:
///    a placeholder (or stale) value there caused a server-side PDF
///    rendering failure. It is only set from [htmlFile] — the signed visit
///    report ("bezoekrapport") built by the app, a complete HTML document,
///    which Ridder turns into the "Getekende werkbon" pdf. The caller
///    retries without it if Ridder rejects it (see
///    `ServiceRemoteJobOrderRepository.submitHoursForJobOrder`).
///
/// [hours] replaces whatever `hours` array (if any) was on the original job
/// order response — the caller's list is the authoritative source for this
/// submission's worked hours.
///
/// [signaturePaths] (the `[[x, y], ...]`-per-stroke vector data captured by
/// `SignaturePadScreen`, via `SignatureCapture.paths`; `int32[][][]` per the
/// Swagger schema) becomes the `signature.paths` field when non-empty —
/// unconfirmed against a live submission (unlike the rest of this
/// builder), since there was no way to
/// curl-test a real signed submission while building this. [signerName] is
/// the best available stand-in for who signed (the bon's linked contact
/// name); Ridder's schema has no separate "customer signed" flag to fill in
/// beyond `signature.name`.
///
/// Never mutates [rawJobOrder]: every map this function writes into is
/// copied first.
Map<String, dynamic> buildServiceRemoteJobOrderSubmission({
  required Map<String, dynamic> rawJobOrder,
  required int appointmentId,
  required int employeeId,
  required List<HoursEntry> hours,
  required String uniqueId,
  List<ScannedExtra> extras = const [],
  List<List<List<int>>>? signaturePaths,
  String? signerName,
  String? signerEmail,
  String? employeeName,
  String? htmlFile,
  bool? overnachting,
  bool onHold = false,
}) {
  final body = Map<String, dynamic>.from(rawJobOrder)
    ..remove('htmlFile')
    ..remove('htmlfile');
  if (htmlFile != null && htmlFile.trim().isNotEmpty) {
    // Als base64 (UTF-8), niet als ruwe HTML: met ruwe HTML — zelfs een
    // simpele placeholder — gaf Ridder steeds 500 "Fout tijdens aanmaken
    // .pdf bestand van html". Bestanden gaan in deze API als base64-tekst.
    body['htmlFile'] = base64Encode(utf8.encode(htmlFile));
  }

  final dateChanged = formatServiceRemoteUtc(DateTime.now());

  // Eigen veld "Overnachting" (Ridder gebruikersveld, kolomnaam OVERNACHTING)
  // staat in `userFields` van de bon. Bestaande waarden blijven staan; alleen
  // als de monteur het vinkje heeft gezet/verwijderd passen we het aan.
  if (overnachting != null) {
    final bestaand = body['userFields'];
    body['userFields'] = {
      if (bestaand is Map) ...Map<String, dynamic>.from(bestaand),
      'OVERNACHTING': overnachting,
    };
  }

  body['uniqueId'] = uniqueId;
  body['appointment'] = appointmentId;
  // A material-only publication must retain hours already stored on the job
  // order. When there are new local hours, they remain authoritative.
  body['hours'] = hours.isEmpty
      ? (rawJobOrder['hours'] as List<dynamic>? ?? const [])
      : hours.map((entry) => entry.toJson()).toList();

  // Ridder slaat `hours[].memo` via Service Remote (nog) niet op, ook al
  // staat het veld in het schema. Tijdelijke oplossing: de memo's ook als
  // regels onder "Gerealiseerde oplossing" (`realizedSolution`) zetten.
  final memoRegels = hoursMemoLines(hours, employeeName: employeeName);
  if (memoRegels.isNotEmpty) {
    body['realizedSolution'] = appendToRealizedSolution(
      rawJobOrder['realizedSolution'] as String?,
      memoRegels,
    );
  }

  if (extras.isNotEmpty) {
    final jobOrderId = rawJobOrder['id'] as int;
    final detailItems = List<dynamic>.from(
      rawJobOrder['detailItems'] as List<dynamic>? ?? const [],
    );
    final detailMisc = List<dynamic>.from(
      rawJobOrder['detailMisc'] as List<dynamic>? ?? const [],
    );
    // Confirmed via a live GET (job order 83): `warehouseId` IS present as a
    // top-level job order field, just past the 800-char cutoff `_shortBody`
    // uses for its debug log, which is why it looked absent. Fall back to
    // an existing `detailItems` line's `warehouseId` only if the top-level
    // field is ever missing.
    int? warehouseIdValue = rawJobOrder['warehouseId'] as int?;
    if (warehouseIdValue == null) {
      for (final line in detailItems.whereType<Map>()) {
        final value = line['warehouseId'];
        if (value is int) {
          warehouseIdValue = value;
          break;
        }
      }
    }
    if (warehouseIdValue == null && extras.any((e) => !e.isManual)) {
      throw StateError(
        'Cannot submit catalog-item extras: job order $jobOrderId has no '
        'warehouseId, neither top-level nor on an existing detailItems line.',
      );
    }
    final warehouseId = warehouseIdValue ?? 0;
    // Every material line submitted so far (across catalog items with real
    // stock and manual/free-text ones alike) got a clean `200 true` but
    // never actually showed up in Ridder. The `wip` ("work in progress")
    // array on the `JobOrderServiceRegistration` schema — never previously
    // sent by this app — links back to a `detailItems`/`detailMisc` line
    // via `jobOrderDetailItemId`/`jobOrderDetailMiscId`. Hypothesis: a
    // `detailItems`/`detailMisc` line without a matching `wip` entry is an
    // inert reference Ridder silently discards; the `wip` line is what
    // actually registers the stock consumption. Untested — first real
    // attempt at including it.
    final wip = List<dynamic>.from(
      rawJobOrder['wip'] as List<dynamic>? ?? const [],
    );
    // Voorbereidingsregels van kantoor ("bonregel artikel" in Ridder): de
    // `detailItems` die al op de bon staan. Gebruikt de monteur zo'n artikel,
    // dan koppelen we de registratie (`wip.jobOrderDetailItemId`) aan die
    // regel en maken we geen tweede regel aan. Een artikel dat niet op de
    // voorbereiding stond blijft ongekoppeld (id 0). Elke regel wordt
    // maximaal één keer gekoppeld, en niet als een eerdere registratie er al
    // naar verwijst.
    final alGekoppeld = <int>{
      for (final w in wip.whereType<Map>())
        if (w['jobOrderDetailItemId'] is int && w['jobOrderDetailItemId'] != 0)
          w['jobOrderDetailItemId'] as int,
    };
    final voorbereiding = <Map>[
      for (final line in detailItems.whereType<Map>())
        if (line['id'] is int &&
            line['id'] != 0 &&
            line['itemId'] is int &&
            line['delete'] != true &&
            !alGekoppeld.contains(line['id']))
          line,
    ];
    int? koppelAanVoorbereiding(int itemId) {
      final i = voorbereiding.indexWhere((l) => l['itemId'] == itemId);
      if (i < 0) return null;
      return voorbereiding.removeAt(i)['id'] as int;
    }

    for (final extra in extras) {
      if (extra.isManual) {
        detailMisc.add({
          'id': 0,
          'dateChanged': dateChanged,
          'delete': false,
          'recordTag': null,
          'description': extra.description,
          // Sent as a double, not an int: the one confirmed real
          // `detailItems` example this app has ever seen from a live GET
          // shows `"quantity": 2.0` — matching that shape here too, since
          // an int quantity is the only concrete way this payload differs
          // from that confirmed example.
          'quantity': extra.scannedCount.toDouble(),
          // Confirmed by a real Service Remote response: free-text material
          // lines use the tenant's generic miscellaneous record, id 1.
          'miscId': 1,
          'jobOrderId': jobOrderId,
          'deliveryMethod': 1,
          'registrationPath': 3,
        });
        wip.add({
          'id': 0,
          'dateChanged': dateChanged,
          'delete': false,
          'recordTag': null,
          'quantity': extra.scannedCount.toDouble(),
          'itemId': null,
          'miscId': 1,
          'warehouseId': warehouseId,
          'jobOrderId': jobOrderId,
          'description': extra.description,
          'jobOrderDetailItemId': 0,
          'jobOrderDetailMiscId': 0,
          'followup': false,
          'unitId': extra.unitId,
          'uniqueId': _uuid.v4(),
          'sourceMechanicId': employeeId,
          'pricePerUnit': 0,
          'contractDiscount': 0,
          'discount': 0,
          'totalPrice': 0,
          'vatPercentage': 0,
          'vatAmount': 0,
          'totalPriceIncVAT': 0,
        });
      } else {
        final voorbereidingId = koppelAanVoorbereiding(extra.itemId);
        if (voorbereidingId == null) {
          detailItems.add({
            'id': 0,
            'dateChanged': dateChanged,
            'delete': false,
            'recordTag': null,
            'description': extra.description,
            'quantity': extra.scannedCount.toDouble(),
            'itemId': extra.itemId,
            'warehouseId': warehouseId,
            'jobOrderId': jobOrderId,
            'deliveryMethod': 1,
            'registrationPath': 5,
            'isTravelDetail': false,
          });
        }
        wip.add({
          'id': 0,
          'dateChanged': dateChanged,
          'delete': false,
          'recordTag': null,
          'quantity': extra.scannedCount.toDouble(),
          'itemId': extra.itemId,
          'miscId': null,
          'warehouseId': warehouseId,
          'jobOrderId': jobOrderId,
          'description': extra.description,
          'jobOrderDetailItemId': voorbereidingId ?? 0,
          'jobOrderDetailMiscId': 0,
          'followup': false,
          'unitId': extra.unitId,
          'uniqueId': _uuid.v4(),
          'sourceMechanicId': employeeId,
          'pricePerUnit': 0,
          'contractDiscount': 0,
          'discount': 0,
          'totalPrice': 0,
          'vatPercentage': 0,
          'vatAmount': 0,
          'totalPriceIncVAT': 0,
        });
      }
    }
    body['detailItems'] = detailItems;
    body['detailMisc'] = detailMisc;
    body['wip'] = wip;
  }

  // finishTime: confirmed set equal to the end of the (latest) submitted
  // hours line, not "now" — falls back to now only if there are somehow no
  // hours lines to derive it from (shouldn't happen; submission requires at
  // least one entry).
  if (hours.isNotEmpty) {
    final latestEnd = hours
        .map((e) => e.end)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    body['finishTime'] = formatServiceRemoteUtc(latestEnd);
  }

  body['followup'] = body['followup'] ?? false;
  // Onderbroken (handleiding Ridder: "Einde werkdag" / remote status
  // Onderbroken): een tussentijdse registratie bij een meerdaagse bon. Kantoor
  // verwerkt hem als "Onderbreking verwerkt" — de uren worden projecturen,
  // maar de afspraak blijft open. Altijd expliciet zetten: de bon kan van een
  // eerdere tussentijdse registratie nog `onHold: true` hebben.
  body['onHold'] = onHold;
  // Confirmed value in every live submission so far (all of which predate
  // the signature-capture flow) — kept forced false even now that a real
  // signature can be attached, since there's no live-confirmed evidence
  // this needs to flip to true once signed. Revisit with a live curl check
  // if Ridder doesn't actually register the signature as expected.
  body['readyForSignature'] = false;

  body['contact'] = body['contact'] ?? _emptyContact();
  // A real captured signature (vector `paths`, the only thing Ridder's
  // schema has room for — there is no image field) takes priority over
  // whatever the source job order had; otherwise fall back to the
  // confirmed empty stub, same as every other nullable nested object here.
  // Either way the result is cut down to exactly the `ServiceRemoteSignature`
  // fields (`additionalProperties: false`) with int paths — see
  // [_sanitizeSignature].
  final capturedPaths = SignatureCapture.pathsFromJson(signaturePaths);
  final rawSignature = body['signature'] as Map<String, dynamic>?;
  body['signature'] = capturedPaths.isNotEmpty
      ? {
          'id': 0,
          'dateChanged': dateChanged,
          'delete': false,
          'recordTag': null,
          'name': signerName,
          'email': (signerEmail?.trim().isEmpty ?? true)
              ? null
              : signerEmail!.trim(),
          'paths': capturedPaths,
        }
      : rawSignature == null
      ? _emptySignature()
      : _sanitizeSignature(rawSignature);
  body['alternativeServiceAddress'] =
      body['alternativeServiceAddress'] ?? _emptyAlternativeServiceAddress();

  final rawServiceObject = body['serviceObject'] as Map<String, dynamic>?;
  final patchedServiceObject = rawServiceObject == null
      ? null
      : _patchServiceObjectDates(rawServiceObject);
  if (patchedServiceObject != null) {
    body['serviceObject'] = patchedServiceObject;
  }
  body['changedServiceObject'] = patchedServiceObject == null
      ? _fallbackChangedServiceObject()
      : Map<String, dynamic>.from(patchedServiceObject);

  final rawOrder = body['order'] as Map<String, dynamic>?;
  if (rawOrder != null) {
    final order = Map<String, dynamic>.from(rawOrder);
    order['delete'] = order['delete'] ?? false;
    body['order'] = order;
  }

  return body;
}

/// Adds the four non-nullable datetime fields (and `lastKnownMeterReading`)
/// the API requires on `serviceObject` but `GET` does not return — confirmed
/// missing from the live response for job order 79's service object.
/// Existing values (if somehow already present) are left untouched.
Map<String, dynamic> _patchServiceObjectDates(Map<String, dynamic> raw) {
  final copy = Map<String, dynamic>.from(raw);
  copy['buildDate'] ??= serviceRemoteSentinelDateTime;
  copy['deliveryDate'] ??= serviceRemoteSentinelDateTime;
  copy['ourWarrantyDate'] ??= serviceRemoteSentinelDateTime;
  copy['supplierWarrantyDate'] ??= serviceRemoteSentinelDateTime;
  copy['lastKnownMeterReading'] ??= 0.0;
  return copy;
}

Map<String, dynamic> _emptyContact() => {
  'id': 0,
  'dateChanged': serviceRemoteSentinelDateTime,
  'delete': false,
  'recordTag': null,
  'relationId': 0,
  'cellPhone': null,
  'email': null,
  'phone': null,
};

/// Reduces a signature from the source job order to the seven fields
/// `ServiceRemoteSignature` allows, with `paths` normalized to `int32[][][]`
/// — `null` when there are no non-empty strokes, never `[[]]`.
Map<String, dynamic> _sanitizeSignature(Map<String, dynamic> raw) {
  final paths = SignatureCapture.pathsFromJson(raw['paths']);
  return {
    'id': raw['id'] ?? 0,
    'dateChanged': raw['dateChanged'] ?? serviceRemoteSentinelDateTime,
    'delete': raw['delete'] ?? false,
    'recordTag': raw['recordTag'],
    'name': raw['name'],
    'email': raw['email'],
    'paths': paths.isEmpty ? null : paths,
  };
}

Map<String, dynamic> _emptySignature() => {
  'id': 0,
  'dateChanged': serviceRemoteSentinelDateTime,
  'delete': false,
  'recordTag': null,
  'name': null,
  'email': null,
  'paths': null,
};

Map<String, dynamic> _emptyAlternativeServiceAddress() => {
  'id': 0,
  'dateChanged': serviceRemoteSentinelDateTime,
  'delete': false,
  'recordTag': null,
  'zipcode': null,
  'city': null,
  'country': null,
  'street': null,
  'location': null,
  'housenumber': 0,
  'housenumberAddition': null,
};

/// Fallback shape for `changedServiceObject` when the source job order has
/// no `serviceObject` at all to copy from — not seen in the confirmed curl
/// session (every real job order has one), so this is a defensive best
/// guess from the same field list, not an independently-confirmed shape.
Map<String, dynamic> _fallbackChangedServiceObject() => {
  'id': 0,
  'dateChanged': serviceRemoteSentinelDateTime,
  'delete': false,
  'recordTag': null,
  'objectLocation': null,
  'buildDate': serviceRemoteSentinelDateTime,
  'deliveryDate': serviceRemoteSentinelDateTime,
  'ourWarrantyDate': serviceRemoteSentinelDateTime,
  'supplierWarrantyDate': serviceRemoteSentinelDateTime,
  'description': null,
  'memo': null,
  'objectnumber': null,
  'serialnumber': null,
  'serviceObjectType': null,
  'documents': null,
  'relation': null,
  'lastKnownMeterReading': 0.0,
  'contactID': 0,
};


const _memoDagen = ['', 'Ma', 'Di', 'Wo', 'Do', 'Vr', 'Za', 'Zo'];

/// Eén leesbare regel per urenregel met een memo, bijv.
/// `Ma 28-09 · Lex de Bruijn · 8u00 · Motor uit elkaar gehaald`.
/// Urenregels zonder (of met een lege) memo worden overgeslagen.
List<String> hoursMemoLines(List<HoursEntry> hours, {String? employeeName}) {
  final naam = employeeName?.trim();
  return [
    for (final h in hours)
      if ((h.memo ?? '').trim().isNotEmpty)
        [
          '${_memoDagen[h.start.weekday]} '
              '${h.start.day.toString().padLeft(2, '0')}-'
              '${h.start.month.toString().padLeft(2, '0')}',
          if (naam != null && naam.isNotEmpty) naam,
          '${h.totalTime ~/ 60}u${(h.totalTime % 60).toString().padLeft(2, '0')}',
          h.memo!.trim().replaceAll(RegExp(r'\s*\n\s*'), ' '),
        ].join(' · '),
  ];
}

/// Voegt [regels] toe onder de bestaande "Gerealiseerde oplossing", zonder
/// wat kantoor (of een eerdere publicatie) er al had neergezet te
/// overschrijven. Regels die er al letterlijk in staan worden niet nog eens
/// toegevoegd, zodat opnieuw publiceren geen dubbele regels geeft.
///
/// Is de bestaande tekst RTF (Ridder bewaart memo's soms zo), dan worden de
/// regels als RTF-alinea's vóór de afsluitende `}` ingevoegd.
String appendToRealizedSolution(String? bestaand, List<String> regels) {
  final huidig = bestaand ?? '';
  final nieuw = regels
      .where((r) => !huidig.contains(r) && !huidig.contains(_rtfEscape(r)))
      .toList();
  if (nieuw.isEmpty) return huidig;

  final isRtf = huidig.trimLeft().startsWith(r'{\rtf');
  if (isRtf) {
    final slot = huidig.lastIndexOf('}');
    if (slot > 0) {
      final rtfRegels = nieuw.map((r) => r'\par ' + _rtfEscape(r)).join('\n');
      return '${huidig.substring(0, slot)}$rtfRegels\n${huidig.substring(slot)}';
    }
  }
  final basis = huidig.trimRight();
  return [if (basis.isNotEmpty) basis, ...nieuw].join('\n');
}

String _rtfEscape(String s) {
  final b = StringBuffer();
  // UTF-16-eenheden: tekens buiten de BMP (emoji) worden zo als twee
  // \u-codes (surrogaatpaar) geschreven, zoals RTF dat verwacht.
  for (final c in s.codeUnits) {
    if (c == 0x5C || c == 0x7B || c == 0x7D) {
      b.write('\\${String.fromCharCode(c)}');
    } else if (c > 127) {
      // RTF-unicode: \uN? (N als signed 16-bit).
      b.write('\\u${c > 32767 ? c - 65536 : c}?');
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}
