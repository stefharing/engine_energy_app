import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/signature_capture.dart';

/// Persists a bon's customer signature locally — both the rendered PNG
/// (base64) and its vector `paths`, the same way [HoursDraftService]
/// persists hour cards — so leaving and reopening "Klant laten tekenen"
/// still shows the signature that was captured last, and it can still be
/// submitted to Ridder from a later session without having to be redrawn.
class SignatureDraftService {
  SignatureDraftService._();
  static final instance = SignatureDraftService._();

  String _keyFor(String orderId) => 'signature_$orderId';

  Future<SignatureCapture?> load(String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyFor(orderId));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return SignatureCapture(
        png: base64Decode(decoded['png'] as String),
        paths: SignatureCapture.pathsFromJson(decoded['paths']),
      );
    } on FormatException {
      // A draft saved before `paths` existed is a bare base64 PNG string —
      // no vector strokes to recover, only the image.
      return SignatureCapture(png: base64Decode(raw), paths: const []);
    }
  }

  Future<void> save(String orderId, SignatureCapture capture) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyFor(orderId),
      jsonEncode({'png': base64Encode(capture.png), 'paths': capture.paths}),
    );
  }
}
