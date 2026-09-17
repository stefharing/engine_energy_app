import '../models/hours_entry.dart';
import '../models/scanned_extra.dart';
import '../models/service_remote_format.dart';

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
///  - `htmlFile` MUST be entirely absent from the body, even if the source
///    job order response happened to include one. Including it — even as a
///    placeholder — causes a server-side PDF rendering failure.
///
/// [hours] replaces whatever `hours` array (if any) was on the original job
/// order response — the caller's list is the authoritative source for this
/// submission's worked hours.
///
/// Never mutates [rawJobOrder]: every map this function writes into is
/// copied first.
Map<String, dynamic> buildServiceRemoteJobOrderSubmission({
  required Map<String, dynamic> rawJobOrder,
  required int appointmentId,
  required List<HoursEntry> hours,
  required String uniqueId,
  List<ScannedExtra> extras = const [],
}) {
  final body = Map<String, dynamic>.from(rawJobOrder)
    ..remove('htmlFile')
    ..remove('htmlfile');

  body['uniqueId'] = uniqueId;
  body['appointment'] = appointmentId;
  // A material-only publication must retain hours already stored on the job
  // order. When there are new local hours, they remain authoritative.
  body['hours'] = hours.isEmpty
      ? (rawJobOrder['hours'] as List<dynamic>? ?? const [])
      : hours.map((entry) => entry.toJson()).toList();

  if (extras.isNotEmpty) {
    final jobOrderId = rawJobOrder['id'] as int;
    final warehouseId = rawJobOrder['warehouseId'] as int;
    final dateChanged = formatServiceRemoteUtc(DateTime.now());
    final detailItems = List<dynamic>.from(
      rawJobOrder['detailItems'] as List<dynamic>? ?? const [],
    );
    final detailMisc = List<dynamic>.from(
      rawJobOrder['detailMisc'] as List<dynamic>? ?? const [],
    );
    for (final extra in extras) {
      if (extra.isManual) {
        detailMisc.add({
          'id': 0,
          'dateChanged': dateChanged,
          'delete': false,
          'recordTag': null,
          'description': extra.description,
          'quantity': extra.scannedCount,
          // Confirmed by a real Service Remote response: free-text material
          // lines use the tenant's generic miscellaneous record, id 1.
          'miscId': 1,
          'jobOrderId': jobOrderId,
          'deliveryMethod': 1,
          'registrationPath': 3,
        });
      } else {
        detailItems.add({
          'id': 0,
          'dateChanged': dateChanged,
          'delete': false,
          'recordTag': null,
          'description': extra.description,
          'quantity': extra.scannedCount,
          'itemId': extra.itemId,
          'warehouseId': warehouseId,
          'jobOrderId': jobOrderId,
          'deliveryMethod': 1,
          'registrationPath': 5,
          'isTravelDetail': false,
        });
      }
    }
    body['detailItems'] = detailItems;
    body['detailMisc'] = detailMisc;
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
  body['onHold'] = body['onHold'] ?? false;
  // Confirmed value — always false for this (no signature-capture flow yet).
  body['readyForSignature'] = false;

  body['contact'] = body['contact'] ?? _emptyContact();
  body['signature'] = body['signature'] ?? _emptySignature();
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
