import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small locally-learned history of text a technician has previously typed
/// into a given work-report field, shown back as tappable snippet chips —
/// "standaardteksten uit eerdere rapporten". Not scoped to a single bon:
/// the whole point is to recall phrasing used on *other* reports too.
///
/// Stored as a capped, most-recent-first, de-duplicated list per field key
/// in SharedPreferences.
class WorkReportSnippets {
  WorkReportSnippets._();

  static const _maxPerField = 5;

  static String _prefsKey(String fieldKey) => 'work_report_snippets_$fieldKey';

  static Future<List<String>> forField(String fieldKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey(fieldKey));
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded.cast<String>();
  }

  /// Records [text] as the most-recently-used snippet for [fieldKey].
  /// No-ops for blank text.
  static Future<void> recordUsage(String fieldKey, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final existing = await forField(fieldKey);
    final updated = [trimmed, ...existing.where((s) => s != trimmed)]
        .take(_maxPerField)
        .toList();
    await prefs.setString(_prefsKey(fieldKey), jsonEncode(updated));
  }
}
