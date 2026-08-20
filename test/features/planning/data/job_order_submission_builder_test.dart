import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/data/job_order_submission_builder.dart';
import 'package:engine_energy_app/features/planning/models/hours_entry.dart';

void main() {
  HoursEntry entry({DateTime? start, DateTime? end}) => HoursEntry(
    jobOrderId: 79,
    employeeId: 6,
    start: start ?? DateTime.utc(2026, 8, 22, 8, 0),
    end: end ?? DateTime.utc(2026, 8, 22, 9, 0),
    totalTime: 60,
    timeEmployee: 60,
    workActivityId: 20,
    uniqueId: 'line-guid',
  );

  Map<String, dynamic> baseJobOrder({Map<String, dynamic>? extra}) => {
    'id': 79,
    'recordTag': 'B-0079',
    'employees': const [],
    ...?extra,
  };

  test('sets uniqueId, appointment and hours, and always forces readyForSignature:false', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'submission-guid',
    );

    expect(body['uniqueId'], 'submission-guid');
    expect(body['appointment'], 112);
    expect(body['readyForSignature'], false);
    expect(body['hours'], [entry().toJson()]);
    // Original job order fields survive the round trip.
    expect(body['id'], 79);
    expect(body['recordTag'], 'B-0079');
  });

  test('readyForSignature is forced to false even if the source had true', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {'readyForSignature': true}),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(body['readyForSignature'], false);
  });

  test('finishTime is set to the latest end across the submitted hours lines', () {
    final earlier = entry(
      start: DateTime.utc(2026, 8, 22, 8, 0),
      end: DateTime.utc(2026, 8, 22, 9, 0),
    );
    final later = entry(
      start: DateTime.utc(2026, 8, 22, 12, 0),
      end: DateTime.utc(2026, 8, 22, 13, 30),
    );
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      hours: [earlier, later],
      uniqueId: 'x',
    );
    expect(body['finishTime'], '2026-08-22T13:30:00Z');
  });

  test('followup/onHold default to false only when missing', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(body['followup'], false);
    expect(body['onHold'], false);

    final passthrough = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {'followup': true, 'onHold': true}),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(passthrough['followup'], true);
    expect(passthrough['onHold'], true);
  });

  test('adds delete:false into the existing order object without dropping other fields', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {
        'order': {'id': 5, 'recordtag': 'ORD-5'},
      }),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(body['order'], {'id': 5, 'recordtag': 'ORD-5', 'delete': false});
  });

  test('order.delete is left untouched if the source already set it', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {
        'order': {'id': 5, 'delete': true},
      }),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect((body['order'] as Map)['delete'], true);
  });

  test('fills contact/signature/alternativeServiceAddress with the confirmed stub when missing', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );

    expect(body['contact'], {
      'id': 0,
      'dateChanged': '1900-01-01T00:00:00Z',
      'delete': false,
      'recordTag': null,
      'relationId': 0,
      'cellPhone': null,
      'email': null,
      'phone': null,
    });
    expect(body['signature'], {
      'id': 0,
      'dateChanged': '1900-01-01T00:00:00Z',
      'delete': false,
      'recordTag': null,
      'name': null,
      'email': null,
      'paths': null,
    });
    expect(body['alternativeServiceAddress'], {
      'id': 0,
      'dateChanged': '1900-01-01T00:00:00Z',
      'delete': false,
      'recordTag': null,
      'zipcode': null,
      'city': null,
      'country': null,
      'street': null,
      'location': null,
      'housenumber': 0,
      'housenumberAddition': null,
    });
  });

  test('passes through an existing non-null contact/signature/alternativeServiceAddress', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {
        'contact': {'id': 42, 'email': 'real@example.com'},
      }),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(body['contact'], {'id': 42, 'email': 'real@example.com'});
  });

  test('patches serviceObject with the four missing dates and lastKnownMeterReading', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {
        'serviceObject': {
          'id': 11,
          'description': 'Vaartuig',
          'objectLocation': {'id': 3},
        },
      }),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );

    final so = body['serviceObject'] as Map<String, dynamic>;
    expect(so['id'], 11);
    expect(so['description'], 'Vaartuig');
    expect(so['buildDate'], '1900-01-01T00:00:00Z');
    expect(so['deliveryDate'], '1900-01-01T00:00:00Z');
    expect(so['ourWarrantyDate'], '1900-01-01T00:00:00Z');
    expect(so['supplierWarrantyDate'], '1900-01-01T00:00:00Z');
    expect(so['lastKnownMeterReading'], 0.0);
  });

  test('does not overwrite existing serviceObject date fields', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {
        'serviceObject': {
          'id': 11,
          'buildDate': '2020-01-01T00:00:00Z',
        },
      }),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect((body['serviceObject'] as Map)['buildDate'], '2020-01-01T00:00:00Z');
  });

  test('changedServiceObject is built as a full copy of the patched serviceObject', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {
        'serviceObject': {'id': 11, 'description': 'Vaartuig'},
      }),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );

    expect(body['changedServiceObject'], body['serviceObject']);
    // Must be a separate map instance, not the same reference — mutating
    // one later must not silently mutate the other.
    expect(
      identical(body['changedServiceObject'], body['serviceObject']),
      isFalse,
    );
  });

  test('changedServiceObject falls back to a stub when there is no serviceObject at all', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );

    final cso = body['changedServiceObject'] as Map<String, dynamic>;
    expect(cso['id'], 0);
    expect(cso['buildDate'], '1900-01-01T00:00:00Z');
    expect(cso['lastKnownMeterReading'], 0.0);
  });

  test('omits htmlFile entirely, even if present on the source job order', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {'htmlFile': 'placeholder.pdf'}),
      appointmentId: 112,
      hours: const [],
      uniqueId: 'x',
    );
    expect(body.containsKey('htmlFile'), isFalse);
  });

  test('overwrites any existing hours array on the source job order', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {
        'hours': [
          {'id': 1, 'stale': true},
        ],
      }),
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(body['hours'], hasLength(1));
    expect((body['hours'] as List).single, entry().toJson());
  });

  test('does not mutate the source job order map', () {
    final raw = baseJobOrder(extra: {
      'order': {'id': 5},
      'serviceObject': {'id': 11},
    });

    buildServiceRemoteJobOrderSubmission(
      rawJobOrder: raw,
      appointmentId: 112,
      hours: [entry()],
      uniqueId: 'x',
    );

    expect(raw.containsKey('uniqueId'), isFalse);
    expect(raw.containsKey('appointment'), isFalse);
    expect(raw.containsKey('hours'), isFalse);
    expect((raw['order'] as Map).containsKey('delete'), isFalse);
    expect((raw['serviceObject'] as Map).containsKey('buildDate'), isFalse);
  });
}
