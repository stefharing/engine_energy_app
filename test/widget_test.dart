import 'package:flutter_test/flutter_test.dart';

import 'package:engine_energy_app/main.dart';

void main() {
  test('app root is EngineEnergyApp', () {
    const app = EngineEnergyApp();
    expect(app, isA<EngineEnergyApp>());
  });
}
