import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_config.dart';

/// Een uursoort (`/workactivity/workactivities`) zoals de app hem gebruikt.
@immutable
class WorkActivity {
  const WorkActivity({
    required this.id,
    required this.code,
    required this.description,
  });

  final int id;
  final String code;
  final String description;

  /// Korte naam voor in de app: omschrijving zonder "Service Engineer".
  String get label => description.replaceFirst('Service Engineer ', 'Service ');

  Map<String, dynamic> toJson() => {
    'id': id,
    'code': code,
    'description': description,
  };

  factory WorkActivity.fromJson(Map<String, dynamic> j) => WorkActivity(
    id: (j['id'] as num).toInt(),
    code: j['code'] as String? ?? '',
    description: j['description'] as String? ?? '',
  );
}

/// De uursoorten van de actieve Ridder-administratie, opgezocht op **code**.
///
/// Ridder-id's verschillen per administratie (live `SRV-NL` = 24, in test
/// een ander nummer), dus de app bewaart bij een urenkaart de code en zoekt
/// pas bij het versturen het id op in de administratie waar naartoe
/// verstuurd wordt. De lijst wordt per administratie in de cache bewaard,
/// zodat hij ook offline beschikbaar is.
///
/// Welke uursoorten de monteur kan kiezen ([werkOpties]): alle "Directe
/// uren" die voor tijdregistratie in de app zijn vrijgegeven, behalve
/// reistijd ([reistijdCode], apart als "Reistijd") en de oude codes met een
/// `Z` ervoor (ZSRV-NL, ZSRV-ABR, ZTRAV-H — dubbelingen van de gewone codes).
class WorkActivityCatalog {
  WorkActivityCatalog._();
  static final instance = WorkActivityCatalog._();

  static const reistijdCode = 'TRAV-H';

  /// Uursoort "Indirecte uren" (workactivitytype 15): uren die niet op een
  /// bon staan. Alleen te boeken via `/hours/projecttimes` zonder bon.
  static const indirectCode = '1140';

  /// Bewerking "Overnachting": een indirecte projecttijd van 0 uur op de dag
  /// van de overnachting (zonder bon). Let op: in live staat deze bewerking
  /// (okt 2026) als "Directe uren", in test als "Indirecte uren".
  static const overnachtingCode = 'OVERNACHT';

  /// Bewerking "Compensatie uren" (bijv. na weekendwerk): indirecte
  /// projecttijd zonder bon. Net als OVERNACHT staat deze in live (okt 2026)
  /// als "Directe uren" en in test als "Indirecte uren".
  static const compensatieCode = 'COMP';

  /// Bewerkingen die alleen zonder bon (indirect) geboekt worden.
  static const zonderBonCodes = {
    indirectCode,
    overnachtingCode,
    compensatieCode,
  };

  /// Wat de vroegere vaste id's in de app betekenden, voor urenkaarten die
  /// nog zonder code zijn opgeslagen. 21/22/26 (overwerk, machinale
  /// bewerkingen) hebben geen bekende code en bestaan niet in live; die
  /// moet de monteur opnieuw kiezen.
  static const legacyCodes = {20: 'SRV-NL', 23: 'SRV-ABR', 24: 'TRAV-H'};

  /// Laatste redmiddel als de lijst nog nooit is opgehaald en er geen
  /// verbinding is: de bekende live-waarden (uit Ridder, 29-09-2026).
  static const _liveStandaard = [
    WorkActivity(
      id: 24,
      code: 'SRV-NL',
      description: 'Service Engineer NL (Standaard)',
    ),
    WorkActivity(
      id: 27,
      code: 'SRV-ABR',
      description: 'Service Engineer Abroad (Dagtarief)',
    ),
    WorkActivity(id: 28, code: 'TRAV-H', description: 'Reisuren (Uurtarief)'),
  ];

  final _perAdministratie = <String, List<WorkActivity>>{};

  static String _cacheSleutel(String administratie) =>
      'work_activities_$administratie';

  List<WorkActivity> get _huidig {
    final admin = ApiConfig.administrationId;
    final lijst = _perAdministratie[admin];
    if (lijst != null) return lijst;
    return ApiConfig.environment == ApiEnvironment.live
        ? _liveStandaard
        : const [];
  }

  bool get isGeladen =>
      _perAdministratie.containsKey(ApiConfig.administrationId);

  /// Haalt de uursoorten op (of uit de cache). Veilig om vaak aan te
  /// roepen; na de eerste keer per administratie direct klaar, tenzij
  /// [vernieuw].
  Future<void> laad({bool vernieuw = false}) async {
    final admin = ApiConfig.administrationId;
    if (!vernieuw && _perAdministratie.containsKey(admin)) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      final response = await ApiClient.instance.dio
          .get(
            '/workactivity/workactivities',
            queryParameters: {'page': 1, 'size': 200, 'sort': 'id.asc'},
          )
          .timeout(const Duration(seconds: 10));
      final lijst = parseDirecteUren(
        (response.data['data'] as List).cast<Map<String, dynamic>>(),
      );
      _perAdministratie[admin] = lijst;
      await prefs.setString(
        _cacheSleutel(admin),
        jsonEncode(lijst.map((w) => w.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('Uursoorten niet opgehaald ($admin), cache gebruikt: $e');
      final raw = prefs.getString(_cacheSleutel(admin));
      if (raw != null) {
        _perAdministratie[admin] = (jsonDecode(raw) as List)
            .map(
              (j) => WorkActivity.fromJson(Map<String, dynamic>.from(j as Map)),
            )
            .toList();
      }
    }
  }

  /// Uit een `/workactivity/workactivities`-response: alleen "Directe uren"
  /// (workactivitytype 16) die voor tijdregistratie in de app gelden.
  static List<WorkActivity> parseDirecteUren(List<Map<String, dynamic>> data) =>
      [
        for (final w in data)
          if (((w['workactivitytype'] as Map?)?['choicenumber'] == 16 &&
                  w['timeregistrationapp'] != false) ||
              zonderBonCodes.contains(
                (w['code'] as String? ?? '').trim().toUpperCase(),
              ))
            WorkActivity(
              id: (w['id'] as num).toInt(),
              code: (w['code'] as String? ?? '').trim(),
              description: (w['description'] as String? ?? '').trim(),
            ),
      ];

  /// De uursoorten waaruit de monteur kan kiezen (zonder reistijd).
  List<WorkActivity> get werkOpties => [
    for (final w in _huidig)
      if (!w.code.toUpperCase().startsWith('Z') &&
          !w.code.toUpperCase().startsWith('TRAV') &&
          !zonderBonCodes.contains(w.code.toUpperCase()))
        w,
  ];

  /// Reistijd (`TRAV-H`), als die in deze administratie bestaat.
  WorkActivity? get reistijd => perCode(reistijdCode);

  /// "Indirecte uren", als die in deze administratie bestaat.
  WorkActivity? get indirect => perCode(indirectCode);

  /// "Overnachting", als die in deze administratie bestaat.
  WorkActivity? get overnachting => perCode(overnachtingCode);

  /// "Compensatie uren", als die in deze administratie bestaat.
  WorkActivity? get compensatie => perCode(compensatieCode);

  WorkActivity? perCode(String? code) {
    if (code == null) return null;
    for (final w in _huidig) {
      if (w.code.toUpperCase() == code.toUpperCase()) return w;
    }
    return null;
  }

  /// De code van een urenkaart: de opgeslagen code, of voor oude kaarten de
  /// betekenis van het vroegere vaste id.
  static String? codeVoorKaart({String? code, int? id}) =>
      (code != null && code.isNotEmpty) ? code : legacyCodes[id];

  /// Het id in de actieve administratie voor een urenkaart, of `null` als
  /// die uursoort hier niet bestaat.
  int? idVoorKaart({String? code, int? id}) =>
      perCode(codeVoorKaart(code: code, id: id))?.id;

  /// Leesbare naam voor een urenkaart.
  String labelVoorKaart({String? code, int? id}) {
    final c = codeVoorKaart(code: code, id: id);
    if (c == reistijdCode) return 'Reistijd';
    return perCode(c)?.label ?? (c ?? 'Onbekende uursoort');
  }
}
