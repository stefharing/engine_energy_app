import '../models/hours_entry.dart';
import '../models/job_order.dart';

/// Builds the exact JSON body `POST /ServiceRemote/JobOrder/{id}` needs to
/// submit a job order's worked hours (phase 5a — hours only, no signature).
///
/// Every rule below came out of a full day debugging real 500s against the
/// live API — do not "clean up" or simplify any of them:
///
///  - [uniqueId] (a fresh GUID, one per submission — NOT the per-day GUID
///    on individual [hours] entries) MUST be present at the top level.
///    Its absence was a primary cause of 500s.
///  - [appointmentId] MUST be present at the top level as `appointment`.
///    This is distinct from `employees[].id` on the job order — also a
///    primary cause of 500s when missing.
///  - `htmlFile` MUST be entirely absent from the body, even if the source
///    job order response happened to include one. Including it — even as a
///    placeholder — causes a server-side PDF rendering failure.
///
/// [hours] is serialized exactly as stored by `HoursEntryStore`, replacing
/// whatever `hours` array (if any) was on the original job order response —
/// the store is the authoritative source for this session's worked hours.
///
/// [readyForSignature] defaults to `true` because phase 5a has no signature
/// flow yet. It's a parameter — not a literal buried in the body map —
/// specifically so phase 5b can pass `false` once a signature is attached
/// without touching this function's body.
///
/// Never mutates [jobOrder]'s underlying data: a fresh copy is made before
/// any key is added or removed.
///
/// [signature] is a TEMPORARY EXPERIMENT hook (see
/// `JobOrderRepository.submitJobOrderWithSignatureExperiment`) — phase 5a
/// itself never passes it. Left `null` it changes nothing about the body
/// above. Do not treat its presence here as phase 5b being "done"; it's
/// only wired up enough to test one hypothesis about the live 500.
Map<String, dynamic> buildJobOrderSubmission({
  required JobOrder jobOrder,
  required int appointmentId,
  required List<HoursEntry> hours,
  required String uniqueId,
  bool readyForSignature = true,
  Map<String, dynamic>? signature,
}) {
  final body = Map<String, dynamic>.from(jobOrder.toJson())
    ..remove('htmlFile')
    ..remove('htmlfile');

  body['uniqueId'] = uniqueId;
  body['appointment'] = appointmentId;
  body['hours'] = hours.map((entry) => entry.toJson()).toList();
  body['readyForSignature'] = readyForSignature;
  if (signature != null) {
    body['signature'] = signature;
  }

  return body;
}
