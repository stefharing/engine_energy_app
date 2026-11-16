import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:engine_energy_app/features/planning/data/job_order_submission_builder.dart';
import 'package:engine_energy_app/features/planning/models/hours_entry.dart';
import 'package:engine_energy_app/features/planning/models/scanned_extra.dart';
import 'package:engine_energy_app/features/planning/models/signature_capture.dart';

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

  test(
    'sets uniqueId, appointment and hours, and always forces readyForSignature:false',
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(),
        appointmentId: 112,
        employeeId: 6,
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
    },
  );

  test('appends stock extras as detailItems without dropping server lines', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(
        extra: {
          'warehouseId': 2,
          'detailItems': [
            {'id': 8, 'itemId': 100, 'quantity': 1},
          ],
        },
      ),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
      extras: [
        ScannedExtra(
          item: {'id': 8447, 'code': 'OIL-1', 'description': 'Oil filter'},
          scannedCount: 2,
        ),
      ],
    );

    expect(body['detailItems'], [
      {'id': 8, 'itemId': 100, 'quantity': 1},
      {
        'id': 0,
        'dateChanged': isA<String>(),
        'delete': false,
        'recordTag': null,
        'description': 'Oil filter',
        'quantity': 2,
        'itemId': 8447,
        'warehouseId': 2,
        'jobOrderId': 79,
        'deliveryMethod': 1,
        'registrationPath': 5,
        'isTravelDetail': false,
      },
    ]);
  });

  test(
    'links a used article to the office preparation line (bonregel artikel) '
    'instead of adding a second detailItems line',
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(
          extra: {
            'warehouseId': 2,
            'detailItems': [
              {'id': 186, 'itemId': 66105, 'quantity': 2},
            ],
          },
        ),
        appointmentId: 112,
        employeeId: 6,
        hours: [entry()],
        uniqueId: 'x',
        extras: [
          ScannedExtra(
            item: {'id': 66105, 'code': 'X1', 'description': 'Hose'},
            scannedCount: 2,
          ),
          // Niet op de voorbereiding: ongekoppeld, en wel een nieuwe regel.
          ScannedExtra(
            item: {'id': 8447, 'code': 'OIL-1', 'description': 'Oil filter'},
            scannedCount: 1,
          ),
        ],
      );

      final wip = (body['wip'] as List).cast<Map>();
      expect(wip.firstWhere((w) => w['itemId'] == 66105)['jobOrderDetailItemId'], 186);
      expect(wip.firstWhere((w) => w['itemId'] == 8447)['jobOrderDetailItemId'], 0);
      final regels = (body['detailItems'] as List).cast<Map>();
      expect(regels.where((l) => l['itemId'] == 66105), hasLength(1));
      expect(regels.where((l) => l['itemId'] == 8447), hasLength(1));
    },
  );

  test('a preparation line is linked at most once', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(
        extra: {
          'warehouseId': 2,
          'detailItems': [
            {'id': 186, 'itemId': 66105, 'quantity': 2},
          ],
          'wip': [
            {'id': 1, 'itemId': 66105, 'jobOrderDetailItemId': 186},
          ],
        },
      ),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
      extras: [
        ScannedExtra(
          item: {'id': 66105, 'code': 'X1', 'description': 'Hose'},
          scannedCount: 1,
        ),
      ],
    );

    final wip = (body['wip'] as List).cast<Map>();
    expect(wip.last['jobOrderDetailItemId'], 0);
  });

  test('appends manually entered extras as generic detailMisc lines', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(
        extra: {
          'warehouseId': 2,
          'detailMisc': [
            {'id': 2, 'miscId': 1, 'quantity': 1},
          ],
        },
      ),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
      extras: [
        ScannedExtra(
          item: {'id': null, 'code': 'CUSTOM', 'description': 'Custom seal'},
          scannedCount: 3,
        ),
      ],
    );

    expect(body['detailMisc'], [
      {'id': 2, 'miscId': 1, 'quantity': 1},
      {
        'id': 0,
        'dateChanged': isA<String>(),
        'delete': false,
        'recordTag': null,
        'description': 'Custom seal',
        'quantity': 3,
        'miscId': 1,
        'jobOrderId': 79,
        'deliveryMethod': 1,
        'registrationPath': 3,
      },
    ]);
  });

  test('a material-only publication preserves existing hours and finishTime', () {
    final existingHours = [
      {'id': 4, 'memo': 'Previously submitted'},
    ];
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(
        extra: {
          'warehouseId': 2,
          'hours': existingHours,
          'finishTime': '2026-09-17T12:00:00Z',
        },
      ),
      appointmentId: 112,
      employeeId: 6,
      hours: const [],
      uniqueId: 'x',
      extras: [
        ScannedExtra(
          item: {'id': 8447, 'description': 'Oil filter'},
          scannedCount: 1,
        ),
      ],
    );

    expect(body['hours'], existingHours);
    expect(body['finishTime'], '2026-09-17T12:00:00Z');
  });

  test('readyForSignature is forced to false even if the source had true', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {'readyForSignature': true}),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(body['readyForSignature'], false);
  });

  test(
    'finishTime is set to the latest end across the submitted hours lines',
    () {
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
        employeeId: 6,
        hours: [earlier, later],
        uniqueId: 'x',
      );
      expect(body['finishTime'], '2026-08-22T13:30:00Z');
    },
  );

  test('followup defaults to false only when missing', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(body['followup'], false);

    final passthrough = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {'followup': true}),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(passthrough['followup'], true);
  });

  test('onHold komt alleen uit de parameter, nooit uit de bron', () {
    // Standaard false.
    final standaard = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(standaard['onHold'], false);

    // Een bon die van een eerdere onderbreking nog onHold:true heeft, mag
    // dat niet doorgeven: Ridder boekt dan geen projecturen (zie onderzoek
    // tussentijdse uren, okt 2026).
    final staleBron = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {'onHold': true}),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(staleBron['onHold'], false);

    // Expliciet onderbreken blijft mogelijk.
    final onderbroken = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
      onHold: true,
    );
    expect(onderbroken['onHold'], true);
  });

  test(
    'adds delete:false into the existing order object without dropping other fields',
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(
          extra: {
            'order': {'id': 5, 'recordtag': 'ORD-5'},
          },
        ),
        appointmentId: 112,
        employeeId: 6,
        hours: [entry()],
        uniqueId: 'x',
      );
      expect(body['order'], {'id': 5, 'recordtag': 'ORD-5', 'delete': false});
    },
  );

  test('order.delete is left untouched if the source already set it', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(
        extra: {
          'order': {'id': 5, 'delete': true},
        },
      ),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect((body['order'] as Map)['delete'], true);
  });

  test(
    'fills contact/signature/alternativeServiceAddress with the confirmed stub when missing',
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(),
        appointmentId: 112,
        employeeId: 6,
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
    },
  );

  test(
    'passes through an existing non-null contact/signature/alternativeServiceAddress',
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(
          extra: {
            'contact': {'id': 42, 'email': 'real@example.com'},
          },
        ),
        appointmentId: 112,
        employeeId: 6,
        hours: [entry()],
        uniqueId: 'x',
      );
      expect(body['contact'], {'id': 42, 'email': 'real@example.com'});
    },
  );

  test(
    'patches serviceObject with the four missing dates and lastKnownMeterReading',
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(
          extra: {
            'serviceObject': {
              'id': 11,
              'description': 'Vaartuig',
              'objectLocation': {'id': 3},
            },
          },
        ),
        appointmentId: 112,
        employeeId: 6,
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
    },
  );

  test('does not overwrite existing serviceObject date fields', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(
        extra: {
          'serviceObject': {'id': 11, 'buildDate': '2020-01-01T00:00:00Z'},
        },
      ),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect((body['serviceObject'] as Map)['buildDate'], '2020-01-01T00:00:00Z');
  });

  test(
    'changedServiceObject is built as a full copy of the patched serviceObject',
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(
          extra: {
            'serviceObject': {'id': 11, 'description': 'Vaartuig'},
          },
        ),
        appointmentId: 112,
        employeeId: 6,
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
    },
  );

  test(
    'changedServiceObject falls back to a stub when there is no serviceObject at all',
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(),
        appointmentId: 112,
        employeeId: 6,
        hours: [entry()],
        uniqueId: 'x',
      );

      final cso = body['changedServiceObject'] as Map<String, dynamic>;
      expect(cso['id'], 0);
      expect(cso['buildDate'], '1900-01-01T00:00:00Z');
      expect(cso['lastKnownMeterReading'], 0.0);
    },
  );

  test('omits htmlFile entirely, even if present on the source job order', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {'htmlFile': 'placeholder.pdf'}),
      appointmentId: 112,
      employeeId: 6,
      hours: const [],
      uniqueId: 'x',
    );
    expect(body.containsKey('htmlFile'), isFalse);
  });

  test('overwrites any existing hours array on the source job order', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(
        extra: {
          'hours': [
            {'id': 1, 'stale': true},
          ],
        },
      ),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
    );
    expect(body['hours'], hasLength(1));
    expect((body['hours'] as List).single, entry().toJson());
  });

  test(
    'uses signaturePaths/signerName for the signature field when provided',
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(
          extra: {
            'signature': {'id': 9, 'name': 'stale'},
          },
        ),
        appointmentId: 112,
        employeeId: 6,
        hours: [entry()],
        uniqueId: 'x',
        signaturePaths: [
          [
            [0, 0],
            [1, 2],
          ],
        ],
        signerName: 'J. Jansen',
      );

      expect(body['signature'], {
        'id': 0,
        'dateChanged': isA<String>(),
        'delete': false,
        'recordTag': null,
        'name': 'J. Jansen',
        'email': null,
        'paths': [
          [
            [0, 0],
            [1, 2],
          ],
        ],
      });
    },
  );

  test('signature paths are int32 and survive a JSON round-trip as ints', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
      signaturePaths: SignatureCapture.pathsFromJson([
        [
          [279.6666666666667, 10.4],
          [280.5, 11.49],
        ],
      ]),
    );

    final encoded = jsonEncode(body['signature']);
    expect(encoded, contains('"paths":[[[280,10],[281,11]]]'));
  });

  test(
    'empty strokes are dropped; only-empty strokes fall back to the stub',
    () {
      final withEmpty = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(),
        appointmentId: 112,
        employeeId: 6,
        hours: [entry()],
        uniqueId: 'x',
        signaturePaths: [
          [],
          [
            [1, 2],
          ],
          [],
        ],
      );
      expect((withEmpty['signature'] as Map)['paths'], [
        [
          [1, 2],
        ],
      ]);

      final onlyEmpty = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(),
        appointmentId: 112,
        employeeId: 6,
        hours: [entry()],
        uniqueId: 'x',
        signaturePaths: [[], []],
      );
      expect((onlyEmpty['signature'] as Map)['paths'], isNull);
    },
  );

  test(
    "a source job order's signature is cut down to the seven schema fields",
    () {
      final body = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(
          extra: {
            'signature': {
              'id': 9,
              'dateChanged': '2026-01-01T00:00:00Z',
              'delete': false,
              'recordTag': 'x',
              'name': 'Klant',
              'email': 'klant@example.com',
              'paths': [
                [
                  [1.6, 2.2],
                ],
                [],
              ],
              'signedAt': '2026-01-01T00:00:00Z',
              'image': 'base64...',
            },
          },
        ),
        appointmentId: 112,
        employeeId: 6,
        hours: [entry()],
        uniqueId: 'x',
      );

      expect(body['signature'], {
        'id': 9,
        'dateChanged': '2026-01-01T00:00:00Z',
        'delete': false,
        'recordTag': 'x',
        'name': 'Klant',
        'email': 'klant@example.com',
        'paths': [
          [
            [2, 2],
          ],
        ],
      });
    },
  );

  test('an empty signaturePaths list falls back to the confirmed stub', () {
    final body = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
      signaturePaths: const [],
      signerName: 'J. Jansen',
    );

    expect(body['signature'], {
      'id': 0,
      'dateChanged': '1900-01-01T00:00:00Z',
      'delete': false,
      'recordTag': null,
      'name': null,
      'email': null,
      'paths': null,
    });
  });

  test('does not mutate the source job order map', () {
    final raw = baseJobOrder(
      extra: {
        'order': {'id': 5},
        'serviceObject': {'id': 11},
      },
    );

    buildServiceRemoteJobOrderSubmission(
      rawJobOrder: raw,
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'x',
    );

    expect(raw.containsKey('uniqueId'), isFalse);
    expect(raw.containsKey('appointment'), isFalse);
    expect(raw.containsKey('hours'), isFalse);
    expect((raw['order'] as Map).containsKey('delete'), isFalse);
    expect((raw['serviceObject'] as Map).containsKey('buildDate'), isFalse);
  });

  group('memo\'s naar "Gerealiseerde oplossing"', () {
    HoursEntry metMemo(String? memo, {int minuten = 480}) => HoursEntry(
      jobOrderId: 79,
      employeeId: 6,
      start: DateTime(2026, 9, 28, 8),
      end: DateTime(2026, 9, 28, 8).add(Duration(minutes: minuten)),
      totalTime: minuten,
      timeEmployee: minuten,
      workActivityId: 20,
      uniqueId: 'g',
      memo: memo,
    );

    test('één regel per urenregel met memo, met monteursnaam', () {
      final regels = hoursMemoLines([
        metMemo('Motor uit elkaar gehaald'),
        metMemo(null),
        metMemo('   '),
        metMemo('Pakking\nvervangen', minuten: 138),
      ], employeeName: 'Lex de Bruijn');
      expect(regels, [
        'Ma 28-09 · Lex de Bruijn · 8u00 · Motor uit elkaar gehaald',
        'Ma 28-09 · Lex de Bruijn · 2u18 · Pakking vervangen',
      ]);
    });

    test('bestaande tekst blijft staan, geen dubbele regels', () {
      const regel = 'Ma 28-09 · Lex · 8u00 · Motor';
      final eerste = appendToRealizedSolution('Filter vervangen.', [regel]);
      expect(eerste, 'Filter vervangen.\n$regel');
      expect(appendToRealizedSolution(eerste, [regel]), eerste);
      expect(appendToRealizedSolution(null, [regel]), regel);
    });

    test('RTF: regels als alinea vóór de afsluitende accolade', () {
      const rtf = r'{\rtf1\ansi Bestaand}';
      final uit = appendToRealizedSolution(rtf, ['Ma 28-09 · Motor']);
      expect(uit.startsWith(r'{\rtf1\ansi Bestaand\par Ma 28-09 \u183? Motor'), isTrue);
      expect(uit.endsWith('}'), isTrue);
      expect(appendToRealizedSolution(uit, ['Ma 28-09 · Motor']), uit);
    });

    test('builder zet realizedSolution alleen bij memo\'s', () {
      final zonder = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(extra: {'realizedSolution': 'Oud'}),
        appointmentId: 112,
        employeeId: 6,
        hours: [metMemo(null)],
        uniqueId: 'u',
        employeeName: 'Lex',
      );
      expect(zonder['realizedSolution'], 'Oud');

      final met = buildServiceRemoteJobOrderSubmission(
        rawJobOrder: baseJobOrder(extra: {'realizedSolution': 'Oud'}),
        appointmentId: 112,
        employeeId: 6,
        hours: [metMemo('Motor')],
        uniqueId: 'u',
        employeeName: 'Lex',
      );
      expect(met['realizedSolution'], 'Oud\nMa 28-09 · Lex · 8u00 · Motor');
    });
  });

  test('htmlFile alleen uit de parameter, nooit uit de bron', () {
    final zonder = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {'htmlFile': 'oud'}),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'u',
    );
    expect(zonder.containsKey('htmlFile'), isFalse);

    final met = buildServiceRemoteJobOrderSubmission(
      rawJobOrder: baseJobOrder(extra: {'htmlFile': 'oud'}),
      appointmentId: 112,
      employeeId: 6,
      hours: [entry()],
      uniqueId: 'u',
      htmlFile: '<html>rapport</html>',
      signaturePaths: [
        [
          [1, 2],
          [3, 4],
        ],
      ],
      signerName: 'P. Jansen',
      signerEmail: ' p@jansen.nl ',
    );
    // Base64 van de UTF-8-HTML.
    expect(met['htmlFile'], 'PGh0bWw+cmFwcG9ydDwvaHRtbD4=');
    expect(met['signature']['name'], 'P. Jansen');
    expect(met['signature']['email'], 'p@jansen.nl');
  });
}
