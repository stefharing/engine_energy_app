import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const _hiddenKey = 'hidden_employee_ids';
  static const _orderKey = 'employee_order';

  SettingsService._();
  static final instance = SettingsService._();

  Future<Set<int>> loadHiddenIds() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_hiddenKey) ?? [];
    return list.map(int.parse).toSet();
  }

  Future<void> saveHiddenIds(Set<int> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _hiddenKey,
      ids.map((id) => id.toString()).toList(),
    );
  }

  Future<List<int>> loadEmployeeOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_orderKey) ?? [];
    return list.map(int.parse).toList();
  }

  Future<void> saveEmployeeOrder(List<int> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _orderKey,
      ids.map((id) => id.toString()).toList(),
    );
  }
}
