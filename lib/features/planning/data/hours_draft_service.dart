import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/auth_service.dart';
import '../../bon_sync/data/firestore_bon_draft_repository.dart';
import '../../bon_sync/models/servicebon_sync.dart';
import '../models/hours_entry.dart';
import '../models/job_order.dart';
import '../models/scanned_extra.dart';
import '../models/signature_capture.dart';
import '../screens/hours_week_screen.dart'
    show hoursDraftKeyForOrder;
import 'extras_draft_service.dart';
import 'hours_sync_service.dart';
import '../models/visit_report.dart';
import 'visit_report_html.dart';
import 'visit_report_service.dart';
import 'planning_repository.dart';
import 'work_activity_catalog.dart';
import 'service_remote_job_order_repository.dart';

/// Marks a card in the hours draft as a kilometers card rather than an
/// hour card: `{'type': 'km', 'km': <int>, ...}`. Km cards keep
/// `minutes: 0` so anything summing minutes can stay oblivious to them.
const kmCardType = 'km';

bool isKmCard(Map card) => card['type'] == kmCardType;

/// A single hour or kilometers card as shown in the "Uren geregistreerd"
/// breakdown — its Uursoort label, duration (or [km]) and (optional) memo,
/// exactly as entered in `HoursWeekScreen`.
class HoursCardBreakdown {
  final String label;
  final int minutes;
  final int? km;
  final String? memo;
  const HoursCardBreakdown({
    required this.label,
    required this.minutes,
    this.km,
    this.memo,
  });

  bool get isKm => km != null;
  double get hours => minutes / 60;
}

/// One day's worth of [HoursCardBreakdown]s, oldest first.
class HoursDayBreakdown {
  final DateTime date;
  final List<HoursCardBreakdown> cards;
  const HoursDayBreakdown({required this.date, required this.cards});

  int get totalMinutes => cards.fold(0, (sum, c) => sum + c.minutes);
}

String _labelForCard(Map card) => WorkActivityCatalog.instance.labelVoorKaart(
  code: card['workActivityCode'] as String?,
  id: card['workActivityId'] as int?,
);

/// Maandag (00:00) van de week waarin [dag] valt.
DateTime maandagVanWeek(DateTime dag) =>
    DateTime(dag.year, dag.month, dag.day - (dag.weekday - 1));

DateTime _datumUitDagKey(String key) {
  final p = key.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

/// Een nog niet verstuurde uren- of km-kaart, voor het weekoverzicht
/// (`WeekAfsluitenScreen`).
class OpenKaart {
  const OpenKaart({
    required this.orderId,
    required this.dag,
    required this.label,
    required this.minuten,
    this.km,
    this.memo,
  });

  final String orderId;
  final DateTime dag;
  final String label;
  final int minuten;
  final int? km;
  final String? memo;
}

/// Uitkomst van [HoursDraftService.verstuurWeken]: per verstuurde week de
/// maandag van die week.
class WekenVerstuurd {
  const WekenVerstuurd(this.weken);
  final List<DateTime> weken;
  bool get isLeeg => weken.isEmpty;
}

/// Submits a bon's locally-drafted (not-yet-submitted) hours — the same
/// cards a technician enters via `HoursWeekScreen`'s "+" button — without
/// opening that screen, namely from `BonDetailScreen`'s publish button.
/// Reads and writes the exact same SharedPreferences draft `HoursWeekScreen`
/// does (see [hoursDraftKeyForOrder]), so the two stay in sync: cards
/// published here show up locked/sent if that screen is opened afterwards.
class HoursDraftService {
  HoursDraftService._();
  static final instance = HoursDraftService._();

  static const _uuid = Uuid();

  Future<Map<String, dynamic>> _readDraftDays(String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(hoursDraftKeyForOrder(orderId));
    if (raw == null) return {};
    final draft = jsonDecode(raw) as Map<String, dynamic>;
    return (draft['days'] as Map<String, dynamic>?) ?? {};
  }

  /// Total hours in [orderId]'s local draft — every card, whether or not
  /// it's been submitted to Ridder yet. This is what [BonDetailScreen]
  /// shows as "Uren & km" registered so far.
  /// Kaarten van een andere medewerker (bon met meerdere monteurs) tellen
  /// niet mee in "mijn" uren. Oude kaarten zonder eigenaar tellen wel mee.
  bool _isMine(Map card) {
    final eigenaar = card['monteurId'];
    final ik = AuthService.instance.currentMechanicId;
    return eigenaar == null || ik == null || eigenaar == ik;
  }

  Future<double> localTotalHours(String orderId) async {
    final days = await _readDraftDays(orderId);
    var minutes = 0;
    for (final dayEntry in days.values) {
      final cards = (dayEntry as Map)['cards'] as List<dynamic>? ?? const [];
      for (final c in cards) {
        if (!_isMine(c as Map)) continue;
        minutes += c['minutes'] as int;
      }
    }
    return minutes / 60;
  }

  /// Total kilometers in [orderId]'s local draft, submitted or not.
  Future<int> localTotalKm(String orderId) async {
    final days = await _readDraftDays(orderId);
    var km = 0;
    for (final dayEntry in days.values) {
      final cards = (dayEntry as Map)['cards'] as List<dynamic>? ?? const [];
      for (final c in cards) {
        if (!_isMine(c as Map)) continue;
        if (isKmCard(c)) km += c['km'] as int;
      }
    }
    return km;
  }

  /// Per-day breakdown of [orderId]'s local draft — every card, with its
  /// Uursoort label and memo, grouped by day and sorted oldest first. This
  /// is what [WorkCompletionScreen] shows instead of a single combined
  /// total, so the technician can double-check exactly what was booked
  /// (and why) before publishing.
  Future<List<HoursDayBreakdown>> localDailyBreakdown(String orderId) async {
    await WorkActivityCatalog.instance.laad();
    final days = await _readDraftDays(orderId);
    final result = <HoursDayBreakdown>[];
    for (final dayEntry in days.entries) {
      final cards =
          ((dayEntry.value as Map)['cards'] as List<dynamic>? ?? const [])
              .where((c) => _isMine(c as Map))
              .toList();
      if (cards.isEmpty) continue;
      final dateParts = dayEntry.key.split('-').map(int.parse).toList();
      result.add(
        HoursDayBreakdown(
          date: DateTime(dateParts[0], dateParts[1], dateParts[2]),
          cards: cards.map((c) {
            final map = c as Map;
            final km = isKmCard(map);
            return HoursCardBreakdown(
              label: km
                  ? 'Kilometers'
                  : _labelForCard(map),
              minutes: map['minutes'] as int,
              km: km ? map['km'] as int : null,
              memo: (map['memo'] as String?)?.trim().isEmpty ?? true
                  ? null
                  : map['memo'] as String?,
            );
          }).toList(),
        ),
      );
    }
    result.sort((a, b) => a.date.compareTo(b.date));
    return result;
  }

  /// Publishes pending hour cards and extra-material drafts — plus, if
  /// captured, the customer [signature] (attributed to [signerName]) — in
  /// one Service Remote job-order submission. Both drafts are marked sent
  /// only after the POST succeeds.
  ///
  /// Each pending km card becomes its own line of the "Kilometers" article
  /// ([kmItemCode]); being marked submitted afterwards, like hour cards,
  /// guarantees each day's kilometers are sent exactly once.
  ///
  /// Uren en kilometers gaan per **week** naar Ridder (zie
  /// [verstuurWeken]): staan er nog openstaande kaarten uit eerdere weken,
  /// dan gaan die eerst als eigen weekregistratie(s). Deze laatste
  /// registratie bevat daarna de resterende uren/km, het materiaal, de
  /// handtekening en het bezoekrapport.
  Future<JobOrderSubmissionResult?> submitPendingHours(
    ServiceOrder order, {
    SignatureCapture? signature,
    String? signerName,
  }) async {
    final weken = await _openWeken(order.id);
    if (weken.length > 1) {
      final laatste = weken.last;
      for (final week in weken.where((w) => w != laatste)) {
        await _verstuur(orderId: order.id, tussentijds: true, week: week);
      }
    }
    return _verstuur(
      orderId: order.id,
      order: order,
      signature: signature,
      signerName: signerName,
    );
  }

  /// Weekregistratie(s): verstuurt per week de nog niet verstuurde uren en
  /// kilometers van [orderId] als gewone servicebonregistratie zónder
  /// handtekening, bezoekrapport of materiaal (die komen bij
  /// "Werk afronden"). Kantoor verwerkt zo'n registratie; de uren worden dan
  /// projecturen en de bon blijft open (getest okt 2026, zie
  /// claude/onderzoek-tussentijdse-uren.md in het project).
  ///
  /// Met [alleenAfgelopenWeken] blijft de lopende week staan — zo werkt het
  /// automatisch versturen; de knop "Uren tussentijds versturen" stuurt ook
  /// de lopende week.
  Future<WekenVerstuurd> verstuurWeken(
    String orderId, {
    bool alleenAfgelopenWeken = false,
  }) async {
    final dezeWeek = maandagVanWeek(DateTime.now());
    final verstuurd = <DateTime>[];
    for (final week in await _openWeken(orderId)) {
      if (alleenAfgelopenWeken && !week.isBefore(dezeWeek)) continue;
      final r = await _verstuur(orderId: orderId, tussentijds: true, week: week);
      if (r != null) verstuurd.add(week);
    }
    return WekenVerstuurd(verstuurd);
  }

  /// Bezig met [verstuurAfgelopenWekenOveral]; voorkomt dubbel versturen.
  bool _automatischBezig = false;

  /// Verstuurt voor álle bonnen met een lokaal urenconcept de uren en km uit
  /// afgelopen weken (de knop "Uren versturen" op `WeekAfsluitenScreen`).
  /// Gaat het bij een bon mis (geen verbinding, bon weg, ...), dan gaan de
  /// andere bonnen gewoon door; de fouten komen terug in `fouten` (per bon
  /// het id met de foutmelding).
  Future<({int aantal, Map<String, Object> fouten})>
  verstuurAfgelopenWekenOveral() async {
    final fouten = <String, Object>{};
    if (_automatischBezig) return (aantal: 0, fouten: fouten);
    if (AuthService.instance.currentMechanicId == null) {
      return (aantal: 0, fouten: fouten);
    }
    _automatischBezig = true;
    var aantal = 0;
    try {
      for (final orderId in await _bonnenMetConcept()) {
        try {
          final r = await verstuurWeken(orderId, alleenAfgelopenWeken: true);
          aantal += r.weken.length;
        } catch (e) {
          debugPrint('Weekregistratie bon $orderId niet verstuurd: $e');
          fouten[orderId] = e;
        }
      }
    } finally {
      _automatischBezig = false;
    }
    return (aantal: aantal, fouten: fouten);
  }

  /// Id's van alle bonnen met een lokaal urenconcept op dit toestel.
  Future<List<String>> _bonnenMetConcept() async {
    final prefs = await SharedPreferences.getInstance();
    const prefix = 'hours_week_draft_';
    return prefs
        .getKeys()
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .where((id) => int.tryParse(id) != null)
        .toList();
  }

  /// Mijn nog niet verstuurde uren- en km-kaarten van vóór deze week (dus
  /// t/m afgelopen zondag, de deadline), over alle bonnen. Leeg = vorige
  /// week is afgerond. Haalt eerst kaarten van andere toestellen op; lukt
  /// dat niet (offline), dan telt wat er lokaal staat.
  ///
  /// Met [synchroniseer] `false` wordt alleen lokaal gekeken (snel, voor de
  /// controle bij het toevoegen van uren).
  Future<List<OpenKaart>> openKaartenAfgelopenWeken({
    bool synchroniseer = true,
  }) async {
    final dezeWeek = maandagVanWeek(DateTime.now());
    final catalogus = WorkActivityCatalog.instance;
    try {
      await catalogus.laad();
    } catch (_) {}
    final kaarten = <OpenKaart>[];
    for (final orderId in await _bonnenMetConcept()) {
      if (synchroniseer) {
        try {
          await HoursSyncService.instance
              .haalOp(orderId)
              .timeout(const Duration(seconds: 8));
        } catch (_) {}
      }
      final days = await _readDraftDays(orderId);
      for (final e in days.entries) {
        final dag = _datumUitDagKey(e.key);
        if (!dag.isBefore(dezeWeek)) continue;
        for (final c in ((e.value as Map)['cards'] as List?) ?? const []) {
          final kaart = c as Map;
          if (!_isMine(kaart) || kaart['submitted'] == true) continue;
          kaarten.add(
            OpenKaart(
              orderId: orderId,
              dag: dag,
              label: isKmCard(kaart) ? 'Kilometers' : _labelForCard(kaart),
              minuten: isKmCard(kaart) ? 0 : (kaart['minutes'] as int? ?? 0),
              km: isKmCard(kaart) ? kaart['km'] as int? : null,
              memo: kaart['memo'] as String?,
            ),
          );
        }
      }
    }
    kaarten.sort((a, b) => a.dag.compareTo(b.dag));
    return kaarten;
  }

  /// Maandagen van de weken waarin [orderId] nog niet verstuurde eigen
  /// uren- of km-kaarten heeft, oudste eerst.
  Future<List<DateTime>> _openWeken(String orderId) async {
    await HoursSyncService.instance.haalOp(orderId);
    final days = await _readDraftDays(orderId);
    final weken = <DateTime>{};
    for (final e in days.entries) {
      final cards = ((e.value as Map)['cards'] as List?) ?? const [];
      final open = cards.any((c) {
        final kaart = c as Map;
        return _isMine(kaart) && kaart['submitted'] != true;
      });
      if (open) weken.add(maandagVanWeek(_datumUitDagKey(e.key)));
    }
    return weken.toList()..sort();
  }

  /// Eén registratie naar Ridder. [order] is alleen nodig voor de
  /// eindregistratie (bezoekrapport). Met [week] gaan alleen kaarten uit die
  /// week (maandag t/m zondag) mee.
  Future<JobOrderSubmissionResult?> _verstuur({
    required String orderId,
    ServiceOrder? order,
    SignatureCapture? signature,
    String? signerName,
    bool tussentijds = false,
    DateTime? week,
  }) async {
    if (tussentijds) signature = null;
    bool inWeek(String dagKey) =>
        week == null || maandagVanWeek(_datumUitDagKey(dagKey)) == week;
    final mechanicId = AuthService.instance.currentMechanicId;
    if (mechanicId == null) {
      throw const JobOrderSubmissionLoginFailed('Not logged in.');
    }
    // Eigen uren/km uit de gedeelde opslag erbij, zodat ook uren die op een
    // ander toestel zijn ingevoerd worden gepubliceerd.
    await HoursSyncService.instance.haalOp(orderId);
    final days = await _readDraftDays(orderId);

    // Uursoorten op code omzetten naar het id in déze administratie (live
    // en test hebben andere id's). Bestaat een uursoort hier niet, dan
    // stoppen vóór er iets verstuurd of geclaimd is — nooit op een
    // verkeerde uursoort boeken.
    final catalogus = WorkActivityCatalog.instance;
    await catalogus.laad();
    final onbekend = <String>{};
    for (final dag in days.values) {
      for (final c in ((dag as Map)['cards'] as List?) ?? const []) {
        final kaart = c as Map;
        if (!_isMine(kaart)) continue;
        if (kaart['submitted'] == true || isKmCard(kaart)) continue;
        if (catalogus.idVoorKaart(
              code: kaart['workActivityCode'] as String?,
              id: kaart['workActivityId'] as int?,
            ) ==
            null) {
          onbekend.add(_labelForCard(kaart));
        }
      }
    }
    if (onbekend.isNotEmpty) {
      throw JobOrderSubmissionPostFailed(
        'Deze uursoort bestaat niet in Ridder: ${onbekend.join(', ')}. '
        'Open de urenregel en kies een andere uursoort.',
      );
    }
    final prefs = await SharedPreferences.getInstance();

    // Artikelen: bij gedeelde opslag eerst "claimen" dat wij afronden, zodat
    // twee monteurs niet tegelijk (en dus dubbel) naar Ridder publiceren.
    final extrasService = ExtrasDraftService.instance;
    final gedeeld = extrasService.isGedeeld && !tussentijds;
    final repo = FirestoreBonDraftRepository.instance;
    var geclaimd = false;
    var pendingExtras = <ScannedExtra>[];
    if (gedeeld) {
      final AfrondClaim claim;
      try {
        await extrasService.migreer(orderId);
        claim = await repo.claimAfronden(
          orderId,
          monteurId: mechanicId,
          monteurNaam: AuthService.instance.currentEmployee?.name ?? '',
        );
      } catch (e) {
        throw JobOrderSubmissionSyncFailed(e.toString());
      }
      switch (claim) {
        case AfrondClaimBezet(:final doorNaam):
          throw JobOrderSubmissionBezetDoorCollega(
            '$doorNaam is deze bon op dit moment al aan het afronden. '
            'Probeer het over een paar minuten opnieuw.',
          );
        case AfrondClaimAlAfgerond():
          // Een collega heeft de artikelen al gepubliceerd; eigen uren/km
          // die nog op dit toestel staan gaan hieronder alsnog mee.
          pendingExtras = [];
        case AfrondClaimGelukt():
          geclaimd = true;
          try {
            pendingExtras = (await extrasService.load(
              orderId,
            )).where((extra) => extra.needsPublication).toList();
          } catch (e) {
            await _annuleerClaim(orderId);
            throw JobOrderSubmissionSyncFailed(e.toString());
          }
      }
    } else if (!tussentijds) {
      pendingExtras = (await extrasService.load(
        orderId,
      )).where((extra) => extra.needsPublication).toList();
    }

    final entries = <HoursEntry>[];
    final pendingKm = <int>[];
    final verstuurdeKaartIds = <String>[];
    final updatedDays = <String, dynamic>{};
    for (final dayEntry in days.entries) {
      final dayMap = Map<String, dynamic>.from(dayEntry.value as Map);
      final cards = ((dayMap['cards'] as List<dynamic>?) ?? const [])
          .map((c) => Map<String, dynamic>.from(c as Map))
          .toList();
      final dateParts = dayEntry.key.split('-').map(int.parse).toList();
      var cursor = DateTime(dateParts[0], dateParts[1], dateParts[2], 8);
      final updatedCards = <Map<String, dynamic>>[];
      for (final card in cards) {
        // Kaarten van een andere monteur (zelfde bon, ander account) horen
        // hier niet bij: niet versturen en niet als de mijne boeken.
        if (!_isMine(card)) {
          updatedCards.add(card);
          continue;
        }
        final alreadySubmitted = card['submitted'] as bool? ?? false;
        // Alleen kaarten uit de gevraagde week.
        if (!inWeek(dayEntry.key)) {
          updatedCards.add(card);
          continue;
        }
        final minutes = card['minutes'] as int;
        if (!alreadySubmitted && card['id'] is String) {
          verstuurdeKaartIds.add(card['id'] as String);
        }
        if (!alreadySubmitted && isKmCard(card)) {
          pendingKm.add(card['km'] as int);
        } else if (!alreadySubmitted) {
          final end = cursor.add(Duration(minutes: minutes));
          entries.add(
            HoursEntry(
              jobOrderId: int.parse(orderId),
              employeeId: mechanicId,
              start: cursor,
              end: end,
              totalTime: minutes,
              timeEmployee: minutes,
              workActivityId: catalogus.idVoorKaart(
                code: card['workActivityCode'] as String?,
                id: card['workActivityId'] as int?,
              )!,
              uniqueId: _uuid.v4(),
              memo: card['memo'] as String?,
            ),
          );
          cursor = end;
        }
        updatedCards.add({...card, 'submitted': true});
      }
      updatedDays[dayEntry.key] = {'cards': updatedCards};
    }
    // Overnachtingen worden sinds okt 2026 als eigen (indirecte) bewerking
    // geboekt vanuit het urenscherm; het oude bon-veld OVERNACHTING laten we
    // ongemoeid.
    const bool? overnachting = null;
    final signaturePaths = signature != null && signature.paths.isNotEmpty
        ? signature.paths
        : null;
    if (tussentijds && entries.isEmpty && pendingKm.isEmpty) return null;
    if (entries.isEmpty &&
        pendingExtras.isEmpty &&
        pendingKm.isEmpty &&
        signaturePaths == null) {
      if (geclaimd) await _bevestigAfgerond(orderId, const []);
      return null;
    }

    // Bezoekrapport (zoals de klant het heeft getekend) en de foto's en
    // documenten uit "Rapport schrijven". Mislukt het samenstellen, dan gaat
    // de registratie gewoon zonder rapport.
    final ondertekenaar = await VisitReportService.instance.laadOndertekenaar(
      orderId,
    );
    String? bezoekrapport;
    VisitReportData? rapportData;
    final getekendOp = DateTime.now();
    var bijlagen = <String>[];
    if (!tussentijds) try {
      final data = await VisitReportService.instance.verzamel(order!);
      rapportData = data;
      bezoekrapport = buildVisitReportHtml(
        data,
        handtekeningPng: signature?.png,
        ondertekenaar: ondertekenaar,
        getekendOp: getekendOp,
        logoPng: await VisitReportService.instance.laadLogo(),
      );
      final rapport = data.rapport;
      if (rapport != null) {
        bijlagen = [
          ...rapport.photoPaths,
          ...rapport.documents.map((d) => d.path),
        ];
      }
    } catch (e) {
      debugPrint('Bezoekrapport niet samengesteld: $e');
    }

    final JobOrderSubmissionResult resultaat;
    try {
      final kmExtras = <ScannedExtra>[];
      if (pendingKm.isNotEmpty) {
        final kmItem = await PlanningRepository.instance.fetchItemByCode(
          kmItemCode,
        );
        if (kmItem == null) {
          throw JobOrderSubmissionPostFailed(
            'Artikel "$kmItemCode" (Kilometers) niet gevonden in Ridder.',
          );
        }
        for (final km in pendingKm) {
          kmExtras.add(ScannedExtra(item: kmItem, scannedCount: km));
        }
      }

      // Een diverse regel (vrije tekst) heeft geen artikel en dus geen eigen
      // eenheid: die vullen we met "Stuks" uit Ridder (itemunits).
      final stuksId = pendingExtras.any((e) => e.isManual && e.unitId == null)
          ? await PlanningRepository.instance.fetchStuksUnitId()
          : null;
      final extrasMetEenheid = [
        for (final e in pendingExtras)
          if (e.isManual && e.unitId == null && stuksId != null)
            ScannedExtra(
              item: {
                ...e.item,
                'itemunit': {'id': stuksId},
              },
              scannedCount: e.scannedCount,
              ridderId: e.ridderId,
              syncedQuantity: e.syncedQuantity,
              regelId: e.regelId,
              monteurId: e.monteurId,
              monteurNaam: e.monteurNaam,
            )
          else
            e,
      ];

      resultaat = await ServiceRemoteJobOrderRepository.instance
          .submitHoursForJobOrder(
            jobOrderId: int.parse(orderId),
            employeeId: mechanicId,
            hours: entries,
            extras: [...extrasMetEenheid, ...kmExtras],
            signaturePaths: signaturePaths,
            signerName: (ondertekenaar?.name.trim().isNotEmpty ?? false)
                ? ondertekenaar!.name.trim()
                : signerName,
            signerEmail: ondertekenaar?.email,
            employeeName: AuthService.instance.currentEmployee?.name,
            htmlFile: bezoekrapport,
            overnachting: overnachting,
            attachmentPaths: bijlagen,
          );
    } catch (_) {
      if (geclaimd) await _annuleerClaim(orderId);
      rethrow;
    }

    if (geclaimd) {
      await _bevestigAfgerond(
        orderId,
        pendingExtras.map((e) => e.regelId).whereType<String>(),
      );
    }

    if (days.isNotEmpty) {
      await prefs.setString(
        hoursDraftKeyForOrder(orderId),
        jsonEncode({'days': updatedDays}),
      );
    }
    await HoursSyncService.instance.markeerVerstuurd(
      orderId,
      verstuurdeKaartIds,
    );
    if (!gedeeld && pendingExtras.isNotEmpty) {
      await extrasService.markeerLokaalGepubliceerd(orderId, pendingExtras);
    }
    // Het getekende rapport als pdf bewaren, om het na afronden in de app
    // te kunnen bekijken en delen.
    if (rapportData != null && !tussentijds) {
      try {
        final pdf = await VisitReportService.instance.maakPdf(
          rapportData,
          handtekeningPng: signature?.png,
          ondertekenaar: ondertekenaar,
          getekendOp: getekendOp,
        );
        await VisitReportService.instance.bewaarDefinitievePdf(orderId, pdf);
      } catch (e) {
        debugPrint('Pdf van bezoekrapport niet bewaard: $e');
      }
    }
    return resultaat;
  }

  /// Zet de bon in de gedeelde opslag op "afgerond". Ridder heeft de POST
  /// dan al geaccepteerd, dus een fout hier mag het afronden niet laten
  /// mislukken (anders zou opnieuw proberen dubbel boeken). Offline blijft
  /// de schrijfactie in de wachtrij staan tot er weer verbinding is.
  Future<void> _bevestigAfgerond(String orderId, Iterable<String> ids) async {
    try {
      await FirestoreBonDraftRepository.instance
          .bevestigAfgerond(orderId, ids)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Bon $orderId niet als afgerond gemarkeerd in Firestore: $e');
    }
  }

  Future<void> _annuleerClaim(String orderId) async {
    try {
      await FirestoreBonDraftRepository.instance
          .annuleerAfronden(orderId)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Afronden van bon $orderId niet vrijgegeven: $e');
    }
  }
}
