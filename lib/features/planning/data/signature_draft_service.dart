import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists a bon's customer signature locally (base64-encoded PNG), the
/// same way [HoursDraftService] persists hour cards — so leaving and
/// reopening "Klant laten tekenen" still shows the signature that was
/// captured last, and it can be redrawn from there.
class SignatureDraftService {
  SignatureDraftService._();
  static final instance = SignatureDraftService._();

  String _keyFor(String orderId) => 'signature_$orderId';

  Future<Uint8List?> load(String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyFor(orderId));
    if (raw == null) return null;
    return base64Decode(raw);
  }

  Future<void> save(String orderId, Uint8List bytes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFor(orderId), base64Encode(bytes));
  }
}
