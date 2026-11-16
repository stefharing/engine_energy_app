import 'package:engine_energy_app/features/planning/models/signature_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pathsFromJson rounds coordinates to ints', () {
    expect(
      SignatureCapture.pathsFromJson([
        [
          [279.6666666666667, 0.49],
          [3, 4.5],
        ],
      ]),
      [
        [
          [280, 0],
          [3, 5],
        ],
      ],
    );
  });

  test('pathsFromJson drops empty strokes and malformed points', () {
    expect(
      SignatureCapture.pathsFromJson([
        [],
        [
          [1, 2],
          [1],
          ['a', 2],
        ],
        [
          [1, 2, 3],
        ],
      ]),
      [
        [
          [1, 2],
        ],
      ],
    );
  });

  test('pathsFromJson treats null / non-lists as no signature', () {
    expect(SignatureCapture.pathsFromJson(null), isEmpty);
    expect(SignatureCapture.pathsFromJson('x'), isEmpty);
  });
}
