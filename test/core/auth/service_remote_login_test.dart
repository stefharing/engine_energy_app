import 'package:flutter_test/flutter_test.dart';

import 'package:engine_energy_app/core/auth/credentials.dart';

void main() {
  test('uses employee, not login record id, as the mechanic id', () {
    final login = ServiceRemoteLogin.fromJson({
      'id': 24,
      'recordTag': 'Lex de Bruijn',
      'username': 'LEXDEBRUIJN',
      'employee': 6,
    });

    expect(login.loginRecordId, 24);
    expect(login.mechanicId, 6);
    expect(login.mechanicId, isNot(login.loginRecordId));
  });
}
