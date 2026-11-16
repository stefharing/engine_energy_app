import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/auth_service.dart';
import '../../uren_overzicht/data/uren_overzicht_service.dart';
import '../data/hours_draft_service.dart'
    show HoursDraftService, kmCardType, maandagVanWeek;
import '../data/hours_sync_service.dart';
import '../data/work_activity_catalog.dart';
import '../data/planning_repository.dart';
import '../data/service_remote_job_order_repository.dart';
import '../models/job_order.dart';
import '../../../core/theme/app_colors.dart';
import 'week_afsluiten_screen.dart';

// SharedPreferences key for a bon's local (not-yet-submitted) hours draft.
// Also used by [HoursDraftService], which lets [BonDetailScreen]'s publish
// button read/write the exact same draft this screen does.
String hoursDraftKeyForOrder(String orderId) => 'hours_week_draft_$orderId';

/// Vroeger: vinkje "Overnachting" per bon (lokaal bewaard). Sinds okt 2026
/// worden overnachtingen als eigen bewerking geboekt vanuit het indirecte
/// urenscherm; de sleutel blijft alleen bestaan voor oude gegevens.
String overnachtingKeyForOrder(String orderId) => 'overnachting_$orderId';

/// Turns a [ServiceRemoteJobOrderRepository.submitHoursForJobOrder] failure
/// into the Dutch message shown next to the submit button — shared with
/// [HoursDraftService] so a publish failure from [BonDetailScreen] reads
/// the same way as one from this screen.
String describeHoursSubmitError(Object error) {
  if (error is JobOrderSubmissionLoginFailed) {
    return 'Inloggen mislukt bij indienen.\n$error';
  }
  if (error is JobOrderSubmissionFetchFailed) {
    return 'Bon ophalen mislukt.\n$error';
  }
  if (error is JobOrderSubmissionAppointmentNotFound) {
    return 'Deze bon is niet aan jou toegewezen.\n$error';
  }
  if (error is JobOrderSubmissionAppointmentOpenFailed) {
    return 'Afspraak openen mislukt.\n$error';
  }
  if (error is JobOrderSubmissionAppointmentCloseFailed) {
    return 'Afspraak afsluiten mislukt.\n$error';
  }
  if (error is JobOrderSubmissionBezetDoorCollega) {
    return error.message;
  }
  if (error is JobOrderSubmissionSyncFailed) {
    return 'Geen verbinding met de gedeelde opslag. Probeer het opnieuw '
        'zodra je internet hebt.\n$error';
  }
  if (error is JobOrderSubmissionPostFailed) {
    return 'Indienen van de uren mislukt.\n$error';
  }
  return 'Indienen mislukt.\n$error';
}

// The dashboard's accent orange, reused here so this screen's interactive
// accents (selected states, buttons, links) match the rest of the app
// instead of Cupertino's default blue.
const _accentOrange = Color(0xFFFF6B2B);

const _fullDayNames = [
  '',
  'Maandag',
  'Dinsdag',
  'Woensdag',
  'Donderdag',
  'Vrijdag',
  'Zaterdag',
  'Zondag',
];

/// A selectable "hour type" in the add-entry sheet — the existing Uursoort
/// options (Service NL, Service Abroad, Overwerk, ...) plus Reistijd
/// (travel), which used to be its own separate input field. Merging it in
/// here matches how the API actually models hours: one `workActivityId` per
/// line, no structural distinction between "work" and "travel" beyond that.
class _HourType {
  const _HourType(this.code, this.label, this.icon, this.color);

  /// Ridder-code van de uursoort (bijv. `SRV-NL`); het id wordt pas bij
  /// versturen opgezocht in de actieve administratie.
  final String code;
  final String label;
  final IconData icon;
  final Color color;
}

/// De kiesbare uursoorten, uit Ridder (per administratie, zie
/// [WorkActivityCatalog]) plus Reistijd.
List<_HourType> get _hourTypes {
  final catalogus = WorkActivityCatalog.instance;
  return [
    for (final w in catalogus.werkOpties)
      _HourType(
        w.code,
        w.label,
        CupertinoIcons.hammer_fill,
        const Color(0xFF34C759),
      ),
    if (catalogus.reistijd != null)
      const _HourType(
        WorkActivityCatalog.reistijdCode,
        'Reistijd',
        CupertinoIcons.car_fill,
        _accentOrange,
      ),
  ];
}

/// Display type for kilometers cards — not an Uursoort; km cards are
/// published as the "Kilometers" article instead (see `HoursDraftService`).
const _kmType = _HourType(
  'KM',
  'Kilometers',
  CupertinoIcons.car_fill,
  Color(0xFF007AFF),
);

/// Weergave van de uursoort "Indirecte uren" (uren zonder bon).
const _indirectType = _HourType(
  WorkActivityCatalog.indirectCode,
  'Indirecte uren',
  CupertinoIcons.clock_fill,
  Color(0xFF5856D6),
);

/// Weergave van een overnachting (bewerking OVERNACHT, 0 uur, zonder bon).
const _overnachtingType = _HourType(
  WorkActivityCatalog.overnachtingCode,
  'Overnachting',
  CupertinoIcons.moon_zzz_fill,
  Color(0xFF30B0C7),
);

/// Duur waarmee een overnachting als projecttijd wordt geboekt: 0 uur
/// (getest okt 2026, Ridder accepteert een projecttijd van 00:00 op
/// OVERNACHT).
const _overnachtingMinuten = 0;

/// Weergave van compensatie-uren (bewerking COMP, zonder bon).
const _compensatieType = _HourType(
  WorkActivityCatalog.compensatieCode,
  'Compensatie-uren',
  CupertinoIcons.arrow_2_circlepath,
  Color(0xFFFF9500),
);

/// Typen die je in het indirecte urenscherm onder "Uren" kunt kiezen.
/// Compensatie alleen als die bewerking in deze administratie bestaat.
List<_HourType> get _indirecteTypes => [
  _indirectType,
  if (WorkActivityCatalog.instance.compensatie != null) _compensatieType,
];

bool _isOvernachting(_HourCard card) =>
    (card.workActivityCode ?? '').toUpperCase() ==
    WorkActivityCatalog.overnachtingCode;

/// Sleutel waaronder het concept van indirecte uren lokaal wordt bewaard
/// (in plaats van een bon-id) en waarmee de bonkiezer "Indirecte uren"
/// teruggeeft.
const _indirectDraftId = 'indirect';

/// Weergavetype van een urenkaart. Een kaart met een uursoort die in deze
/// administratie niet (meer) bestaat, krijgt een rode "Onbekend"-weergave.
_HourType _hourTypeVoorKaart(_HourCard card) {
  final code = WorkActivityCatalog.codeVoorKaart(
    code: card.workActivityCode,
    id: card.workActivityId,
  );
  if (code == WorkActivityCatalog.indirectCode) return _indirectType;
  if ((code ?? '').toUpperCase() == WorkActivityCatalog.overnachtingCode) {
    return _overnachtingType;
  }
  if ((code ?? '').toUpperCase() == WorkActivityCatalog.compensatieCode) {
    return _compensatieType;
  }
  for (final t in _hourTypes) {
    if (t.code == code) return t;
  }
  return _HourType(
    code ?? '?',
    '${WorkActivityCatalog.instance.labelVoorKaart(code: card.workActivityCode, id: card.workActivityId)} – kies opnieuw',
    CupertinoIcons.exclamationmark_triangle_fill,
    CupertinoColors.systemRed,
  );
}

/// Leesbare foutmelding van een Ridder-call: bij een 4xx/5xx de `title`,
/// `detail` en eventuele `errors` uit de Problem-response in plaats van
/// Dio's algemene tekst.
String _ridderFout(Object e) {
  if (e is! DioException) return '$e';
  final data = e.response?.data;
  final status = e.response?.statusCode;
  if (data is Map) {
    final delen = <String>[
      for (final k in ['title', 'detail', 'message'])
        if ((data[k] ?? '').toString().trim().isNotEmpty) '${data[k]}'.trim(),
      if (data['errors'] != null) '${data['errors']}',
    ];
    if (delen.isNotEmpty) return 'Ridder ($status): ${delen.join(' – ')}';
  }
  if (data != null && '$data'.trim().isNotEmpty) {
    return 'Ridder ($status): $data';
  }
  return 'Ridder ($status): ${e.message ?? e}';
}

String _formatMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}u' : '${h}u ${m}m';
}

double _parseDecimal(String text) =>
    double.tryParse(text.replaceAll(',', '.')) ?? 0.0;

/// A single locally-added entry for one day: either an amount of time,
/// tagged with an [_HourType], plus an optional short description — or,
/// when [km] is set, a number of kilometers driven. This is what the "+"
/// button in [HoursWeekScreen] creates.
class _HourCard {
  const _HourCard({
    required this.id,
    required this.workActivityId,
    this.workActivityCode,
    required this.minutes,
    this.km,
    this.memo,
    this.submitted = false,
    this.monteurId,
  });

  final String id;

  /// Medewerker die de kaart heeft ingevoerd (`null` bij oude kaarten).
  final int? monteurId;
  final int workActivityId;

  /// Ridder-code van de uursoort; `null` bij kaarten van vóór de koppeling
  /// op code (dan geldt [WorkActivityCatalog.legacyCodes]).
  final String? workActivityCode;
  final int minutes;
  final int? km;
  final String? memo;

  bool get isKm => km != null;

  /// Whether this card has already been sent to Ridder. Submitted cards
  /// stay visible (as a local record of what was sent) but are locked:
  /// greyed out, not swipe-to-delete, and excluded from the next submit.
  final bool submitted;

  _HourCard copyWith({bool? submitted}) => _HourCard(
    id: id,
    workActivityId: workActivityId,
    workActivityCode: workActivityCode,
    minutes: minutes,
    km: km,
    memo: memo,
    submitted: submitted ?? this.submitted,
    monteurId: monteurId,
  );

  Map<String, dynamic> toDraftJson() => {
    'id': id,
    if (isKm) 'type': kmCardType,
    'workActivityId': workActivityId,
    if (workActivityCode != null) 'workActivityCode': workActivityCode,
    'minutes': minutes,
    if (isKm) 'km': km,
    'memo': memo,
    'submitted': submitted,
    if (monteurId != null) 'monteurId': monteurId,
  };

  factory _HourCard.fromDraftJson(Map<String, dynamic> json) => _HourCard(
    id: json['id'] as String,
    workActivityId: json['workActivityId'] as int,
    workActivityCode: json['workActivityCode'] as String?,
    minutes: json['minutes'] as int,
    km: json['type'] == kmCardType ? json['km'] as int : null,
    memo: json['memo'] as String?,
    submitted: json['submitted'] as bool? ?? false,
    monteurId: (json['monteurId'] as num?)?.toInt(),
  );
}

/// Paginated day view for entering a technician's hours against a bon —
/// one day per page, swipeable, across a fixed 29-day window (2 weeks back
/// through 2 weeks forward from today) with the selected bon's planned days
/// highlighted. The bon to book hours onto is chosen via [_ProjectSelectorBar]
/// — either pre-filled with [initialOrder] (opened from a bon's detail
/// screen) or left empty for the technician to pick (opened from the
/// dashboard). Hours are entered as individual cards (amount + type +
/// description) via the "+" button, rather than fixed work/travel fields —
/// the same button adds a day's kilometers, via the sheet's Uren/Kilometers
/// tabs.
/// "Uren opslaan" only saves the draft locally — actually publishing to
/// Ridder happens in one go from the "Werk afronden" screen, via
/// `HoursDraftService.submitPendingHours`.
class HoursWeekScreen extends StatefulWidget {
  final ServiceOrder? initialOrder;

  /// Dag waarop het scherm opent (standaard vandaag), bijvoorbeeld vanuit
  /// het overzicht "Uren vorige week".
  final DateTime? initialDay;

  /// "Registreren"-modus: het scherm zelf blijft onzichtbaar en toont direct
  /// het invoersheet, waarin je ook de bon (of indirect) en de dag kiest.
  /// Na het toevoegen sluit het vanzelf. Zie [HoursWeekScreen.registreer].
  final bool registreerModus;

  const HoursWeekScreen({
    super.key,
    this.initialOrder,
    this.initialDay,
    this.registreerModus = false,
  });

  /// Opent direct het invoersheet boven het huidige scherm (dashboard of
  /// urenoverzicht). Levert `true` als er iets is toegevoegd.
  static Future<bool?> registreer(BuildContext context, {DateTime? dag}) {
    return Navigator.of(context).push<bool>(
      PageRouteBuilder<bool>(
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            HoursWeekScreen(initialDay: dag, registreerModus: true),
      ),
    );
  }

  @override
  State<HoursWeekScreen> createState() => _HoursWeekScreenState();
}

class _HoursWeekScreenState extends State<HoursWeekScreen> {
  late List<DateTime> _days;
  late final Map<String, List<_HourCard>> _cardsByDay;
  late final PageController _pageController;
  late List<GlobalKey> _dayChipKeys;
  int _currentPage = 0;
  ServiceOrder? _selectedOrder;

  /// Standaard boeken we indirecte uren (geen bon); alleen als het scherm
  /// vanuit een bon wordt geopend of de monteur bovenin een bon kiest, gaan
  /// de uren op die bon.
  late bool _indirect;

  bool _submitting = false;
  String? _submitError;
  Timer? _draftSaveTimer;
  final _uuid = const Uuid();

  String? _draftKeyFor(ServiceOrder? order) =>
      order == null ? null : hoursDraftKeyForOrder(order.id);

  /// Indirecte uren hebben geen lokaal concept: die staan per medewerker
  /// in Ridder en worden daar direct gelezen en geschreven.
  String? get _currentDraftKey => _indirect ? null : _draftKeyFor(_selectedOrder);

  /// Bezig met een verzoek voor indirecte uren (voorkomt dubbel tikken).
  bool _indirectBusy = false;

  static DateTime _dagVan(DateTime d) => DateTime(d.year, d.month, d.day);

  /// "08:00:00" → 480 minuten.
  static int _minutenUit(String? tijd) {
    final p = (tijd ?? '').split(':');
    if (p.length < 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  /// Haalt de indirecte uren van de ingelogde medewerker op uit Ridder en
  /// zet ze als kaarten op de juiste dag.
  Future<void> _loadIndirect() async {
    final employeeId = AuthService.instance.currentMechanicId;
    if (employeeId == null) {
      if (mounted) setState(() => _submitError = 'Je bent niet ingelogd.');
      return;
    }
    try {
      await WorkActivityCatalog.instance.laad();
      final entries = await PlanningRepository.instance
          .fetchIndirectProjectTimes(
            employeeId,
            from: _days.first,
            codes: WorkActivityCatalog.zonderBonCodes,
          );
      final perDag = <String, List<_HourCard>>{
        for (final d in _days) _key(d): <_HourCard>[],
      };
      for (final e in entries.reversed) {
        final datum = DateTime.tryParse(e['date'] as String? ?? '');
        if (datum == null) continue;
        final lijst = perDag[_key(_dagVan(datum))];
        if (lijst == null) continue;
        final id = (e['id'] as num).toInt();
        lijst.add(
          _HourCard(
            id: 'pt-$id',
            workActivityId: (e['workactivity'] as Map?)?['id'] as int? ?? 0,
            workActivityCode:
                ((e['workactivity'] as Map?)?['code'] as String? ??
                        WorkActivityCatalog.indirectCode)
                    .trim(),
            minutes: _minutenUit(e['timeemployee'] as String?),
            monteurId: employeeId,
          ),
        );
      }
      if (!mounted || !_indirect) return;
      setState(() {
        _submitError = null;
        for (final k in perDag.keys) {
          _cardsByDay[k] = perDag[k]!;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _submitError = 'Indirecte uren ophalen mislukt.\n$e');
      }
    }
  }

  /// Voert een schrijfactie voor indirecte uren uit en laadt daarna de
  /// uren opnieuw, zodat het scherm altijd toont wat er in Ridder staat.
  Future<void> _indirectActie(
    Future<void> Function() actie,
    String foutTekst,
  ) async {
    if (_indirectBusy) return;
    setState(() {
      _indirectBusy = true;
      _submitError = null;
    });
    String? fout;
    try {
      await actie();
    } catch (e) {
      fout = '$foutTekst\n${_ridderFout(e)}';
    }
    await _loadIndirect();
    if (!mounted) return;
    setState(() {
      _indirectBusy = false;
      if (fout != null) _submitError = fout;
    });
  }

  int? get _mijnId => AuthService.instance.currentMechanicId;

  static const _months = [
    '',
    'jan',
    'feb',
    'mrt',
    'apr',
    'mei',
    'jun',
    'jul',
    'aug',
    'sep',
    'okt',
    'nov',
    'dec',
  ];

  @override
  void initState() {
    super.initState();
    _selectedOrder = widget.initialOrder;
    _indirect = widget.initialOrder == null;
    // Eerdere versie bewaarde indirecte uren lokaal (voor alle medewerkers
    // samen); die zijn nu per medewerker in Ridder.
    SharedPreferences.getInstance().then(
      (p) => p.remove(hoursDraftKeyForOrder(_indirectDraftId)),
    );
    // Uursoorten van de actieve administratie (live/test) ophalen.
    WorkActivityCatalog.instance.laad().then((_) {
      if (mounted) setState(() {});
    });
    _days = _buildDayRange();
    _dayChipKeys = List.generate(_days.length, (_) => GlobalKey());
    _cardsByDay = {for (final d in _days) _key(d): <_HourCard>[]};
    final initialPage = _initialPageIndex();
    _currentPage = initialPage;
    _pageController = PageController(initialPage: initialPage);
    if (widget.registreerModus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _registreerStart());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollDayStripToCurrent(),
    );
    _loadDraft();
  }

  /// Registreren-modus: sheet openen, daarna het scherm sluiten.
  Future<void> _registreerStart() async {
    final d = widget.initialDay ?? DateTime.now();
    await _addHourCard(DateTime(d.year, d.month, d.day));
    if (!mounted) return;
    if (!_indirect) await _saveDraft(wachtOpSync: true);
    final fout = _submitError;
    if (fout != null && mounted) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Toevoegen mislukt'),
          content: Text(fout),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    if (mounted) Navigator.of(context).pop(_toegevoegd > 0);
  }

  /// Aantal geslaagde toevoegingen in de Registreren-modus.
  int _toegevoegd = 0;

  static const _laatsteBestemmingKey = 'registreer_laatste_bestemming';

  Future<void> _onthoudBestemming() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _laatsteBestemmingKey,
      _indirect ? _indirectDraftId : (_selectedOrder?.id ?? _indirectDraftId),
    );
  }

  /// Zet het scherm op de in het sheet gekozen bestemming.
  Future<void> _wisselBestemming(bool indirect, ServiceOrder? order) async {
    _draftSaveTimer?.cancel();
    await _saveDraft();
    setState(() {
      _indirect = indirect;
      _selectedOrder = indirect ? null : order;
      _submitError = null;
    });
    await _loadDraft();
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  List<DateTime> _buildDayRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(const Duration(days: 14));
    return List.generate(29, (i) => start.add(Duration(days: i)));
  }

  int _initialPageIndex() {
    final today = widget.initialDay ?? DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    final todayIndex = _days.indexWhere((d) => d == todayOnly);
    return todayIndex >= 0 ? todayIndex : 0;
  }

  void _scrollDayStripToCurrent({bool animate = false}) {
    final ctx = _dayChipKeys[_currentPage].currentContext;
    if (ctx == null) return;
    if (animate) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      Scrollable.ensureVisible(ctx, alignment: 0.5);
    }
  }

  bool _isPlanned(DateTime day) {
    final start = _selectedOrder?.startDate;
    if (start == null) return false;
    final end = _selectedOrder?.endTime ?? start;
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    return !day.isBefore(s) && !day.isAfter(e);
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  int _totalMinutesForDay(String key) =>
      (_cardsByDay[key] ?? const []).fold(0, (s, c) => s + c.minutes);

  double get _totalHours =>
      _days.fold(0, (s, d) => s + _totalMinutesForDay(_key(d))) / 60;

  int get _totalKm => _cardsByDay.values.fold(
    0,
    (s, cards) => s + cards.fold(0, (s, c) => s + (c.km ?? 0)),
  );

  bool get _hasPendingCards =>
      _cardsByDay.values.any((l) => l.any((c) => !c.submitted));

  /// Nog niet verstuurde uren- of km-kaarten van mij — wat "Tussentijds
  /// versturen" zou meesturen.
  bool get _hasPendingHourCards => _cardsByDay.values.any(
    (l) => l.any(
      (c) =>
          !c.submitted &&
          (c.monteurId == null ||
              c.monteurId == AuthService.instance.currentMechanicId),
    ),
  );

  bool _tussentijdsBezig = false;

  /// ISO-weeknummer van [d].
  static int _isoWeek(DateTime d) {
    // In UTC rekenen: met lokale tijd scheelt zomertijd een uur, waardoor
    // `inDays` een dag te weinig telt.
    final dag = DateTime.utc(d.year, d.month, d.day);
    final donderdag = dag.add(Duration(days: 4 - dag.weekday));
    final eersteJan = DateTime.utc(donderdag.year, 1, 1);
    return (donderdag.difference(eersteJan).inDays ~/ 7) + 1;
  }

  String _fmtDate(DateTime d) =>
      '${_fullDayNames[d.weekday]} ${d.day} ${_months[d.month]}';
  String _fmtDouble(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  /// Restores a previously locally-saved (not-yet-submitted) draft for the
  /// currently selected bon, if any — the phone remembers cards created in
  /// a previous session until they're actually submitted. Each bon keeps
  /// its own draft, so switching the selected bon swaps the visible cards.
  Future<void> _loadDraft() async {
    _vreemdeKaarten.clear();
    for (final d in _days) {
      _cardsByDay[_key(d)] = [];
    }
    if (_indirect) {
      if (mounted) setState(() {});
      await _loadIndirect();
      return;
    }
    final key = _currentDraftKey;
    if (key != null) {
      // Eerst de eigen uren uit de gedeelde opslag erbij halen (crash,
      // ander toestel); daarna staat alles in het lokale concept.
      // Indirecte uren hebben geen bon en blijven alleen lokaal.
      if (!_indirect) {
        await HoursSyncService.instance.haalOp(_selectedOrder!.id);
      }
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw != null) {
        final draft = jsonDecode(raw) as Map<String, dynamic>;
        final days = (draft['days'] as Map<String, dynamic>?) ?? {};
        final ik = _mijnId;
        _vreemdeKaarten.clear();
        for (final entry in days.entries) {
          final d = entry.value as Map<String, dynamic>;
          final cardsJson = (d['cards'] as List<dynamic>?) ?? const [];
          final eigen = <Map<String, dynamic>>[];
          for (final c in cardsJson) {
            final json = Map<String, dynamic>.from(c as Map);
            final eigenaar = (json['monteurId'] as num?)?.toInt();
            // Uren van een collega op dezelfde bon zie ik niet, maar ze
            // blijven bewaard (zie _saveDraft).
            if (eigenaar != null && ik != null && eigenaar != ik) {
              _vreemdeKaarten.putIfAbsent(entry.key, () => []).add(json);
            } else {
              eigen.add(json);
            }
          }
          _cardsByDay[entry.key] = eigen.map(_HourCard.fromDraftJson).toList();
        }
      }
    }
    _verbreedDagen();
    if (mounted) setState(() {});
  }

  /// Kaarten van andere monteurs in het lokale concept van deze bon: nooit
  /// getoond, maar bij het opslaan weer meegeschreven zodat ze niet verdwijnen.
  final Map<String, List<Map<String, dynamic>>> _vreemdeKaarten = {};

  bool _dagenVerbreed = false;

  /// Het scherm toont standaard 14 dagen terug en 14 vooruit. Staan er uren
  /// op een dag daarbuiten (bijvoorbeeld oudere of latere uren op de bon),
  /// dan breiden we het bereik uit zodat ze zichtbaar en aanpasbaar zijn —
  /// en bij het opslaan niet stilletjes wegvallen. De eerste keer springen
  /// we naar zo'n dag, zodat je ze meteen ziet.
  void _verbreedDagen() {
    DateTime? vroegste;
    DateTime? laatste;
    for (final e in _cardsByDay.entries) {
      if (e.value.isEmpty) continue;
      final delen = e.key.split('-');
      if (delen.length != 3) continue;
      final d = DateTime(
        int.tryParse(delen[0]) ?? 0,
        int.tryParse(delen[1]) ?? 0,
        int.tryParse(delen[2]) ?? 0,
      );
      if (d.year == 0) continue;
      if (vroegste == null || d.isBefore(vroegste)) vroegste = d;
      if (laatste == null || d.isAfter(laatste)) laatste = d;
    }
    final eerste = _days.first;
    final einde = _days.last;
    final buiten =
        (vroegste != null && vroegste.isBefore(eerste)) ||
        (laatste != null && laatste.isAfter(einde));
    if (!buiten) return;
    final nieuwStart = (vroegste != null && vroegste.isBefore(eerste))
        ? vroegste
        : eerste;
    final nieuwEinde = (laatste != null && laatste.isAfter(einde))
        ? laatste
        : einde;
    final aantal = nieuwEinde.difference(nieuwStart).inDays + 1;
    final huidig = _days[_currentPage];
    _days = List.generate(
      aantal,
      (i) => DateTime(nieuwStart.year, nieuwStart.month, nieuwStart.day + i),
    );
    _dayChipKeys = List.generate(_days.length, (_) => GlobalKey());
    var doel = _days.indexWhere((d) => d == huidig);
    if (!_dagenVerbreed) {
      // Naar de meest recente dag buiten het oude bereik.
      final springNaar = (laatste != null && laatste.isAfter(einde))
          ? laatste
          : vroegste!;
      final i = _days.indexWhere((d) => d == springNaar);
      if (i >= 0) doel = i;
    }
    _dagenVerbreed = true;
    if (doel < 0) doel = 0;
    _currentPage = doel;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) _pageController.jumpToPage(doel);
      _scrollDayStripToCurrent();
    });
  }

  /// Debounced auto-save of the current inputs as a local draft — fires
  /// shortly after the technician stops typing, so it doesn't hit
  /// SharedPreferences on every keystroke.
  void _scheduleDraftSave() {
    // Toevoegen, aanpassen en verwijderen gaan meteen door (lokaal en naar
    // Firestore), zodat ook het dashboard en andere toestellen het direct
    // zien, en er niets verloren gaat als je het scherm snel verlaat.
    _draftSaveTimer?.cancel();
    unawaited(_saveDraft());
  }

  Future<void> _saveDraft({bool wachtOpSync = false}) async {
    final key = _currentDraftKey;
    if (key == null) return;
    final dagSleutels = {for (final d in _days) _key(d), ..._vreemdeKaarten.keys};
    final days = <String, dynamic>{
      for (final k in dagSleutels)
        k: {
          'cards': [
            ...(_cardsByDay[k] ?? const <_HourCard>[]).map((c) => c.toDraftJson()),
            ...(_vreemdeKaarten[k] ?? const <Map<String, dynamic>>[]),
          ],
        },
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode({'days': days}));
    final order = _selectedOrder;
    if (!_indirect && order != null) {
      final sync = HoursSyncService.instance.stuurDoor(order.id);
      if (wachtOpSync) {
        // Kort wachten: offline gaat het via de wachtrij van Firestore.
        await sync.timeout(const Duration(seconds: 6), onTimeout: () {});
      } else {
        unawaited(sync);
      }
    }
  }

  /// Opens the bon picker and, if a different bon is chosen, saves the
  /// current bon's draft, clears the visible cards, and loads the newly
  /// selected bon's own draft.
  Future<void> _pickOrder() async {
    final picked = await Navigator.of(context).push<Object>(
      CupertinoPageRoute<Object>(
        builder: (_) => _BonPickerScreen(
          selectedId: _indirect ? null : _selectedOrder?.id,
          indirectSelected: _indirect,
        ),
      ),
    );
    if (picked == null) return;
    if (picked == _indirectDraftId) {
      if (_indirect) return;
      _draftSaveTimer?.cancel();
      await _saveDraft();
      setState(() {
        _indirect = true;
        _selectedOrder = null;
        _submitError = null;
      });
      await _loadDraft();
      return;
    }
    if (picked is! ServiceOrder) return;
    if (!_indirect && picked.id == _selectedOrder?.id) return;
    _draftSaveTimer?.cancel();
    await _saveDraft();
    setState(() {
      _indirect = false;
      _selectedOrder = picked;
      _submitError = null;
    });
    await _loadDraft();
  }

  /// Adds an hour card for [day] — or, if no bon is selected yet, opens the
  /// bon picker instead. Cards are always scoped to the selected bon's
  /// draft (see [_saveDraft]/[_loadDraft]), so entry is blocked until a bon
  /// exists to attribute them to; this also means [_loadDraft]'s reset when
  /// switching bons never discards cards a technician just entered.
  /// Controles voor een dag: vorige week eerst versturen, en een
  /// waarschuwing bij een dag in de toekomst. `false` = niet doorgaan.
  Future<bool> _controleerDag(DateTime day) async {
    // Deadline is zondag: uren voor deze week pas invullen als die van
    // vorige week verstuurd zijn (zie WeekAfsluitenScreen).
    final dezeWeek = maandagVanWeek(DateTime.now());
    if (!DateTime(day.year, day.month, day.day).isBefore(dezeWeek)) {
      final open = await HoursDraftService.instance.openKaartenAfgelopenWeken(
        synchroniseer: false,
      );
      if (!mounted) return false;
      if (open.isNotEmpty) {
        final naarOverzicht = await showCupertinoDialog<bool>(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: const Text('Eerst vorige week versturen'),
            content: const Text(
              'Je hebt nog uren van vorige week die niet verstuurd zijn. '
              'Verstuur die eerst naar kantoor; daarna kun je uren voor deze '
              'week invullen.',
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Annuleren'),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Naar overzicht'),
              ),
            ],
          ),
        );
        if (naarOverzicht == true && mounted) {
          await _saveDraft();
          if (!mounted) return false;
          await WeekAfsluitenScreen.openScherm(context);
          if (mounted) await _loadDraft();
        }
        return false;
      }
    }
    // Uren in de toekomst kan kantoor vaak niet verwerken ("geen werkdag
    // voor deze werknemer op deze datum"), en ze horen in een latere
    // weekregistratie. Wel toestaan, maar eerst waarschuwen.
    final vandaag = DateTime.now();
    if (DateTime(day.year, day.month, day.day)
        .isAfter(DateTime(vandaag.year, vandaag.month, vandaag.day))) {
      final doorgaan = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Dag in de toekomst'),
          content: Text(
            '${_fmtDate(day)} is nog niet geweest. Weet je zeker dat je hier '
            'uren of kilometers wilt boeken?',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuleren'),
            ),
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Toch boeken'),
            ),
          ],
        ),
      );
      if (doorgaan != true || !mounted) return false;
    }
    return true;
  }

  Future<void> _addHourCard(DateTime day) async {
    final vrij = widget.registreerModus;
    if (!vrij && !await _controleerDag(day)) return;
    if (!vrij && !_indirect && _selectedOrder == null) {
      await _pickOrder();
      if ((!_indirect && _selectedOrder == null) || !mounted) return;
    }
    final draft = await showCupertinoModalPopup<_HourCardDraft>(
      context: context,
      builder: (ctx) => _AddHourCardSheet(
        indirect: _indirect,
        vrij: vrij,
        dag: day,
        order: _selectedOrder,
      ),
    );
    if (draft == null || !mounted) return;
    if (vrij) {
      day = draft.dag ?? day;
      if (!await _controleerDag(day) || !mounted) return;
      await _wisselBestemming(draft.indirect, draft.order);
      if (!mounted) return;
      await _onthoudBestemming();
    }
    // Uren, kilometers en overnachting uit één sheet gaan achter elkaar.
    for (final d in [draft, ...draft.extra]) {
      await _boekDraft(day, d);
      if (!mounted || _submitError != null) return;
    }
  }

  Future<void> _boekDraft(DateTime day, _HourCardDraft draft) async {
    if (_indirect) {
      final id = _mijnId;
      final draftCode = (draft.workActivityCode ?? '').toUpperCase();
      final isOvernachting = draftCode == WorkActivityCatalog.overnachtingCode;
      final isCompensatie = draftCode == WorkActivityCatalog.compensatieCode;
      final soort = isOvernachting
          ? WorkActivityCatalog.instance.overnachting
          : isCompensatie
          ? WorkActivityCatalog.instance.compensatie
          : WorkActivityCatalog.instance.indirect;
      if (id == null) {
        setState(() => _submitError = 'Je bent niet ingelogd.');
        return;
      }
      if (soort == null) {
        setState(
          () => _submitError = isOvernachting
              ? 'Bewerking "Overnachting" '
                    '(${WorkActivityCatalog.overnachtingCode}) niet gevonden '
                    'in Ridder.'
              : isCompensatie
              ? 'Bewerking "Compensatie uren" '
                    '(${WorkActivityCatalog.compensatieCode}) niet gevonden '
                    'in Ridder.'
              : 'Uursoort "Indirecte uren" '
                    '(${WorkActivityCatalog.indirectCode}) niet gevonden in '
                    'Ridder.',
        );
        return;
      }
      if (isOvernachting &&
          (_cardsByDay[_key(day)] ?? const []).any(_isOvernachting)) {
        setState(
          () => _submitError =
              'Er staat al een overnachting op ${_fmtDate(day)}.',
        );
        return;
      }
      await _indirectActie(
        () => PlanningRepository.instance.createIndirectProjectTime(
          date: day,
          employeeId: id,
          workActivityId: soort.id,
          duration: Duration(minutes: draft.minutes),
        ),
        'Boeken mislukt (${_fmtDate(day)}).',
      );
      if (_submitError == null) _toegevoegd++;
      return;
    }
    if ((draft.workActivityCode ?? '').toUpperCase() ==
            WorkActivityCatalog.overnachtingCode &&
        (_cardsByDay[_key(day)] ?? const []).any(_isOvernachting)) {
      setState(
        () => _submitError = 'Er staat al een overnachting op ${_fmtDate(day)}.',
      );
      return;
    }
    final key = _key(day);
    setState(() {
      _cardsByDay
          .putIfAbsent(key, () => [])
          .add(
            _HourCard(
              id: _uuid.v4(),
              monteurId: _mijnId,
              workActivityId: draft.workActivityId,
              workActivityCode: draft.workActivityCode,
              minutes: draft.minutes,
              km: draft.km,
              memo: draft.memo,
            ),
          );
    });
    _toegevoegd++;
    _scheduleDraftSave();
  }

  /// Opent hetzelfde sheet als bij toevoegen, maar met de gegevens van
  /// [card] ingevuld. Alleen voor kaarten die nog niet zijn verstuurd.
  Future<void> _editHourCard(DateTime day, _HourCard card) async {
    // Een overnachting heeft niets om aan te passen; alleen verwijderen.
    if (card.submitted || _isOvernachting(card)) return;
    final draft = await showCupertinoModalPopup<_HourCardDraft>(
      context: context,
      builder: (ctx) => _AddHourCardSheet(initial: card, indirect: _indirect),
    );
    if (draft == null || !mounted) return;
    if (_indirect) {
      final ptId = int.tryParse(card.id.replaceFirst('pt-', ''));
      if (ptId == null) return;
      await _indirectActie(
        () => PlanningRepository.instance.updateProjectTime(
          id: ptId,
          date: day,
          duration: Duration(minutes: draft.minutes),
        ),
        'Aanpassen mislukt (${_fmtDate(day)}).',
      );
      return;
    }
    final key = _key(day);
    setState(() {
      final cards = _cardsByDay[key];
      final i = cards?.indexWhere((c) => c.id == card.id) ?? -1;
      if (cards == null || i < 0) return;
      cards[i] = _HourCard(
        id: card.id,
        monteurId: card.monteurId ?? _mijnId,
        workActivityId: draft.workActivityId,
        workActivityCode: draft.workActivityCode,
        minutes: draft.minutes,
        km: draft.km,
        memo: draft.memo,
      );
    });
    _scheduleDraftSave();
  }

  void _removeHourCard(DateTime day, String cardId) {
    if (_indirect) {
      final ptId = int.tryParse(cardId.replaceFirst('pt-', ''));
      if (ptId == null) return;
      _indirectActie(
        () => PlanningRepository.instance.deleteProjectTime(ptId),
        'Verwijderen mislukt (${_fmtDate(day)}).',
      );
      return;
    }
    setState(() {
      _cardsByDay[_key(day)]?.removeWhere((c) => c.id == cardId);
    });
    _scheduleDraftSave();
  }

  /// Saves the entered hours to this bon's local draft only — it no longer
  /// submits to Ridder directly. Publishing now happens in one go from the
  /// "Werk afronden" screen (see `HoursDraftService.submitPendingHours`),
  /// which reads this same draft and is the only place that still calls
  /// [ServiceRemoteJobOrderRepository.submitHoursForJobOrder]. Cards stay
  /// unlocked (not marked [_HourCard.submitted]) since nothing's actually
  /// been sent yet.
  Future<void> _submit() async {
    final order = _selectedOrder;
    if (order == null) {
      setState(() => _submitError = 'Selecteer eerst een bon.');
      return;
    }
    if (AuthService.instance.currentMechanicId == null) {
      setState(() => _submitError = 'Je bent niet ingelogd.');
      return;
    }
    if (!_hasPendingCards) return;

    setState(() {
      _submitting = true;
      _submitError = null;
    });
    _draftSaveTimer?.cancel();
    await _saveDraft(wachtOpSync: true);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// Stuurt de nog niet verstuurde uren van deze bon als *onderbroken*
  /// registratie naar Ridder (zie `HoursDraftService.submitPendingHours`
  /// met `tussentijds`), zodat kantoor ze al kan verwerken terwijl de bon
  /// openblijft. Kilometers, materiaal en handtekening volgen bij het
  /// afronden.
  Future<void> _tussentijdsVersturen() async {
    final order = _selectedOrder;
    if (order == null || _indirect) return;
    final akkoord = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Uren tussentijds versturen?'),
        content: const Text(
          'Je nog niet verstuurde uren en kilometers gaan nu naar kantoor, '
          'per week een registratie. De bon blijft open: materiaal en de '
          'handtekening van de klant stuur je mee bij "Werk afronden". '
          'Verstuurde uren kun je daarna niet meer aanpassen.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuleren'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Versturen'),
          ),
        ],
      ),
    );
    if (akkoord != true || !mounted) return;

    setState(() {
      _tussentijdsBezig = true;
      _submitError = null;
    });
    _draftSaveTimer?.cancel();
    try {
      await _saveDraft(wachtOpSync: true);
      final resultaat = await HoursDraftService.instance.verstuurWeken(
        order.id,
      );
      if (!mounted) return;
      await _loadDraft();
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text(
            resultaat.isLeeg ? 'Niets te versturen' : 'Uren verstuurd',
          ),
          content: Text(
            resultaat.isLeeg
                ? 'Er staan geen nieuwe uren of kilometers klaar voor deze bon.'
                : 'Verstuurd: ${resultaat.weken.map((w) => 'week ${_isoWeek(w)}').join(', ')}. '
                      'Kantoor kan de uren nu verwerken; de bon blijft open '
                      'voor de rest van het werk.',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _submitError = describeHoursSubmitError(e));
    } finally {
      if (mounted) setState(() => _tussentijdsBezig = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.registreerModus) return const SizedBox.shrink();
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final canSubmit =
        !_submitting && _hasPendingCards && _selectedOrder != null;

    return CupertinoPageScaffold(
      backgroundColor: isDark ? CupertinoColors.black : const Color(0xFFF2F2F7),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
        leading: CupertinoNavigationBarBackButton(
          color: AppColors.navForeground,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: Text(
          'Uren & KM',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.navForeground.resolveFrom(context),
          ),
        ),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _ProjectSelectorBar(
                order: _selectedOrder,
                indirect: _indirect,
                onTap: _pickOrder,
              ),
              _DayTabStrip(
                days: _days,
                chipKeys: _dayChipKeys,
                currentIndex: _currentPage,
                isPlanned: _isPlanned,
                isToday: _isToday,
                onSelect: (i) => _pageController.animateToPage(
                  i,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    PageView.builder(
                      controller: _pageController,
                      itemCount: _days.length,
                      onPageChanged: (i) {
                        setState(() => _currentPage = i);
                        _scrollDayStripToCurrent(animate: true);
                      },
                      itemBuilder: (context, i) {
                        final d = _days[i];
                        final key = _key(d);
                        return SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: _DayPage(
                            label: _fmtDate(d),
                            isToday: _isToday(d),
                            isPlanned: _isPlanned(d),
                            hasOrder: _indirect || _selectedOrder != null,
                            cards: _cardsByDay[key] ?? const [],
                            borderColor: borderColor,
                            isDark: isDark,
                            onDeleteCard: (cardId) =>
                                _removeHourCard(d, cardId),
                            onEditCard: (card) => _editHourCard(d, card),
                            onAddPressed: () => _addHourCard(d),
                          ),
                        );
                      },
                    ),
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: _AddHourFab(
                        onPressed: () => _addHourCard(_days[_currentPage]),
                      ),
                    ),
                  ],
                ),
              ),
              _SubmitFooter(
                borderColor: borderColor,
                isDark: isDark,
                totalsLabel: _totalKm > 0
                    ? '${_fmtDouble(_totalHours)}u · $_totalKm km'
                    : '${_fmtDouble(_totalHours)}u',
                error: _submitError,
                submitting: _submitting,
                canSubmit: canSubmit,
                submitLabel: _indirect ? null : 'Uren & km opslaan',
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Add hour FAB ──────────────────────────────────────────────────────────

class _AddHourFab extends StatelessWidget {
  final VoidCallback onPressed;

  const _AddHourFab({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: _accentOrange,
          shape: BoxShape.circle,
          // boxShadow: [
          //   BoxShadow(
          //     color: _accentOrange.withValues(alpha: 0.35),
          //     blurRadius: 14,
          //     offset: const Offset(0, 6),
          //   ),
          // ],
        ),
        child: const Icon(
          CupertinoIcons.add,
          color: CupertinoColors.white,
          size: 28,
        ),
      ),
    );
  }
}

// ─── Day tab strip ─────────────────────────────────────────────────────────

class _DayTabStrip extends StatelessWidget {
  final List<DateTime> days;
  final List<GlobalKey> chipKeys;
  final int currentIndex;
  final bool Function(DateTime) isPlanned;
  final bool Function(DateTime) isToday;
  final ValueChanged<int> onSelect;

  const _DayTabStrip({
    required this.days,
    required this.chipKeys,
    required this.currentIndex,
    required this.isPlanned,
    required this.isToday,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            for (int i = 0; i < days.length; i++)
              GestureDetector(
                key: chipKeys[i],
                onTap: () => onSelect(i),
                behavior: HitTestBehavior.opaque,
                child: _DayTabChip(
                  weekday: _fullDayNames[days[i].weekday],
                  dayNumber: days[i].day,
                  active: i == currentIndex,
                  planned: isPlanned(days[i]),
                  today: isToday(days[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DayTabChip extends StatelessWidget {
  final String weekday;
  final int dayNumber;
  final bool active;
  final bool planned;
  final bool today;

  const _DayTabChip({
    required this.weekday,
    required this.dayNumber,
    required this.active,
    required this.planned,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final bg = active
        ? _accentOrange
        : planned
        ? const Color(0xFF34C759).withValues(alpha: 0.14)
        : const Color(0x00000000);
    final fg = active
        ? CupertinoColors.white
        : planned
        ? const Color(0xFF34C759)
        : CupertinoColors.label.resolveFrom(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            weekday,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: fg,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$dayNumber',
            style: TextStyle(
              fontSize: 14,
              fontWeight: today ? FontWeight.w800 : FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Project selector bar ───────────────────────────────────────────────────

/// Tappable row shown at the top of the screen for choosing which bon the
/// entered hours will be booked onto. Shows a placeholder prompt when no
/// bon is selected yet (e.g. when opened from the dashboard).
class _ProjectSelectorBar extends StatelessWidget {
  final ServiceOrder? order;

  /// Boeken zonder bon (standaard).
  final bool indirect;
  final VoidCallback onTap;

  const _ProjectSelectorBar({
    required this.order,
    required this.indirect,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final order = indirect ? null : this.order;
    final title = indirect
        ? 'Indirecte uren'
        : order != null
        ? (order.description.isNotEmpty ? order.description : order.orderNumber)
        : 'Selecteer een bon';
    final subtitle = indirect
        ? 'Niet op een bon · tik om een bon te kiezen'
        : order != null && order.orderNumber.isNotEmpty
        ? order.orderNumber
        : null;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.resolveFrom(context),
          border: Border(bottom: BorderSide(color: borderColor)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.doc_text,
              size: 18,
              color: order != null || indirect
                  ? _accentOrange
                  : CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: order != null || indirect
                          ? CupertinoColors.label.resolveFrom(context)
                          : _accentOrange,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              CupertinoIcons.chevron_down,
              size: 14,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ],
        ),
      ),
    );
  }
}


// ─── Bon picker screen ───────────────────────────────────────────────────────

/// Full-screen picker listing the current technician's bonnen (filtered the
/// same way [ProjectenScreen] does — by the logged-in mechanic's id), with
/// search, for choosing which one to book hours onto.
class _BonPickerScreen extends StatefulWidget {
  final String? selectedId;

  const _BonPickerScreen({this.selectedId, this.indirectSelected = false});

  /// Of "Indirecte uren" nu de actieve keuze is.
  final bool indirectSelected;

  @override
  State<_BonPickerScreen> createState() => _BonPickerScreenState();
}

class _BonPickerScreenState extends State<_BonPickerScreen> {
  List<ServiceOrder> _orders = [];
  String _query = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final myId = AuthService.instance.currentMechanicId;
      if (myId == null) {
        setState(() {
          _error = 'Je bent niet ingelogd.';
          _loading = false;
        });
        return;
      }
      final orders = await PlanningRepository.instance.fetchServiceOrders();
      final myOrders = orders.where((o) => o.isAssignedTo(myId)).toList()
        ..sort((a, b) {
          final ad = a.planningDate;
          final bd = b.planningDate;
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return bd.compareTo(ad);
        });
      if (mounted) {
        setState(() {
          _orders = myOrders;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  List<ServiceOrder> get _filtered {
    if (_query.isEmpty) return _orders;
    final q = _query.toLowerCase();
    return _orders
        .where(
          (o) =>
              o.description.toLowerCase().contains(q) ||
              o.orderNumber.toLowerCase().contains(q) ||
              o.relationName.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.page,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        middle: Text(
          'Kies een bon',
          style: TextStyle(color: AppColors.navForeground.resolveFrom(context)),
        ),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: CupertinoSearchTextField(
                placeholder: 'Zoeken',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(_indirectDraftId),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.clock_fill,
                      size: 18,
                      color: _accentOrange,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Indirecte uren (geen bon)',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.indirectSelected)
                      const Icon(
                        CupertinoIcons.checkmark_alt,
                        size: 18,
                        color: _accentOrange,
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : _error != null
                  ? _BonPickerErrorView(error: _error!, onRetry: _load)
                  : _filtered.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty
                            ? 'Geen bonnen gevonden'
                            : 'Geen resultaten',
                        style: TextStyle(
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: _filtered.length,
                      itemBuilder: (context, i) {
                        final o = _filtered[i];
                        return GestureDetector(
                          onTap: () => Navigator.of(context).pop(o),
                          behavior: HitTestBehavior.opaque,
                          child: _BonPickerRow(
                            order: o,
                            selected: o.id == widget.selectedId,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BonPickerRow extends StatelessWidget {
  final ServiceOrder order;
  final bool selected;

  const _BonPickerRow({required this.order, required this.selected});

  static const _months = [
    '',
    'jan',
    'feb',
    'mrt',
    'apr',
    'mei',
    'jun',
    'jul',
    'aug',
    'sep',
    'okt',
    'nov',
    'dec',
  ];

  String _formatDate(DateTime? d) {
    if (d == null) return '—';
    return '${d.day} ${_months[d.month]}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final title = order.description.isNotEmpty
        ? order.description
        : order.orderNumber;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? _accentOrange : borderColor,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    order.orderNumber,
                    order.relationName,
                    _formatDate(order.planningDate),
                  ].where((s) => s.isNotEmpty).join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
          if (selected) ...[
            const SizedBox(width: 8),
            const Icon(
              CupertinoIcons.checkmark_circle_fill,
              size: 20,
              color: _accentOrange,
            ),
          ],
        ],
      ),
    );
  }
}

class _BonPickerErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _BonPickerErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 40,
              color: CupertinoColors.destructiveRed.resolveFrom(context),
            ),
            const SizedBox(height: 12),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: onRetry,
              child: const Text('Opnieuw proberen'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Day page ──────────────────────────────────────────────────────────────

class _DayPage extends StatelessWidget {
  final String label;
  final bool isToday;
  final bool isPlanned;
  final bool hasOrder;
  final List<_HourCard> cards;
  final Color borderColor;
  final bool isDark;
  final ValueChanged<String> onDeleteCard;
  final ValueChanged<_HourCard> onEditCard;
  final VoidCallback onAddPressed;

  const _DayPage({
    required this.label,
    required this.isToday,
    required this.isPlanned,
    required this.hasOrder,
    required this.cards,
    required this.borderColor,
    required this.isDark,
    required this.onDeleteCard,
    required this.onEditCard,
    required this.onAddPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (isPlanned) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF34C759).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Gepland',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF34C759),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        if (cards.isEmpty)
          _EmptyCardsHint(
            onAddPressed: onAddPressed,
            isDark: isDark,
            hasOrder: hasOrder,
          )
        else
          for (final card in cards)
            _HourCardTile(
              key: ValueKey(card.id),
              type: card.isKm ? _kmType : _hourTypeVoorKaart(card),
              value: card.isKm
                  ? '${card.km} km'
                  : _isOvernachting(card)
                  ? '1 nacht'
                  : _formatMinutes(card.minutes),
              memo: card.memo,
              borderColor: borderColor,
              isDark: isDark,
              submitted: card.submitted,
              onDelete: () => onDeleteCard(card.id),
              onTap: card.submitted ? null : () => onEditCard(card),
            ),
      ],
    );
  }
}

// ─── Hour card tile ─────────────────────────────────────────────────────────

class _HourCardTile extends StatelessWidget {
  final _HourType type;
  final String value;
  final String? memo;
  final Color borderColor;
  final bool isDark;
  final bool submitted;
  final VoidCallback onDelete;

  /// Tik om aan te passen; `null` voor verstuurde (vergrendelde) kaarten.
  final VoidCallback? onTap;

  const _HourCardTile({
    super.key,
    required this.type,
    required this.value,
    required this.memo,
    required this.borderColor,
    required this.isDark,
    required this.submitted,
    required this.onDelete,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final mutedFg = CupertinoColors.tertiaryLabel.resolveFrom(context);
    final cardBg = submitted
        ? (isDark ? const Color(0xFF232324) : const Color(0xFFF2F2F7))
        : (isDark ? const Color(0xFF1C1C1E) : CupertinoColors.systemBackground);
    final iconBg = submitted
        ? mutedFg.withValues(alpha: 0.15)
        : type.color.withValues(alpha: 0.14);
    final iconFg = submitted ? mutedFg : type.color;
    final titleFg = submitted
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : CupertinoColors.label.resolveFrom(context);
    final durationFg = submitted ? mutedFg : type.color;

    final kaart = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              submitted ? CupertinoIcons.checkmark_alt : type.icon,
              size: 16,
              color: iconFg,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      type.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: titleFg,
                      ),
                    ),
                    if (submitted) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: mutedFg.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Verzonden',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (memo != null && memo!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    memo!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: submitted
                          ? mutedFg
                          : CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: durationFg,
            ),
          ),
        ],
      ),
    );

    final content = onTap == null
        ? kaart
        : GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: kaart,
          );

    // Submitted cards are locked: no swipe-to-delete, they're a record of
    // what was actually sent.
    if (submitted) return content;

    return Dismissible(
      key: key!,
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        margin: const EdgeInsets.only(bottom: 10),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: CupertinoColors.destructiveRed.resolveFrom(context),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(
          CupertinoIcons.delete_solid,
          color: CupertinoColors.white,
          size: 18,
        ),
      ),
      child: content,
    );
  }
}

class _EmptyCardsHint extends StatelessWidget {
  final VoidCallback onAddPressed;
  final bool isDark;
  final bool hasOrder;

  const _EmptyCardsHint({
    required this.onAddPressed,
    required this.isDark,
    required this.hasOrder,
  });

  @override
  Widget build(BuildContext context) {
    const tint = _accentOrange;
    return GestureDetector(
      onTap: onAddPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: isDark ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(16),
          // border: Border.all(color: tint.withValues(alpha: 0.3), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: Icon(
                hasOrder ? CupertinoIcons.add : CupertinoIcons.doc_text,
                size: 22,
                color: tint,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              hasOrder
                  ? 'Nog geen uren of Kilometers toegevoegd'
                  : 'Geen bon geselecteerd',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              hasOrder
                  ? 'Tik om uren of kilometers toe te voegen'
                  : 'Tik om een bon te kiezen',
              style: const TextStyle(fontSize: 12, color: tint),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Add hour card sheet ────────────────────────────────────────────────────

class _HourCardDraft {
  const _HourCardDraft({
    required this.workActivityId,
    this.workActivityCode,
    required this.minutes,
    this.km,
    this.memo,
    this.dag,
    this.indirect = false,
    this.order,
    this.extra = const [],
  });
  final int workActivityId;
  final String? workActivityCode;
  final int minutes;
  final int? km;
  final String? memo;

  /// Alleen in de Registreren-modus: gekozen dag en bestemming.
  final DateTime? dag;
  final bool indirect;
  final ServiceOrder? order;

  /// Verdere kaarten uit hetzelfde sheet (bijv. kilometers en overnachting
  /// naast uren).
  final List<_HourCardDraft> extra;

  _HourCardDraft metExtra(List<_HourCardDraft> extra) => _HourCardDraft(
    workActivityId: workActivityId,
    workActivityCode: workActivityCode,
    minutes: minutes,
    km: km,
    memo: memo,
    dag: dag,
    indirect: indirect,
    order: order,
    extra: extra,
  );

  _HourCardDraft metBestemming({
    required DateTime dag,
    required bool indirect,
    ServiceOrder? order,
  }) => _HourCardDraft(
    workActivityId: workActivityId,
    workActivityCode: workActivityCode,
    minutes: minutes,
    km: km,
    memo: memo,
    dag: dag,
    indirect: indirect,
    order: order,
    extra: extra,
  );
}

enum _EntryKind { hours, km, overnachting }

class _AddHourCardSheet extends StatefulWidget {
  const _AddHourCardSheet({
    this.initial,
    this.indirect = false,
    this.vrij = false,
    this.dag,
    this.order,
  });

  /// Registreren-modus: bestemming (bon of indirect) en dag zijn hier te
  /// kiezen. Anders staan die vast op het scherm waarvandaan je opende.
  final bool vrij;
  final DateTime? dag;
  final ServiceOrder? order;

  /// Indirecte uren: vaste uursoort en geen kilometers (die horen bij een
  /// bon); in plaats daarvan een tabblad "Overnachting".
  final bool indirect;

  /// Bestaande kaart om aan te passen; `null` bij toevoegen.
  final _HourCard? initial;

  @override
  State<_AddHourCardSheet> createState() => _AddHourCardSheetState();
}

class _AddHourCardSheetState extends State<_AddHourCardSheet> {
  // Eén veld per tab, zodat wat je invult blijft staan als je wisselt.
  /// Hoogste toetsenbordhoogte die we zagen zolang een invoerveld focus
  /// heeft. Het cijfertoetsenbord is lager dan het gewone: zonder dit
  /// springt het sheet mee op en neer bij het wisselen tussen de velden.
  double _maxToetsenbord = 0;

  void _focusGewijzigd() {
    if (mounted) setState(() {});
  }

  bool get _veldHeeftFocus {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null &&
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  // Eén invoerveld voor beide tabs; bij wisselen wisselt alleen de tekst
  // erin. Zo blijft het veld (en dus het toetsenbord) ongemoeid.
  final _invoer = TextEditingController();
  String _urenOpgeslagen = '';
  String _kmOpgeslagen = '';
  late final _cijfersFilter = TextInputFormatter.withFunction((oud, nieuw) {
    final toegestaan = _isKm ? RegExp(r'^\d*$') : RegExp(r'^[\d.,]*$');
    return toegestaan.hasMatch(nieuw.text) ? nieuw : oud;
  });
  String get _urenTekst => _isKm ? _urenOpgeslagen : _invoer.text;
  String get _kmTekst => _isKm ? _invoer.text : _kmOpgeslagen;
  final _memoCtrl = TextEditingController();
  /// `null` als er (nog) geen uursoorten bekend zijn voor deze administratie.
  _HourType? _selectedType;
  _EntryKind _kind = _EntryKind.hours;

  bool get _isEdit => widget.initial != null;

  // Bestemming en dag (alleen in de Registreren-modus te wijzigen).
  late bool _indirectSel = widget.vrij ? true : widget.indirect;
  ServiceOrder? _orderSel;
  late DateTime _dag = widget.dag ?? DateTime.now();
  bool _bestemmingLaadt = false;

  bool get _isIndirect => widget.vrij ? _indirectSel : widget.indirect;

  static const _meest = 'registreer_laatste_bestemming';

  /// Beginkeuze: de laatst gebruikte bon, anders de dichtstbijzijnde bon
  /// rond de gekozen dag, anders indirect.
  Future<void> _laadBestemming() async {
    setState(() => _bestemmingLaadt = true);
    ServiceOrder? gekozen;
    try {
      final bonnen = await UrenOverzichtService.instance.bonnen();
      final prefs = await SharedPreferences.getInstance();
      final laatste = prefs.getString(_meest);
      if (laatste == _indirectDraftId) {
        gekozen = null;
      } else {
        for (final o in bonnen) {
          if (o.id == laatste) gekozen = o;
        }
        if (gekozen == null && bonnen.isNotEmpty) {
          int afstand(ServiceOrder o) {
            final s = o.startDate;
            if (s == null) return 1 << 30;
            return DateTime(s.year, s.month, s.day)
                .difference(DateTime(_dag.year, _dag.month, _dag.day))
                .inDays
                .abs();
          }

          final lijst = [...bonnen]
            ..sort((a, b) => afstand(a).compareTo(afstand(b)));
          if (afstand(lijst.first) <= 1) gekozen = lijst.first;
        }
      }
    } catch (_) {
      gekozen = null;
    }
    if (!mounted) return;
    _zetBestemming(indirect: gekozen == null, order: gekozen);
    setState(() => _bestemmingLaadt = false);
  }

  void _zetBestemming({required bool indirect, ServiceOrder? order}) {
    setState(() {
      _indirectSel = indirect;
      _orderSel = indirect ? null : order;
      final types = _types;
      _selectedType = types.isEmpty ? null : types.first;
      // Kilometers horen bij een bon.
      if (indirect && _kind == _EntryKind.km) {
        _kmOpgeslagen = _invoer.text;
        _kind = _EntryKind.hours;
        _invoer.text = _urenOpgeslagen;
      }
    });
  }

  Future<void> _kiesBestemming() async {
    final gekozen = await Navigator.of(context).push<Object>(
      CupertinoPageRoute<Object>(
        builder: (_) => _BonPickerScreen(
          selectedId: _indirectSel ? null : _orderSel?.id,
          indirectSelected: _indirectSel,
        ),
      ),
    );
    if (gekozen == null || !mounted) return;
    if (gekozen == _indirectDraftId) {
      _zetBestemming(indirect: true);
    } else if (gekozen is ServiceOrder) {
      _zetBestemming(indirect: false, order: gekozen);
    }
  }

  Future<void> _kiesDag() async {
    var tijdelijk = _dag;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 300,
        color: CupertinoColors.systemBackground.resolveFrom(ctx),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Klaar'),
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _dag,
                maximumDate: DateTime.now().add(const Duration(days: 365)),
                onDateTimeChanged: (d) =>
                    tijdelijk = DateTime(d.year, d.month, d.day),
              ),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() => _dag = tijdelijk);
  }

  /// Kiesbare typen onder "Uren": bij een bon de uursoorten, indirect
  /// "Indirecte uren" en (als die bestaat) "Compensatie-uren".
  List<_HourType> get _types => _isIndirect ? _indirecteTypes : _hourTypes;

  /// Indirect kan het type alleen bij toevoegen gekozen worden: een al
  /// geboekte projecttijd passen we alleen in duur aan.
  bool get _kanTypeKiezen =>
      _types.length > 1 && !(_isIndirect && _isEdit);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusGewijzigd);
    final types = _types;
    _selectedType = types.isEmpty ? null : types.first;
    if (widget.vrij && !_isEdit) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _laadBestemming());
    }
    final kaart = widget.initial;
    if (kaart != null) {
      if (kaart.isKm) {
        _kind = _EntryKind.km;
        _invoer.text = '${kaart.km}';
      } else {
        _kind = _EntryKind.hours;
        _invoer.text = _urenAlsTekst(kaart.minutes);
        final code = WorkActivityCatalog.codeVoorKaart(
          code: kaart.workActivityCode,
          id: kaart.workActivityId,
        );
        for (final t in types) {
          if (t.code == code) _selectedType = t;
        }
      }
      _memoCtrl.text = kaart.memo ?? '';
    }
  }

  /// Minuten als invoertekst in uren, met komma: 480 → "8", 150 → "2,5".
  static String _urenAlsTekst(int minuten) {
    if (minuten % 60 == 0) return '${minuten ~/ 60}';
    var tekst = (minuten / 60).toStringAsFixed(2);
    tekst = tekst.replaceFirst(RegExp(r'0+$'), '');
    return tekst.replaceAll('.', ',');
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusGewijzigd);
    _invoer.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  bool get _isKm => _kind == _EntryKind.km;
  bool _overnacht = false;
  double get _uren => _parseDecimal(_urenTekst);
  int get _kmWaarde => int.tryParse(_kmTekst) ?? 0;
  bool get _urenOk => _uren > 0 && _selectedType != null;
  bool get _kmOk => !_isIndirect && _kmWaarde > 0;
  bool get _overnachtOk =>
      _overnacht && WorkActivityCatalog.instance.overnachting != null;
  bool get _heeftBestemming =>
      !widget.vrij || (!_bestemmingLaadt && (_indirectSel || _orderSel != null));
  bool get _isValid => _heeftBestemming && _isValid0;
  bool get _isValid0 => _isEdit
      ? (_isKm ? _kmWaarde > 0 : _urenOk)
      : (_urenOk || _kmOk || _overnachtOk);

  /// Wisselen van tab laat de ingevulde waarden staan: uren en kilometers
  /// hebben elk hun eigen invoerveld.
  void _selectKind(_EntryKind? kind) {
    if (kind == null || kind == _kind) return;
    setState(() {
      // Bewaar wat er stond en zet de tekst van de andere tab in het veld.
      if (_isKm) {
        _kmOpgeslagen = _invoer.text;
      } else {
        _urenOpgeslagen = _invoer.text;
      }
      _kind = kind;
      final tekst = _isKm ? _kmOpgeslagen : _urenOpgeslagen;
      _invoer.value = TextEditingValue(
        text: tekst,
        selection: TextSelection.collapsed(offset: tekst.length),
      );
    });
  }

  Future<void> _pickType() async {
    final selected = await showCupertinoModalPopup<_HourType>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Type uren'),
        actions: [
          for (final type in _types)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(ctx).pop(type),
              isDefaultAction: type.code == _selectedType?.code,
              child: Text(type.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
    if (selected != null) setState(() => _selectedType = selected);
  }

  void _afronden(List<_HourCardDraft> lijst) {
    final eerste = lijst.first.metExtra(lijst.skip(1).toList());
    Navigator.of(context).pop(
      widget.vrij
          ? eerste.metBestemming(
              dag: _dag,
              indirect: _indirectSel,
              order: _orderSel,
            )
          : eerste,
    );
  }

  void _add() {
    if (!_isValid) return;
    final memo = _memoCtrl.text.trim();
    if (_isEdit) {
      if (_isKm) {
        // Een eventuele memo van een bestaande km-kaart blijft behouden.
        _afronden([
          _HourCardDraft(
            workActivityId: 0,
            minutes: 0,
            km: _kmWaarde,
            memo: widget.initial?.memo,
          ),
        ]);
      } else {
        _afronden([_urenDraft(memo)]);
      }
      return;
    }
    _afronden([
      if (_urenOk) _urenDraft(memo),
      if (_kmOk) _HourCardDraft(workActivityId: 0, minutes: 0, km: _kmWaarde),
      if (_overnachtOk)
        _HourCardDraft(
          workActivityId: WorkActivityCatalog.instance.overnachting?.id ?? 0,
          workActivityCode: WorkActivityCatalog.overnachtingCode,
          minutes: _overnachtingMinuten,
        ),
    ]);
  }

  _HourCardDraft _urenDraft(String memo) => _HourCardDraft(
    workActivityId:
        WorkActivityCatalog.instance.perCode(_selectedType!.code)?.id ?? 0,
    workActivityCode: _selectedType!.code,
    minutes: (_uren * 60).round(),
    memo: memo.isEmpty ? null : memo,
  );

  static String _fmtDag(DateTime d) {
    const dagen = ['', 'ma', 'di', 'wo', 'do', 'vr', 'za', 'zo'];
    const m = ['', 'jan', 'feb', 'mrt', 'apr', 'mei', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];
    return '${dagen[d.weekday]} ${d.day} ${m[d.month]}';
  }

  /// Ruimte onderin voor het toetsenbord. Zolang een veld focus heeft blijft
  /// die op de hoogste waarde staan; verdwijnt het toetsenbord, dan volgt
  /// het sheet het weer naar beneden.
  double _toetsenbordRuimte(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    if (!_veldHeeftFocus) {
      if (inset == 0) _maxToetsenbord = 0;
      return inset;
    }
    if (inset > _maxToetsenbord) _maxToetsenbord = inset;
    return inset == 0 ? 0 : _maxToetsenbord;
  }

  Widget _bedragVeld(BuildContext context) {
    return CupertinoTextField(
      controller: _invoer,
      autofocus: true,
      textAlign: TextAlign.center,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [_cijfersFilter],
      placeholder: _isKm ? '— km' : '— u',
      placeholderStyle: TextStyle(
        fontSize: 14,
        color: CupertinoColors.tertiaryLabel.resolveFrom(context),
      ),
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: CupertinoColors.label.resolveFrom(context),
      ),
      decoration: const BoxDecoration(),
      onChanged: (_) => setState(() {}),
    );
  }

  /// Grijs blok met de invoervelden (zelfde stijl als in het ontwerp).
  Widget _veldenBlok(
    BuildContext context,
    Color inputBg,
    Color borderColor,
    bool isDark,
  ) {
    final vlak = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7);
    final lijn = isDark ? const Color(0xFF38383A) : const Color(0xFFE0E0E5);
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);

    Widget rij(Widget kind, {bool laatste = false, VoidCallback? onTap}) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: laatste
                ? null
                : Border(bottom: BorderSide(color: lijn, width: 0.5)),
          ),
          child: kind,
        ),
      );
    }

    Widget label(String t) => Text(t, style: TextStyle(fontSize: 16, color: sub));

    final toonDag = widget.vrij && !_isEdit;
    final toonType = !_isKm;
    final toonMemo = !_isKm && !_isIndirect;
    final toonNacht = !_isEdit && !_isKm;

    final rijen = <Widget Function(bool laatste)>[
      if (toonDag)
        (l) => rij(
          Row(
            children: [
              Expanded(child: label('Dag')),
              Text(
                _fmtDag(_dag),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(width: 6),
              Icon(CupertinoIcons.chevron_right, size: 14, color: sub),
            ],
          ),
          laatste: l,
          onTap: _kiesDag,
        ),
      (l) => rij(
        Row(
          children: [
            Expanded(
              child: label(_isKm ? 'Aantal kilometers' : 'Aantal uren'),
            ),
            SizedBox(
              width: 88,
              height: 36,
              child: Container(
                decoration: BoxDecoration(
                  color: inputBg,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: borderColor, width: 0.5),
                ),
                child: _bedragVeld(context),
              ),
            ),
          ],
        ),
        laatste: l,
      ),
      if (toonType)
        (l) => rij(
          Row(
            children: [
              Expanded(child: label('Type')),
              Text(
                _selectedType?.label ?? 'Geen uursoorten beschikbaar',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _accentOrange,
                ),
              ),
              if (_kanTypeKiezen) ...[
                const SizedBox(width: 6),
                const Icon(
                  CupertinoIcons.chevron_down,
                  size: 14,
                  color: _accentOrange,
                ),
              ],
            ],
          ),
          laatste: l,
          onTap: _kanTypeKiezen ? _pickType : null,
        ),
      if (toonMemo)
        (l) => rij(
          CupertinoTextField(
            controller: _memoCtrl,
            placeholder: 'Omschrijving (optioneel)',
            minLines: 1,
            maxLines: 3,
            padding: const EdgeInsets.symmetric(vertical: 14),
            placeholderStyle: TextStyle(
              fontSize: 16,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
            style: TextStyle(
              fontSize: 16,
              color: CupertinoColors.label.resolveFrom(context),
            ),
            decoration: const BoxDecoration(),
          ),
          laatste: l,
        ),
      if (toonNacht)
        (l) => rij(
          Row(
            children: [
              Expanded(
                child: label(
                  WorkActivityCatalog.instance.overnachting == null
                      ? 'Overnachting (niet beschikbaar)'
                      : 'Overnachting',
                ),
              ),
              CupertinoSwitch(
                value: _overnacht,
                activeTrackColor: _accentOrange,
                onChanged: WorkActivityCatalog.instance.overnachting == null
                    ? null
                    : (v) => setState(() => _overnacht = v),
              ),
            ],
          ),
          laatste: l,
        ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: vlak,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rijen.length; i++) rijen[i](i == rijen.length - 1),
        ],
      ),
    );
  }

  String get _knopSuffix {
    if (_isEdit || !_isValid) return '';
    final delen = [
      if (_urenOk) '${_urenTekst.trim()} uur',
      if (_kmOk) '${_kmTekst.trim()} km',
      if (_overnachtOk) 'overnachting',
    ];
    return delen.isEmpty ? '' : ' · ${delen.join(' · ')}';
  }

  /// "Boeken op"-rij bovenaan het sheet (Registreren-modus).
  Widget _bestemmingRij(BuildContext context) {
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);
    final vergrendeld = !widget.vrij;
    final indirect = _isIndirect;
    final order = vergrendeld ? widget.order : _orderSel;
    final String waarde;
    if (_bestemmingLaadt) {
      waarde = 'Laden...';
    } else if (indirect || order == null) {
      waarde = 'Indirect';
    } else {
      final o = order;
      waarde = o.relationName.trim().isEmpty
          ? 'Bon ${o.orderNumber}'
          : 'Bon ${o.orderNumber} · ${o.relationName}';
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _bestemmingLaadt || vergrendeld ? null : _kiesBestemming,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _accentOrange,
                borderRadius: BorderRadius.circular(12),
                gradient: (indirect || order == null)
                    ? const LinearGradient(
                        begin: Alignment(-1, -1),
                        end: Alignment(1, 1),
                        stops: [0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1],
                        colors: [
                          _accentOrange,
                          _accentOrange,
                          Color(0xFFFFD2BD),
                          Color(0xFFFFD2BD),
                          _accentOrange,
                          _accentOrange,
                          Color(0xFFFFD2BD),
                          Color(0xFFFFD2BD),
                        ],
                      )
                    : null,
              ),
              child: (indirect || order == null)
                  ? null
                  : const Icon(
                      CupertinoIcons.doc_text,
                      size: 22,
                      color: CupertinoColors.white,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Boeken op', style: TextStyle(fontSize: 13, color: sub)),
                  Text(
                    waarde,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              vergrendeld ? CupertinoIcons.lock_fill : CupertinoIcons.chevron_down,
              size: 16,
              color: sub,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final sheetBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final inputBg = isDark ? const Color(0xFF2C2C2E) : CupertinoColors.white;

    // De witte achtergrond loopt door onder het toetsenbord, anders schemert
    // het grijs van de achtergrond door in de afgeronde hoeken ervan.
    return Container(
        decoration: BoxDecoration(
          color: sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + _toetsenbordRuimte(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 5,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: borderColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            if (!_isEdit) ...[
              if (widget.vrij) ...[
                const Text(
                  'Registreren',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
              ],
              _bestemmingRij(context),
              const SizedBox(height: 14),
            ],
            if (!_isEdit && !_isIndirect)
              _KindPil(
                waarde: _kind,
                onKies: _selectKind,
                opties: const [
                  (_EntryKind.hours, CupertinoIcons.timer, 'Uren'),
                  (_EntryKind.km, CupertinoIcons.car_fill, 'Kilometers'),
                ],
              ),
            if (!_isEdit && !_isIndirect) const SizedBox(height: 20),
            if (!(widget.vrij && !_isEdit))
            Text(
              _isKm
                  ? (_isEdit ? 'Kilometers aanpassen' : 'Kilometers toevoegen')
                  : (_isEdit ? 'Uren aanpassen' : 'Uren toevoegen'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            if (!(widget.vrij && !_isEdit)) const SizedBox(height: 20),
            _veldenBlok(context, inputBg, borderColor, isDark),
            const SizedBox(height: 20),
            CupertinoButton(
              color: AppColors.accent,
              disabledColor: CupertinoColors.systemFill.resolveFrom(context),
              borderRadius: BorderRadius.circular(16),
              onPressed: _isValid ? _add : null,
              child: Text(
                _isEdit ? 'Aanpassen' : 'Toevoegen$_knopSuffix',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ],
        ),
    );
  }
}

/// Pil-vormige tabkeuze (Uren | Kilometers), zelfde stijl als Week | Maand.
class _KindPil extends StatelessWidget {
  final _EntryKind waarde;
  final ValueChanged<_EntryKind?> onKies;
  final List<(_EntryKind, IconData, String)> opties;

  const _KindPil({
    required this.waarde,
    required this.onKies,
    required this.opties,
  });

  @override
  Widget build(BuildContext context) {
    final index = opties.indexWhere((o) => o.$1 == waarde);
    // Bij drie opties is er geen ruimte voor iconen naast de tekst.
    final compact = opties.length > 2;

    return Container(
      height: 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.card.resolveFrom(context),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: CupertinoColors.separator.resolveFrom(context),
          width: 0.5,
        ),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment(
              opties.length == 1
                  ? 0
                  : -1 + 2 * (index < 0 ? 0 : index) / (opties.length - 1),
              0,
            ),
            child: FractionallySizedBox(
              widthFactor: 1 / opties.length,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final o in opties)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onKies(o.$1),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!compact) Icon(
                            o.$2,
                            size: 18,
                            color: o.$1 == waarde
                                ? CupertinoColors.white
                                : CupertinoColors.secondaryLabel.resolveFrom(
                                    context,
                                  ),
                          ),
                          if (!compact) const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              o.$3,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: compact ? 14 : 16,
                                fontWeight: FontWeight.w600,
                                color: o.$1 == waarde
                                    ? CupertinoColors.white
                                    : CupertinoColors.secondaryLabel
                                          .resolveFrom(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Submit footer ─────────────────────────────────────────────────────────

class _SubmitFooter extends StatelessWidget {
  final Color borderColor;
  final bool isDark;
  final String totalsLabel;
  final String? error;
  final bool submitting;
  final bool canSubmit;
  /// `null`: geen knop (indirecte uren worden direct opgeslagen).
  final String? submitLabel;
  final VoidCallback onSubmit;

  /// "Tussentijds versturen"; `null` verbergt de knop.
  final VoidCallback? onTussentijds;
  final bool tussentijdsBezig;

  const _SubmitFooter({
    this.onTussentijds,
    this.tussentijdsBezig = false,
    required this.borderColor,
    required this.isDark,
    required this.totalsLabel,
    required this.error,
    required this.submitting,
    required this.canSubmit,
    required this.submitLabel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 16 + bottomInset),
      decoration: BoxDecoration(
        color: cardBg,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                totalsLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error!,
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.destructiveRed.resolveFrom(context),
              ),
            ),
          ],
          if (submitLabel != null) const SizedBox(height: 10),
          if (submitLabel != null) CupertinoButton(
            color: const Color(0xFF34C759),
            borderRadius: BorderRadius.circular(14),
            onPressed: canSubmit ? onSubmit : null,
            child: submitting
                ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                : Text(
                    submitLabel!,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.white,
                    ),
                  ),
          ),
          if (onTussentijds != null || tussentijdsBezig)
            CupertinoButton(
              padding: const EdgeInsets.only(top: 10),
              onPressed: onTussentijds,
              child: tussentijdsBezig
                  ? const CupertinoActivityIndicator()
                  : const Text(
                      'Uren tussentijds versturen',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: _accentOrange,
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
