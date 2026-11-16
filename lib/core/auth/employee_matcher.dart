import 'employee.dart';

String _norm(Object? v) => (v?.toString() ?? '').trim().toLowerCase();

/// Zoekt de monteur die bij een Microsoft-account hoort.
///
/// [emails] zijn de e-mailadressen van het Microsoft-account (meestal één).
/// [ridderEmployees] komt uit `GET /hours/employees` (velden `id`, `code`,
/// `email`); [fieldEngineers] is de monteurslijst waar de app mee werkt
/// (`/ServiceRemote/Employee`). Het resultaat komt uit die laatste lijst, zodat
/// id, naam en code precies zijn wat de rest van de app al gebruikt.
///
/// Geeft `null` als het e-mailadres in Ridder niet voorkomt of de persoon geen
/// monteur is. Vergelijken gaat hoofdletterongevoelig; de koppeling tussen de twee
/// lijsten loopt via de code, met het id als terugval.
Employee? matchEmployeeByEmail({
  required Iterable<String> emails,
  required List<Map<String, dynamic>> ridderEmployees,
  required List<Employee> fieldEngineers,
}) {
  final wanted = emails.map(_norm).where((e) => e.isNotEmpty).toSet();
  if (wanted.isEmpty) return null;

  for (final r in ridderEmployees) {
    if (!wanted.contains(_norm(r['email']))) continue;
    final code = _norm(r['code']);
    final id = r['id'];
    for (final e in fieldEngineers) {
      if (code.isNotEmpty && _norm(e.code) == code) return e;
    }
    for (final e in fieldEngineers) {
      if (id is num && e.id == id.toInt()) return e;
    }
  }
  return null;
}
