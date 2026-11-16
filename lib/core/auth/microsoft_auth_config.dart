/// Instellingen voor inloggen met een Microsoft-werkaccount (Entra ID) via
/// Firebase Auth.
class MicrosoftAuthConfig {
  /// Hoofdschakelaar. Staat deze uit, dan toont het inlogscherm de oude
  /// medewerkerskeuze en geen Microsoft-knop. Zet op `true` om Microsoft-login
  /// weer in te schakelen (en het tenant-id hieronder in te vullen).
  static const enabled = false;

  /// Tenant-id (Directory ID) van Engine Energy in Microsoft Entra ID.
  /// Te vinden in het Azure-portaal bij de app-registratie. Hiermee kunnen
  /// alleen accounts uit deze organisatie inloggen.
  static const tenantId = '32cbb991-717f-468a-9d8d-31791fe94098';

  static bool get isConfigured =>
      tenantId.isNotEmpty && !tenantId.startsWith('VUL_HIER');
}
