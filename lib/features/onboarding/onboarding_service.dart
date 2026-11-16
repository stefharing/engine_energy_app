import 'package:shared_preferences/shared_preferences.dart';

/// Onthoudt (per toestel) of de welkomstuitleg al getoond is.
///
/// Verhoog het versienummer in [_key] om de uitleg na een grote update
/// opnieuw aan iedereen te tonen.
class OnboardingService {
  OnboardingService._();
  static final instance = OnboardingService._();

  static const _key = 'onboarding_v1_gezien';

  /// `true` als de uitleg op dit toestel nog niet is afgerond.
  Future<bool> moetTonen() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_key) ?? false);
  }

  Future<void> markeerGezien() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }
}
