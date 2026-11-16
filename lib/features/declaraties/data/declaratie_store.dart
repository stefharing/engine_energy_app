import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/declaratie.dart';

/// Lokale opslag van de declaraties van één monteur (SharedPreferences,
/// per monteur-id). Schrijfacties lopen achter elkaar, zodat twee
/// tegelijkertijd lopende updates (bijv. versturen en verwijderen) elkaar
/// niet overschrijven.
class DeclaratieStore {
  DeclaratieStore._();
  static final instance = DeclaratieStore._();

  static String sleutel(int monteurId) => 'declaraties_v1_$monteurId';

  Future<void> _ketting = Future.value();

  Future<T> _serieel<T>(Future<T> Function() werk) {
    final resultaat = _ketting.then((_) => werk());
    _ketting = resultaat.then<void>((_) {}, onError: (_) {});
    return resultaat;
  }

  /// Alle declaraties van de monteur, nieuwste eerst.
  Future<List<Declaratie>> laad(int monteurId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(sleutel(monteurId));
    if (raw == null || raw.isEmpty) return [];
    try {
      final lijst = (jsonDecode(raw) as List)
          .map((e) => Declaratie.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      lijst.sort((a, b) => b.aangemaaktOp.compareTo(a.aangemaaktOp));
      return lijst;
    } catch (_) {
      return [];
    }
  }

  Future<Declaratie?> vind(int monteurId, String id) async {
    for (final d in await laad(monteurId)) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Voegt de declaratie toe of vervangt die met hetzelfde id.
  Future<void> bewaar(int monteurId, Declaratie declaratie) => _serieel(() async {
    final lijst = await laad(monteurId);
    final index = lijst.indexWhere((d) => d.id == declaratie.id);
    if (index >= 0) {
      lijst[index] = declaratie;
    } else {
      lijst.add(declaratie);
    }
    await _schrijf(monteurId, lijst);
  });

  Future<void> verwijder(int monteurId, String id) => _serieel(() async {
    final lijst = await laad(monteurId);
    lijst.removeWhere((d) => d.id == id);
    await _schrijf(monteurId, lijst);
  });

  Future<void> _schrijf(int monteurId, List<Declaratie> lijst) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      sleutel(monteurId),
      jsonEncode(lijst.map((d) => d.toJson()).toList()),
    );
  }
}
