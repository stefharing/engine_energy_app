import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/api/api_client.dart';
import '../../../core/auth/employee.dart';
import '../../../core/auth/employee_repository.dart';
import '../data/job_order_service.dart';
import '../data/extras_draft_service.dart';
import '../data/hours_draft_service.dart';
import '../data/hours_sync_service.dart';
import '../data/map_snapshot_service.dart';
import '../data/picking_sync_service.dart';
import '../data/planning_repository.dart';
import '../data/signature_draft_service.dart';
import '../data/visit_report_service.dart';
import '../models/work_report_draft.dart';
import '../models/job_order.dart';
import '../models/service_interval.dart';
import '../models/signature_capture.dart';
import '../../declaraties/data/declaratie_service.dart';
import '../../declaraties/screens/declaraties_screen.dart';
import 'used_materials_screen.dart';
import 'service_object_documents_screen.dart';
import 'service_object_history_screen.dart';
import 'hours_week_screen.dart';
import 'parts_list_screen.dart';
import 'work_completion_screen.dart' show WorkCompletionScreen, bonCompletedKey;
import 'visit_report_pdf_screen.dart';
import 'visit_report_screen.dart';
import 'work_report_screen.dart';
import '../../../core/theme/app_colors.dart';

// ─── Screen ────────────────────────────────────────────────────────────────────

class BonDetailScreen extends StatefulWidget {
  final ServiceOrder order;
  const BonDetailScreen({super.key, required this.order});

  @override
  State<BonDetailScreen> createState() => _BonDetailScreenState();
}

class _BonDetailScreenState extends State<BonDetailScreen> {
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

  List<Map<String, dynamic>> _parts = [];
  Set<String> _takenIds = {};
  int _extraCount = 0;
  bool _partsConfirmed = false;

  Map<String, dynamic>? _address;
  MapSnapshot? _kaart;
  String? _contactName;
  String? _contactPhone;

  bool _loading = true;
  String? _error;
  bool _showNavTitle = false;
  final _scrollCtrl = ScrollController();

  String? _bannerText;
  Timer? _bannerTimer;

  SignatureCapture? _signature;
  bool _isCompleted = false;

  /// Status van het werkrapport uit "Rapport schrijven" (null = nog niets).
  WorkReportStatus? _rapportStatus;

  ServiceOrder get _order => widget.order;

  /// Monteurs op deze bon, bijgewerkt nadat er een monteur is toegevoegd.
  List<ServicePerson>? _monteursNaToevoegen;
  List<ServicePerson> get _monteurs =>
      _monteursNaToevoegen ?? _order.assignedMechanics;
  bool _monteurBezig = false;
  int get _aantalOpenPick =>
      _parts.where((p) => !_takenIds.contains(p['id'].toString())).length;

  /// Total hours in this bon's local draft (see [HoursDraftService]) —
  /// every card entered via "Uren & km".
  double _totalUrenGeregistreerd = 0;

  /// Kilometers entered via "Uren & km" (see [HoursDraftService]).
  int _totalKm = 0;

  /// Declaraties op deze bon, en hoeveel daarvan nog op verzenden wachten.
  int _declaratieCount = 0;
  int _declaratieWacht = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadDeclaraties();
    // Toon navbar-titel zodra de titel in de hero voorbij scrolt
    _scrollCtrl.addListener(() {
      final show = _scrollCtrl.offset > 110;
      if (show != _showNavTitle) setState(() => _showNavTitle = show);
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _bannerTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool showLoading = true}) async {
    setState(() {
      if (showLoading) _loading = true;
      _error = null;
    });
    try {
      await Future.wait([
        _loadParts(),
        _loadAddress(),
        _loadContact(),
        _loadHours(),
        _loadSignature(),
        _loadCompleted(),
        _loadRapportStatus(),
      ]);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Pull-to-refresh: reloads everything (parts, address, contact) without
  /// swapping the screen to the full-page spinner — in particular this is
  /// how the "Uren & km" hours count picks up hours registered elsewhere
  /// (e.g. via "Werk afronden") without leaving and re-opening this screen.
  Future<void> _onRefresh() => _load(showLoading: false);

  Future<void> _loadParts() async {
    final resp = await ApiClient.instance.dio.get(
      '/production/joborderdetails',
      queryParameters: {
        'page': 1,
        'size': 200,
        'filter': 'joborder.id[eq]${_order.id}',
      },
    );
    final all = (resp.data['data'] as List).cast<Map<String, dynamic>>();
    final parts = all.where((e) => e['joborderdetailitem'] != null).toList();

    await PickingSyncService.instance.haalOp(_order.id);
    final prefs = await SharedPreferences.getInstance();
    final taken = <String>{};
    for (final p in parts) {
      if (prefs.getBool('part_taken_${_order.id}_${p['id']}') ?? false) {
        taken.add(p['id'].toString());
      }
    }
    // Zelfde bron als UsedMaterialsScreen en PartsListScreen (gedeeld via
    // Firestore, of lokaal als Firebase niet beschikbaar is).
    var extrasCount = _extraCount;
    try {
      extrasCount = (await ExtrasDraftService.instance.load(_order.id)).length;
    } catch (_) {
      // Geen verbinding en niets in de cache: toon de vorige telling.
    }
    final confirmed = prefs.getBool('parts_confirmed_${_order.id}') ?? false;

    if (mounted)
      setState(() {
        _parts = parts;
        _takenIds = taken;
        _extraCount = extrasCount;
        _partsConfirmed = confirmed;
      });
  }

  Future<void> _loadHours() async {
    await HoursSyncService.instance.haalOp(_order.id);
    final total = await HoursDraftService.instance.localTotalHours(_order.id);
    final km = await HoursDraftService.instance.localTotalKm(_order.id);
    if (mounted) {
      setState(() {
        _totalUrenGeregistreerd = total;
        _totalKm = km;
      });
    }
  }

  Future<void> _loadDeclaraties() async {
    final lijst = (await DeclaratieService.instance.laad())
        .where((d) => d.bonId == _order.id)
        .toList();
    if (mounted) {
      setState(() {
        _declaratieCount = lijst.length;
        _declaratieWacht = lijst.where((d) => !d.isVerstuurd).length;
      });
    }
  }

  Future<void> _openDeclaraties() async {
    await Navigator.of(context).push<void>(
      CupertinoPageRoute<void>(
        builder: (_) => DeclaratiesScreen(order: _order),
      ),
    );
    if (mounted) _loadDeclaraties();
  }

  Future<void> _loadSignature() async {
    final sig = await SignatureDraftService.instance.load(_order.id);
    if (mounted) setState(() => _signature = sig);
  }

  Future<void> _loadRapportStatus() async {
    final rapport = await VisitReportService.instance.laadWerkrapport(
      _order.id,
    );
    if (mounted) setState(() => _rapportStatus = rapport?.status);
  }

  Future<void> _loadCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    final completed = prefs.getBool(bonCompletedKey(_order.id)) ?? false;
    if (mounted) setState(() => _isCompleted = completed);
  }

  Future<void> _loadAddress() async {
    try {
      await _loadAddressRidder();
    } finally {
      unawaited(_loadKaart());
    }
  }

  Future<void> _loadKaart() async {
    if (!mounted) return;
    final donker = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final adres = _address != null ? _fmtAddr(_address!) : _order.location;
    final land = _address?['country']?.toString() ?? '';
    final snap = await MapSnapshotService.instance.laad(
      land.isNotEmpty ? '$adres, $land' : adres,
      donker: donker,
    );
    if (snap != null && mounted) setState(() => _kaart = snap);
  }

  Future<void> _loadAddressRidder() async {
    final id = _order.serviceObjectId;
    if (id == null) return;
    final obj = await PlanningRepository.instance.fetchServiceObject(id);
    if (obj == null) return;
    final locId = (obj['objectlocation'] as Map<String, dynamic>?)?['id']
        ?.toString();
    if (locId == null) return;
    final del = await PlanningRepository.instance.fetchDeliveryAddress(locId);
    final addrId = (del?['address'] as Map<String, dynamic>?)?['id']
        ?.toString();
    if (addrId == null) return;
    final addr = await PlanningRepository.instance.fetchAddress(addrId);
    if (addr != null && mounted) setState(() => _address = addr);
  }

  Future<void> _loadContact() async {
    final orderId = _order.productionOrderId;
    if (orderId == null) return;
    final prod = await PlanningRepository.instance.fetchProductionOrder(
      orderId,
    );
    if (prod == null || !mounted) return;
    final ref = prod['contact'] as Map<String, dynamic>?;
    if (ref == null) return;
    final name = ref['recordtag']?.toString() ?? '';
    final cId = ref['id']?.toString();
    String phone = '';
    if (cId != null) {
      final c = await PlanningRepository.instance.fetchContact(cId);
      if (c != null) {
        phone =
            c['phone']?.toString() ??
            c['mobile']?.toString() ??
            c['phone1']?.toString() ??
            c['mobilephone']?.toString() ??
            '';
      }
    }
    if (!mounted) return;
    setState(() {
      _contactName = name.isNotEmpty ? name : null;
      _contactPhone = phone.isNotEmpty ? phone : null;
    });
  }

  String _fmtAddr(Map<String, dynamic> a) {
    final line1 = '${a['street'] ?? ''} ${a['housenumber'] ?? ''}'.trim();
    final line2 = '${a['zipcode'] ?? ''} ${a['city'] ?? ''}'.trim();
    return [line1, line2].where((s) => s.isNotEmpty).join(', ');
  }

  Future<void> _openMaps() async {
    final addr = _address != null ? _fmtAddr(_address!) : _order.location;
    final q = Uri.encodeComponent(addr);
    final k = _kaart;
    final ll = k != null ? '${k.lat},${k.lon}' : null;
    final opts = <(String, Uri)>[];
    if (await canLaunchUrl(Uri.parse('maps://')))
      opts.add((
        'Apple Maps',
        Uri.parse(ll != null ? 'maps://?q=$q&ll=$ll' : 'maps://?q=$q'),
      ));
    if (await canLaunchUrl(Uri.parse('comgooglemaps://')))
      opts.add((
        'Google Maps',
        Uri.parse(
          ll != null
              ? 'comgooglemaps://?q=$ll'
              : 'comgooglemaps://?q=$q',
        ),
      ));
    if (await canLaunchUrl(Uri.parse('waze://')))
      opts.add((
        'Waze',
        Uri.parse(
          ll != null ? 'waze://?ll=$ll&navigate=yes' : 'waze://?q=$q',
        ),
      ));
    if (opts.length == 1) {
      await launchUrl(opts.first.$2);
      return;
    }
    if (!mounted) return;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Navigeer naar locatie'),
        message: Text(addr),
        actions: [
          for (final (n, u) in opts)
            CupertinoActionSheetAction(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await launchUrl(u);
              },
              child: Text(n),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
  }

  Future<void> _callContact() async {
    final p = _contactPhone;
    if (p == null) return;
    final uri = Uri.parse('tel:${p.replaceAll(' ', '')}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _push(
    Widget screen, {
    bool refreshParts = false,
    bool refreshHours = false,
  }) async {
    await Navigator.of(
      context,
    ).push(CupertinoPageRoute<void>(builder: (_) => screen));
    if (refreshParts && mounted) _loadParts();
    if (refreshHours && mounted) _loadHours();
  }

  Future<void> _openHoursWeek() async {
    final saved = await Navigator.of(context).push<bool>(
      CupertinoPageRoute<bool>(
        builder: (_) => HoursWeekScreen(initialOrder: _order),
      ),
    );
    if (!mounted) return;
    await _loadHours();
    if (saved == true && mounted) _showBanner('Uren opgeslagen');
  }

  /// Opent het bezoekrapport: de klant bekijkt het overzicht en tekent
  /// onderaan (met naam en e-mailadres).
  Future<void> _openSignaturePad() async {
    // Na afronden: het getekende rapport bekijken (zoals gepubliceerd).
    if (_isCompleted) {
      final pdf =
          await VisitReportService.instance.laadDefinitievePdf(_order.id) ??
          await VisitReportService.instance.maakPdfVoorBon(_order);
      if (!mounted) return;
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => VisitReportPdfScreen(
            pdf: pdf,
            bestandsnaam:
                'Bezoekrapport_${_order.orderNumber.replaceAll(RegExp(r'[^\w-]'), '_')}.pdf',
            titel: 'Getekend bezoekrapport',
          ),
        ),
      );
      return;
    }
    final getekend = await Navigator.of(context).push<bool>(
      CupertinoPageRoute<bool>(
        builder: (_) =>
            VisitReportScreen(order: _order, contactName: _contactName),
      ),
    );
    if (!mounted) return;
    final sig = await SignatureDraftService.instance.load(_order.id);
    if (!mounted) return;
    setState(() => _signature = sig);
    if (getekend == true && sig != null) _showBanner('Bezoekrapport getekend');
  }

  /// Laat de monteur een collega kiezen en zet die op de bon (Ridder:
  /// `employees[]` van de bon, zie [JobOrderService.addEmployee]).
  Future<void> _voegMonteurToe() async {
    if (_monteurBezig) return;
    setState(() => _monteurBezig = true);
    try {
      final alles = await EmployeeRepository.instance.fetchFieldEngineers();
      if (!mounted) return;
      final opBon = _monteurs.map((m) => m.id).toSet();
      final keuzes = alles.where((e) => !opBon.contains(e.id)).toList();
      if (keuzes.isEmpty) {
        await _meldingDialoog(
          'Geen monteurs beschikbaar',
          'Alle monteurs staan al op deze bon.',
        );
        return;
      }
      final gekozen = await showCupertinoModalPopup<Employee>(
        context: context,
        builder: (ctx) => CupertinoActionSheet(
          title: const Text('Monteur toevoegen'),
          message: const Text('Kies een collega die ook op deze bon werkt.'),
          actions: [
            for (final e in keuzes)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(ctx).pop(e),
                child: Text(e.name),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuleren'),
          ),
        ),
      );
      if (gekozen == null || !mounted) return;

      final actieId = _order.appointmentActionIds.firstOrNull;
      if (actieId == null) {
        await _meldingDialoog(
          'Kan niet toevoegen',
          'Deze bon heeft nog geen planningsafspraak in Ridder. '
              'Vraag kantoor om de bon in te plannen.',
        );
        return;
      }
      await JobOrderService.instance.addEmployee(
        appointmentActionId: actieId,
        employeeId: gekozen.id,
      );
      if (!mounted) return;
      setState(() {
        _monteursNaToevoegen = [
          ..._monteurs,
          ServicePerson(id: gekozen.id, name: gekozen.name),
        ];
      });
      _showBanner('${gekozen.name} toegevoegd');
    } on MonteurAlOpBon {
      if (!mounted) return;
      await _meldingDialoog(
        'Staat al op de bon',
        'Deze monteur is al aan de bon toegevoegd.',
      );
    } on GeenAfspraakOpBon {
      if (!mounted) return;
      await _meldingDialoog(
        'Kan niet toevoegen',
        'Deze bon heeft nog geen planningsafspraak in Ridder. '
            'Vraag kantoor om de bon in te plannen.',
      );
    } catch (e, st) {
      debugPrint('[monteur toevoegen] mislukt: $e\n$st');
      if (!mounted) return;
      await _meldingDialoog('Toevoegen mislukt', _foutTekst(e));
    } finally {
      if (mounted) setState(() => _monteurBezig = false);
    }
  }

  /// Leesbare foutmelding met de technische reden erbij, zodat een mislukte
  /// aanroep (status + antwoord van Ridder) te herleiden is.
  String _foutTekst(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      var body = '${e.response?.data ?? e.error ?? e.message ?? ''}';
      if (body.length > 300) body = '${body.substring(0, 300)}…';
      if (status == null) {
        return 'Geen verbinding met de server. Probeer het opnieuw.\n\n'
            '${e.type.name}';
      }
      return 'Ridder gaf een fout terug (status $status).\n\n$body';
    }
    return 'Er ging iets mis: $e';
  }

  Future<void> _meldingDialoog(String titel, String tekst) {
    return showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(titel),
        content: Text(tekst),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Ok'),
          ),
        ],
      ),
    );
  }

  void _showBanner(String text) {
    _bannerTimer?.cancel();
    setState(() => _bannerText = text);
    _bannerTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _bannerText = null);
    });
  }

  /// Opens the "Werk afronden" summary screen, which publishes this bon's
  /// locally-saved hours to Ridder in one go.
  Future<void> _openWorkCompletion() async {
    final published = await Navigator.of(context).push<bool>(
      CupertinoPageRoute<bool>(
        builder: (_) => WorkCompletionScreen(
          order: _order,
          totalUrenGeregistreerd: _totalUrenGeregistreerd,
          signature: _signature,
          contactName: _contactName,
        ),
      ),
    );
    if (!mounted) return;
    // The bon is finished — bubble the result up to the job order list
    // instead of staying here, so it can show its own confirmation and
    // mark this bon as completed.
    if (published == true) {
      Navigator.of(context).pop(true);
      return;
    }
    _loadHours();
  }

  void _showComingSoon(String feature) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Komt binnenkort'),
        content: Text('$feature is beschikbaar in een volgende versie.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final title = order.description.isNotEmpty
        ? order.description
        : order.orderNumber;
    return CupertinoPageScaffold(
      backgroundColor: AppColors.page,
      navigationBar: CupertinoNavigationBar(
        // De donkere hero loopt door tot achter de navbar.
        backgroundColor: _heroBg,
        // Standaard maakt Cupertino de navbar transparant zolang er nog
        // niets onder scrolt; hier moet hij altijd donker zijn.
        automaticBackgroundVisibility: false,
        border: null,
        padding: const EdgeInsetsDirectional.only(start: 4, end: 16),
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.white,
          previousPageTitle: 'Terug',
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: AnimatedOpacity(
          opacity: _showNavTitle ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: CupertinoColors.white,
            ),
          ),
        ),
        trailing: order.orderNumber.isNotEmpty
            ? Text(
                'Bon ${order.orderNumber}',
                style: const TextStyle(
                  fontSize: 13,
                  color: _heroMuted,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              )
            : null,
      ),
      child: Stack(
        children: [
          CustomScrollView(
            controller: _scrollCtrl,
            slivers: [
              // Het ruimtevak dat tijdens trekken en verversen verschijnt is
              // donker, zodat het naadloos in de hero overgaat.
              CupertinoSliverRefreshControl(
                onRefresh: _onRefresh,
                builder:
                    (
                      context,
                      refreshState,
                      pulledExtent,
                      refreshTriggerPullDistance,
                      refreshIndicatorExtent,
                    ) => ColoredBox(
                      color: _heroBg,
                      child: CupertinoTheme(
                        data: const CupertinoThemeData(
                          brightness: Brightness.dark,
                        ),
                        child: CupertinoSliverRefreshControl
                            .buildRefreshIndicator(
                          context,
                          refreshState,
                          pulledExtent,
                          refreshTriggerPullDistance,
                          refreshIndicatorExtent,
                        ),
                      ),
                    ),
              ),
              if (_loading)
                const SliverFillRemaining(
                  child: Center(child: CupertinoActivityIndicator()),
                )
              else if (_error != null)
                SliverFillRemaining(
                  child: _ErrorView(error: _error!, onRetry: _load),
                )
              else ...[
                // ── Hero (donker) ────────────────────────────────────────
                SliverToBoxAdapter(
                  child: _BonHero(
                    order: order,
                    title: title,
                    months: _months,
                  ),
                ),

                const SliverToBoxAdapter(child: SizedBox(height: 20)),

                // ── Waarschuwing ──────────────────────────────────────────
                if (_aantalOpenPick > 0 && !_partsConfirmed) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _WarningCard(
                        count: _aantalOpenPick,
                        onTap: () => _push(
                          PartsListScreen(order: order),
                          refreshParts: true,
                        ),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],

                // ── Taken ─────────────────────────────────────────────────
                SliverToBoxAdapter(child: _SectionLabel('Taken')),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _TaskGrid(
                      aantalOpenPick: _aantalOpenPick,
                      partsConfirmed: _partsConfirmed,
                      extraCount: _extraCount,
                      declaratieCount: _declaratieCount,
                      declaratieWacht: _declaratieWacht,
                      totalUrenGeregistreerd: _totalUrenGeregistreerd,
                      totalKm: _totalKm,
                      hasSignature: _signature != null,
                      isCompleted: _isCompleted,
                      onPick: () => _push(
                        PartsListScreen(order: order),
                        refreshParts: true,
                      ),
                      onUren: _openHoursWeek,
                      onExtra: () => _push(
                        UsedMaterialsScreen(order: order),
                        refreshParts: true,
                      ),
                      onDeclaraties: _openDeclaraties,
                      rapportStatus: _rapportStatus,
                      onRapport: () async {
                        await Navigator.of(context).push<void>(
                          CupertinoPageRoute<void>(
                            builder: (_) => WorkReportScreen(order: order),
                          ),
                        );
                        if (mounted) _loadRapportStatus();
                      },
                      onTekenen: _openSignaturePad,
                      onWerkAfronden: _openWorkCompletion,
                    ),
                  ),
                ),

                const SliverToBoxAdapter(child: SizedBox(height: 28)),

                // ── Klus ──────────────────────────────────────────────────
                SliverToBoxAdapter(child: _SectionLabel('Klus')),
                SliverToBoxAdapter(
                  child: _KlusTegels(
                    order: order,
                    monteurs: _monteurs,
                    bezig: _monteurBezig,
                    onToevoegen: _voegMonteurToe,
                  ),
                ),

                // ── Object ────────────────────────────────────────────────
                if (order.serviceObjectId != null) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  SliverToBoxAdapter(child: _SectionLabel('Object')),
                  SliverToBoxAdapter(
                    child: _ObjectSection(
                      order: order,
                      onShowComingSoon: _showComingSoon,
                    ),
                  ),
                ],

                // ── Adres & contact ───────────────────────────────────────
                if (order.location.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  SliverToBoxAdapter(child: _SectionLabel('Adres & contact')),
                  SliverToBoxAdapter(
                    child: _AdresKaart(
                      locationName: order.location,
                      address: _address != null ? _fmtAddr(_address!) : null,
                      contactName: _contactName,
                      contactPhone: _contactPhone,
                      kaart: _kaart,
                      onMaps: _openMaps,
                      onCall: _callContact,
                    ),
                  ),
                ],

                const SliverToBoxAdapter(child: SizedBox(height: 48)),
              ],
            ],
          ),
          // Banner die kort verschijnt na het opslaan van uren of handtekening
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutBack,
            top: _bannerText != null ? 12 : -80,
            left: 16,
            right: 16,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _bannerText != null ? 1 : 0,
              child: _SavedBanner(text: _bannerText ?? ''),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Saved banner ──────────────────────────────────────────────────────────────

class _SavedBanner extends StatelessWidget {
  final String text;
  const _SavedBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF34C759),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.checkmark_alt_circle_fill,
            size: 18,
            color: CupertinoColors.white,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.white,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Warning card ──────────────────────────────────────────────────────────────

class _WarningCard extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _WarningCard({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          color: const Color(0xFFFF9500),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 16,
              color: Color(0xFFFFFFFF),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Actie vereist voor vertrek',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFFFFFFF),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$count ${count == 1 ? 'artikel' : 'artikelen'} klaarzetten en bevestigen voordat je vertrekt.',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              CupertinoIcons.chevron_right,
              size: 14,
              color: Color(0xCCFFFFFF),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Task list ─────────────────────────────────────────────────────────────────

String _fmtUren(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// "Uren & km" subtitle, e.g. "6u · 120 km geregistreerd".
String _urenKmSubtitle(double uren, int km) {
  final parts = [if (uren > 0) '${_fmtUren(uren)}u', if (km > 0) '$km km'];
  return parts.isEmpty
      ? 'Nog niets geregistreerd'
      : '${parts.join(' · ')} geregistreerd';
}

/// Builds the seven [_TaskItem]s shown in [_TaskGrid].
List<_TaskItem> _buildTaskItems({
  required int aantalOpenPick,
  required bool partsConfirmed,
  required int extraCount,
  required int declaratieCount,
  required int declaratieWacht,
  required double totalUrenGeregistreerd,
  required int totalKm,
  required bool hasSignature,
  required bool isCompleted,
  required WorkReportStatus? rapportStatus,
  required VoidCallback onPick,
  required VoidCallback onUren,
  required VoidCallback onExtra,
  required VoidCallback onDeclaraties,
  required VoidCallback onRapport,
  required VoidCallback onTekenen,
  required VoidCallback onWerkAfronden,
}) => [
  _TaskItem(
    iconBg: const Color(0xFFFFF4E0),
    icon: CupertinoIcons.cube_box,
    iconColor: const Color(0xFFFF9500),
    title: 'Artikelen picken',
    subtitle: partsConfirmed
        ? 'Bevestigd'
        : aantalOpenPick > 0
        ? '$aantalOpenPick nog te bevestigen'
        : 'Alles bevestigd',
    badge: partsConfirmed ? null : (aantalOpenPick > 0 ? aantalOpenPick : null),
    done: partsConfirmed || aantalOpenPick == 0,
    locked: false,
    onTap: onPick,
  ),
  _TaskItem(
    iconBg: const Color(0xFFE6F9EC),
    icon: CupertinoIcons.timer,
    iconColor: const Color(0xFF34C759),
    title: 'Uren & km',
    subtitle: _urenKmSubtitle(totalUrenGeregistreerd, totalKm),
    done: totalUrenGeregistreerd > 0,
    locked: false,
    onTap: onUren,
  ),
  _TaskItem(
    iconBg: const Color(0xFFE3F0FF),
    icon: CupertinoIcons.add_circled,
    iconColor: const Color(0xFF007AFF),
    title: 'Gebruikt materiaal',
    subtitle: extraCount > 0
        ? '$extraCount ${extraCount == 1 ? 'artikel' : 'artikelen'} geregistreerd'
        : 'Nog niets geregistreerd',
    done: extraCount > 0,
    locked: false,
    onTap: onExtra,
  ),
  _TaskItem(
    iconBg: const Color(0xFFE0F6F9),
    icon: CupertinoIcons.doc_text,
    iconColor: const Color(0xFF30B0C7),
    title: 'Kosten & bonnen',
    subtitle: declaratieCount == 0
        ? 'Bonnetjes toevoegen'
        : '$declaratieCount ${declaratieCount == 1 ? 'declaratie' : 'declaraties'}'
              '${declaratieWacht > 0 ? ' · $declaratieWacht wacht op verzenden' : ''}',
    done: declaratieCount > 0 && declaratieWacht == 0,
    locked: false,
    onTap: onDeclaraties,
  ),
  _TaskItem(
    iconBg: const Color(0xFFEDE8F5),
    icon: CupertinoIcons.pencil_outline,
    iconColor: const Color(0xFF5856D6),
    title: 'Rapport schrijven',
    subtitle: rapportStatus == WorkReportStatus.saved
        ? 'Rapport opgeslagen'
        : rapportStatus == WorkReportStatus.draft
        ? 'Concept – nog niet afgerond'
        : 'Werkzaamheden en bevindingen noteren',
    done: rapportStatus == WorkReportStatus.saved,
    locked: false,
    onTap: onRapport,
  ),
  _TaskItem(
    iconBg: const Color(0xFFE6F9EC),
    icon: CupertinoIcons.signature,
    iconColor: const Color(0xFF34C759),
    title: 'Bezoekrapport tekenen',
    subtitle: isCompleted
        ? 'Getekend rapport bekijken'
        : hasSignature
        ? 'Getekend door de klant'
        : totalUrenGeregistreerd > 0
        ? 'Rapport doornemen en laten tekenen'
        : 'Beschikbaar zodra uren zijn ingevuld',
    done: hasSignature || isCompleted,
    locked: !isCompleted && totalUrenGeregistreerd == 0,
    onTap: isCompleted || totalUrenGeregistreerd > 0 ? onTekenen : null,
  ),
  _TaskItem(
    iconBg: const Color(0xFFFFE9DE),
    icon: CupertinoIcons.flag,
    iconColor: const Color(0xFFFF6B2B),
    title: 'Werk afronden',
    subtitle: isCompleted
        ? 'Gepubliceerd'
        : totalUrenGeregistreerd > 0 && hasSignature
        ? 'Bekijk de samenvatting en publiceer de uren'
        : 'Beschikbaar zodra uren en handtekening zijn ingevuld',
    done: isCompleted,
    locked: !isCompleted && (totalUrenGeregistreerd == 0 || !hasSignature),
    onTap: isCompleted || (totalUrenGeregistreerd > 0 && hasSignature)
        ? onWerkAfronden
        : null,
  ),
];

class _TaskGrid extends StatelessWidget {
  final int aantalOpenPick;
  final bool partsConfirmed;
  final int extraCount;
  final int declaratieCount;
  final int declaratieWacht;
  final double totalUrenGeregistreerd;
  final int totalKm;
  final bool hasSignature;
  final WorkReportStatus? rapportStatus;
  final bool isCompleted;
  final VoidCallback onPick;
  final VoidCallback onUren;
  final VoidCallback onExtra;
  final VoidCallback onDeclaraties;
  final VoidCallback onRapport;
  final VoidCallback onTekenen;
  final VoidCallback onWerkAfronden;

  const _TaskGrid({
    required this.aantalOpenPick,
    required this.partsConfirmed,
    required this.extraCount,
    required this.declaratieCount,
    required this.declaratieWacht,
    required this.totalUrenGeregistreerd,
    required this.totalKm,
    required this.hasSignature,
    this.rapportStatus,
    required this.isCompleted,
    required this.onPick,
    required this.onUren,
    required this.onExtra,
    required this.onDeclaraties,
    required this.onRapport,
    required this.onTekenen,
    required this.onWerkAfronden,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final bg = isDark
        ? const Color(0xFF1C1C1E)
        : CupertinoColors.systemBackground;
    final divider = isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);

    final items = _buildTaskItems(
      aantalOpenPick: aantalOpenPick,
      partsConfirmed: partsConfirmed,
      extraCount: extraCount,
      declaratieCount: declaratieCount,
      declaratieWacht: declaratieWacht,
      totalUrenGeregistreerd: totalUrenGeregistreerd,
      totalKm: totalKm,
      hasSignature: hasSignature,
      rapportStatus: rapportStatus,
      isCompleted: isCompleted,
      onPick: onPick,
      onUren: onUren,
      onExtra: onExtra,
      onDeclaraties: onDeclaraties,
      onRapport: onRapport,
      onTekenen: onTekenen,
      onWerkAfronden: onWerkAfronden,
    );

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: divider),
      ),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) Container(height: 0.5, color: divider),
            items[i],
          ],
        ],
      ),
    );
  }
}

// ─── Task item ─────────────────────────────────────────────────────────────────

class _TaskItem extends StatelessWidget {
  final Color iconBg;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final int? badge;
  final bool done;
  final bool locked;
  final VoidCallback? onTap;

  const _TaskItem({
    required this.iconBg,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.done,
    required this.locked,
    this.badge,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final lockedIconBg = isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFEEEEEE);

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              // The pastel [iconBg]s are light-mode only; on a dark card
              // they'd glow, so dark mode tints with [iconColor] instead.
              color: locked
                  ? lockedIconBg
                  : isDark
                  ? iconColor.withValues(alpha: 0.2)
                  : iconBg,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              icon,
              size: 18,
              color: locked ? const Color(0xFFAAAAAA) : iconColor,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: locked
                        ? CupertinoColors.secondaryLabel.resolveFrom(context)
                        : CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: locked
                        ? CupertinoColors.tertiaryLabel.resolveFrom(context)
                        : CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.elasticOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: badge != null
                ? Container(
                    key: const ValueKey('badge'),
                    constraints: const BoxConstraints(minWidth: 22),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF9500),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(
                      '$badge',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFFFFFF),
                      ),
                    ),
                  )
                : done
                ? Container(
                    key: const ValueKey('done'),
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: Color(0xFF34C759),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      CupertinoIcons.checkmark,
                      size: 11,
                      color: Color(0xFFFFFFFF),
                    ),
                  )
                : locked
                ? const Icon(
                    CupertinoIcons.lock,
                    key: ValueKey('locked'),
                    size: 14,
                    color: Color(0xFFAAAAAA),
                  )
                : Icon(
                    CupertinoIcons.chevron_right,
                    key: const ValueKey('chevron'),
                    size: 14,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
          ),
        ],
      ),
    );

    if (locked) return Opacity(opacity: 0.5, child: row);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: row,
    );
  }
}

// ─── Object section ──────────────────────────────────────────────────────────

/// The "Object" card on the bon detail screen — the service object (e.g. a
/// motor or ketel) linked to this klus. The header renders instantly from
/// data already present on [order] (no extra call); the rest of the card
/// (objectnr/serienr, locatie, garantie) comes from a single
/// `/service/serviceobjects/{id}` call fired in [initState], so it only
/// happens once this section is actually being rendered — not for every
/// order in a list. "Volgend onderhoud" and the document count are lazier
/// still: fetched after the first frame, so they never hold up this
/// section's own initial paint either.
class _ObjectSection extends StatefulWidget {
  final ServiceOrder order;
  final ValueChanged<String> onShowComingSoon;

  const _ObjectSection({
    required this.order,
    required this.onShowComingSoon,
  });

  @override
  State<_ObjectSection> createState() => _ObjectSectionState();
}

class _ObjectSectionState extends State<_ObjectSection> {
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

  Map<String, dynamic>? _detail;
  bool _detailLoading = true;

  List<Map<String, dynamic>>? _intervals;
  int? _documentCount;

  @override
  void initState() {
    super.initState();
    _loadDetail();
    // Deferred to after the first frame is painted, so these two calls
    // fire once this section is actually visible rather than as part of
    // the screen's initial load.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLazyExtras());
  }

  Future<void> _loadDetail() async {
    final detail = await PlanningRepository.instance.fetchServiceObject(
      widget.order.serviceObjectId!,
    );
    if (mounted) {
      setState(() {
        _detail = detail;
        _detailLoading = false;
      });
    }
  }

  Future<void> _loadLazyExtras() async {
    final id = widget.order.serviceObjectId!;
    final results = await Future.wait([
      PlanningRepository.instance.fetchServiceIntervals(id),
      PlanningRepository.instance.fetchServiceObjectDocumentCount(id),
    ]);
    if (!mounted) return;
    setState(() {
      _intervals = results[0] as List<Map<String, dynamic>>;
      _documentCount = results[1] as int?;
    });
  }

  String _fmtDate(DateTime? d) {
    if (d == null) return '—';
    return '${d.day} ${_months[d.month]} ${d.year}';
  }

  /// Tekst uit een Ridder-veld; leeg (null, "" of alleen spaties) → null.
  static String? _tekst(dynamic v) {
    final t = v?.toString().trim() ?? '';
    return t.isEmpty ? null : t;
  }

  /// Haalt HTML/RTF-opmaak uit een memo.
  static String? _schoneMemo(dynamic v) {
    var t = v?.toString() ?? '';
    if (t.trim().startsWith('{\\rtf')) {
      t = t
          .replaceAll(RegExp(r'\\par[d]?\b'), '\n')
          .replaceAll(RegExp(r"\\'[0-9a-fA-F]{2}"), '')
          .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), '')
          .replaceAll(RegExp(r'[{}]'), '');
    }
    t = t
        .replaceAll(RegExp(r'<br\s*/?>|</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return t.isEmpty ? null : t;
  }

  Widget _pill(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
    ),
  );

  Widget _scheiding(BuildContext context, double inspringing) => Container(
    height: 0.5,
    margin: EdgeInsets.only(left: inspringing),
    color: AppColors.border.resolveFrom(context),
  );

  /// Rij met het label boven de waarde.
  Widget _rijLabelBoven(
    BuildContext context, {
    required IconData icon,
    required String label,
    required InlineSpan waarde,
    VoidCallback? onTap,
  }) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: Icon(icon, size: 18, color: secundair),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 12, color: secundair)),
                  const SizedBox(height: 1),
                  Text.rich(
                    waarde,
                    style: TextStyle(
                      fontSize: 15,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(
                CupertinoIcons.chevron_right,
                size: 14,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
          ],
        ),
      ),
    );
  }

  /// Rij met het label links en de waarde rechts.
  Widget _rijWaardeRechts(
    BuildContext context, {
    required IconData icon,
    Color? iconKleur,
    required String label,
    required String waarde,
    Color? waardeKleur,
  }) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Icon(icon, size: 18, color: iconKleur ?? secundair),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 15, color: secundair),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              waarde,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 15,
                color: waardeKleur ?? CupertinoColors.label.resolveFrom(context),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final detail = _detail;
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final navy = AppColors.navy.resolveFrom(context);
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final label = CupertinoColors.label.resolveFrom(context);

    // ── Kop ────────────────────────────────────────────────────────────────
    final fallbackTitel = order.serviceObjectDescription.isNotEmpty
        ? order.serviceObjectDescription
        : order.serviceObjectTag;
    final title =
        _tekst(detail?['description']) ??
        _tekst(detail?['recordtag']) ??
        fallbackTitel;
    final subtitle = [
      _tekst(detail?['attribute01']),
      _tekst(detail?['objectnumber']),
    ].whereType<String>().join(' · ');

    final typeTekst = _tekst(
      (detail?['serviceobjecttype'] as Map<String, dynamic>?)?['description'],
    );
    final statusTekst = _tekst(
      (detail?['workflowstate'] as Map<String, dynamic>?)?['state'],
    );
    final actief =
        statusTekst != null &&
        statusTekst.toLowerCase().contains('actief') &&
        !statusTekst.toLowerCase().contains('inactief');
    final geblokkeerd = detail?['isblocked'] == true;

    const groenTekst = Color(0xFF248A3D);
    const rood = Color(0xFFD70015);
    final pills = <Widget>[
      if (typeTekst != null)
        _pill(
          typeTekst,
          isDark ? navy.withValues(alpha: 0.2) : const Color(0xFFE8EBF5),
          isDark ? navy : const Color(0xFF2C3E6B),
        ),
      if (statusTekst != null)
        actief
            ? _pill(
                statusTekst,
                isDark
                    ? const Color(0xFF34C759).withValues(alpha: 0.2)
                    : const Color(0xFFE6F9EC),
                isDark ? const Color(0xFF34C759) : groenTekst,
              )
            : _pill(statusTekst, AppColors.field.resolveFrom(context), secundair),
      if (geblokkeerd)
        _pill(
          'Geblokkeerd',
          isDark
              ? const Color(0xFFFF453A).withValues(alpha: 0.2)
              : const Color(0xFFFFE5E5),
          isDark ? const Color(0xFFFF453A) : rood,
        ),
    ];

    // ── Rijen (elke rij verdwijnt als het veld leeg is) ────────────────────
    final rijen = <Widget>[];

    final hoofd = detail?['mainserviceobject'] as Map<String, dynamic>?;
    final hoofdNaam =
        _tekst(hoofd?['description']) ?? _tekst(hoofd?['recordtag']);
    if (hoofdNaam != null) {
      final hoofdNr = _tekst(hoofd?['recordtag']);
      rijen.add(
        _rijLabelBoven(
          context,
          icon: CupertinoIcons.link,
          label: 'Onderdeel van',
          waarde: TextSpan(
            children: [
              TextSpan(text: hoofdNaam),
              if (hoofdNr != null && hoofdNr != hoofdNaam)
                TextSpan(
                  text: ' ($hoofdNr)',
                  style: TextStyle(color: secundair),
                ),
            ],
          ),
          onTap: () => widget.onShowComingSoon('Hoofdobject'),
        ),
      );
    }

    final objectRel = detail?['objectrelation'] as Map<String, dynamic>?;
    final objectRelNaam =
        _tekst(objectRel?['name']) ?? _tekst(objectRel?['recordtag']);
    if (objectRelNaam != null) {
      rijen.add(
        _rijLabelBoven(
          context,
          icon: CupertinoIcons.building_2_fill,
          label: 'Eigenaar',
          waarde: TextSpan(text: objectRelNaam),
        ),
      );
    }

    final orderRel = detail?['orderrelation'] as Map<String, dynamic>?;
    final orderRelNaam =
        _tekst(orderRel?['name']) ?? _tekst(orderRel?['recordtag']);
    if (orderRelNaam != null &&
        orderRel?['id']?.toString() != objectRel?['id']?.toString()) {
      rijen.add(
        _rijLabelBoven(
          context,
          icon: CupertinoIcons.building_2_fill,
          label: 'Orderrelatie',
          waarde: TextSpan(text: orderRelNaam),
        ),
      );
    }

    final serienummer = _tekst(detail?['serialnumber']);
    if (serienummer != null) {
      rijen.add(
        _rijWaardeRechts(
          context,
          icon: CupertinoIcons.number,
          label: 'Serienummer',
          waarde: serienummer,
        ),
      );
    }
    final geleverd = parseServiceApiDate(detail?['deliverydate']);
    if (geleverd != null) {
      rijen.add(
        _rijWaardeRechts(
          context,
          icon: CupertinoIcons.cube_box,
          label: 'Geleverd',
          waarde: _fmtDate(geleverd),
        ),
      );
    }
    final inGebruik = parseServiceApiDate(detail?['commissioningdate']);
    if (inGebruik != null) {
      rijen.add(
        _rijWaardeRechts(
          context,
          icon: CupertinoIcons.power,
          label: 'In gebruik',
          waarde: _fmtDate(inGebruik),
        ),
      );
    }
    final garantie =
        parseServiceApiDate(detail?['ourwarrantydate']) ??
        parseServiceApiDate(detail?['supplierwarrantydate']);
    if (garantie != null) {
      final verlopen = garantie.isBefore(DateTime.now());
      rijen.add(
        _rijWaardeRechts(
          context,
          icon: CupertinoIcons.checkmark_shield,
          iconKleur: verlopen ? secundair : const Color(0xFF34C759),
          label: 'Garantie',
          waarde: '${verlopen ? 'verlopen' : 'tot'} ${_fmtDate(garantie)}',
        ),
      );
    }
    final volgendOnderhoud = _intervals != null
        ? nextMaintenanceDateFrom(_intervals!)
        : null;
    if (volgendOnderhoud != null) {
      rijen.add(
        _rijWaardeRechts(
          context,
          icon: CupertinoIcons.wrench,
          label: 'Volgend onderhoud',
          waarde: _fmtDate(volgendOnderhoud),
        ),
      );
    }

    final memo = _schoneMemo(detail?['memo']);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      clipBehavior: Clip.antiAlias,
      decoration: _kaartDecoratie(context, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Kop
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isDark
                        ? navy.withValues(alpha: 0.2)
                        : const Color(0xFFE8EBF5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(CupertinoIcons.gear_alt, size: 22, color: navy),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: label,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: TextStyle(fontSize: 13, color: secundair),
                        ),
                      ],
                      if (pills.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 6, runSpacing: 6, children: pills),
                      ],
                    ],
                  ),
                ),
                if (_detailLoading) ...[
                  const SizedBox(width: 10),
                  const CupertinoActivityIndicator(radius: 8),
                ],
              ],
            ),
          ),
          for (var i = 0; i < rijen.length; i++) ...[
            _scheiding(context, i == 0 ? 14 : 44),
            rijen[i],
          ],
          if (memo != null)
            Container(
              margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFFFF9500).withValues(alpha: 0.2)
                    : const Color(0xFFFFF4E0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      CupertinoIcons.doc_text,
                      size: 16,
                      color: Color(0xFFFF9500),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      memo,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: isDark ? label : const Color(0xFF5C3B00),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Row(
              children: [
                Expanded(
                  child: _VlakKnop(
                    icon: CupertinoIcons.doc_on_doc,
                    label: _documentCount == null
                        ? 'Documenten'
                        : _documentCount == 1
                        ? '1 document'
                        : '$_documentCount documenten',
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => ServiceObjectDocumentsScreen(
                          serviceObjectId: widget.order.serviceObjectId!,
                          objectTitel: title,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _VlakKnop(
                    icon: CupertinoIcons.clock,
                    label: 'Historie',
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => ServiceObjectHistoryScreen(
                          serviceObjectId: widget.order.serviceObjectId!,
                          objectTitel: title,
                          huidigeBonId: widget.order.id,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Hero ──────────────────────────────────────────────────────────────────────

const _heroBg = Color(0xFF1C1C1E);

/// rgba(235,235,245,.6) — secundaire tekst op de donkere hero.
const _heroMuted = Color(0x99EBEBF5);

/// Kleur van een werkstroomstatus (Gepland, Nieuw, Uitvoering, Gereed).
Color _statusColor(String state) {
  final s = state.toLowerCase();
  if (s.contains('nieuw') || s.contains('new')) return const Color(0xFF64B5F6);
  if (s.contains('uitvoering') || s.contains('progress')) {
    return const Color(0xFFFFCC02);
  }
  if (s.contains('gereed') || s.contains('done') || s.contains('klaar')) {
    return const Color(0xFF4CD964);
  }
  if (s.contains('gepland') || s.contains('planned')) {
    return const Color(0xFFCFB0F5);
  }
  return const Color(0xFFCCCCCC);
}

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// De donkere kop van het bon detail scherm: status, titel, datumblok en
/// voortgang van de taken.
class _BonHero extends StatelessWidget {
  final ServiceOrder order;
  final String title;
  final List<String> months;

  const _BonHero({
    required this.order,
    required this.title,
    required this.months,
  });

  Widget _pill(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
    ),
  );

  static const _dagen = ['ma', 'di', 'wo', 'do', 'vr', 'za', 'zo'];

  static DateTime _dag(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Aantal kalenderdagen tussen twee datums (DST-veilig).
  static int _dagenTussen(DateTime van, DateTime tot) =>
      DateTime.utc(tot.year, tot.month, tot.day)
          .difference(DateTime.utc(van.year, van.month, van.day))
          .inDays;

  /// De datumregel van de hero: het bereik ("di 14 – do 16 okt") in wit en
  /// een grijs deel erachter ("· 3 dagen · dag 2").
  ({String bereik, String grijs}) _fmtRange() {
    final start = order.startDate;
    if (start == null) return (bereik: '', grijs: 'Geen datum gepland');

    String kort(DateTime d, {bool jaar = false}) =>
        '${_dagen[d.weekday - 1]} ${d.day} ${months[d.month]}'
        '${jaar ? ' ${d.year}' : ''}';

    final van = _dag(start);
    var tot = order.endTime != null ? _dag(order.endTime!) : van;
    if (tot.isBefore(van)) tot = van;

    // Tijden alleen als ze er echt zijn (00:00 betekent: geen tijd bekend).
    String? tijd;
    if (start.hour != 0 || start.minute != 0) {
      final end = order.endTime;
      tijd = end == null || (end.hour == 0 && end.minute == 0)
          ? _hhmm(start)
          : '${_hhmm(start)} – ${_hhmm(end)}';
    }

    if (tot == van) {
      return (bereik: kort(van), grijs: tijd == null ? '' : ' · $tijd');
    }

    final String bereik;
    if (van.year != tot.year) {
      bereik = '${kort(van, jaar: true)} – ${kort(tot, jaar: true)}';
    } else if (van.month != tot.month) {
      bereik = '${kort(van)} – ${kort(tot)}';
    } else {
      bereik =
          '${_dagen[van.weekday - 1]} ${van.day} – '
          '${_dagen[tot.weekday - 1]} ${tot.day} ${months[tot.month]}';
    }

    final aantal = _dagenTussen(van, tot) + 1;
    final vandaag = _dag(DateTime.now());
    var grijs = ' · $aantal dagen';
    if (!vandaag.isBefore(van) && !vandaag.isAfter(tot)) {
      grijs += ' · dag ${_dagenTussen(van, vandaag) + 1}';
    } else if (vandaag.isBefore(van)) {
      final x = _dagenTussen(vandaag, van);
      grijs += ' · over $x ${x == 1 ? 'dag' : 'dagen'}';
    }
    return (bereik: bereik, grijs: grijs);
  }

  @override
  Widget build(BuildContext context) {
    final status = order.workflowState;
    final statusKleur = _statusColor(status);
    final subtitle = [
      order.serviceObjectDescription.isNotEmpty
          ? order.serviceObjectDescription
          : order.serviceObjectTag,
      order.location,
    ].where((s) => s.isNotEmpty).join(' · ');
    final datum = _fmtRange();

    return Container(
      width: double.infinity,
      color: _heroBg,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (status.isNotEmpty)
                _pill(status, statusKleur.withValues(alpha: 0.2), statusKleur),
              if (order.serviceType.isNotEmpty)
                _pill(
                  order.serviceType,
                  const Color(0x1AFFFFFF),
                  const Color(0xD9EBEBF5),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              height: 1.1,
              letterSpacing: -0.5,
              color: CupertinoColors.white,
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 15, color: _heroMuted),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(
                  CupertinoIcons.calendar,
                  size: 16,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: 8),
              // Breekt op smalle schermen af in plaats van af te kappen.
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (datum.bereik.isNotEmpty)
                        TextSpan(
                          text: datum.bereik,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.white,
                          ),
                        ),
                      TextSpan(
                        text: datum.grijs,
                        style: const TextStyle(color: _heroMuted),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Klus ──────────────────────────────────────────────────────────────────────

/// Eerste letter van de eerste en de laatste naamdelen ("Wim Boekestijn" → WB).
String _initialen(String naam) {
  final delen = naam.trim().split(RegExp(r'\s+')).where((d) => d.isNotEmpty);
  if (delen.isEmpty) return '?';
  final eerste = delen.first[0];
  final laatste = delen.length > 1 ? delen.last[0] : '';
  return (eerste + laatste).toUpperCase();
}

/// Pastelkleurparen (achtergrond, tekst) voor avatars.
const _avatarKleuren = [
  (Color(0xFFFFE9DE), Color(0xFFFF6B2B)),
  (Color(0xFFE3F0FF), Color(0xFF007AFF)),
  (Color(0xFFE6F9EC), Color(0xFF248A3D)),
  (Color(0xFFEDE8F5), Color(0xFF5856D6)),
];

/// Ronde avatar met initialen. In dark mode wordt de accentkleur op 20%
/// gebruikt in plaats van de pastelkleur.
class _Avatar extends StatelessWidget {
  final String tekst;
  final Color bg;
  final Color fg;
  final double size;
  final double fontSize;
  final Color? ring;

  const _Avatar({
    required this.tekst,
    required this.bg,
    required this.fg,
    this.size = 32,
    this.fontSize = 12,
    this.ring,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isDark ? fg.withValues(alpha: 0.2) : bg,
        border: ring == null ? null : Border.all(color: ring!, width: 2),
      ),
      child: Text(
        tekst,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

/// Witte kaart met rand, voor tegels en de object-/adreskaart.
BoxDecoration _kaartDecoratie(BuildContext context, double radius) =>
    BoxDecoration(
      color: AppColors.card.resolveFrom(context),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: AppColors.border.resolveFrom(context)),
    );

class _Tegel extends StatelessWidget {
  final String label;
  final String value;
  final bool cijfers;

  const _Tegel({required this.label, required this.value, this.cijfers = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: _kaartDecoratie(context, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
              fontFeatures: cijfers
                  ? const [FontFeature.tabularFigures()]
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// De "Klus"-tegels: type service, ordernummer en de monteurs.
class _KlusTegels extends StatelessWidget {
  final ServiceOrder order;
  final List<ServicePerson> monteurs;
  final bool bezig;
  final VoidCallback onToevoegen;
  const _KlusTegels({
    required this.order,
    required this.monteurs,
    required this.bezig,
    required this.onToevoegen,
  });

  @override
  Widget build(BuildContext context) {
    final tegels = <Widget>[
      if (order.serviceType.isNotEmpty)
        _Tegel(label: 'Type service', value: order.serviceType),
      if (order.orderNumber.isNotEmpty)
        _Tegel(label: 'Ordernummer', value: order.orderNumber, cijfers: true),
    ];
    if (tegels.isEmpty && monteurs.isEmpty) return const SizedBox.shrink();

    final ring = AppColors.card.resolveFrom(context);
    final tonen = monteurs.take(4).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Een tegel die alleen op een rij staat pakt de volle breedte.
          if (tegels.length == 2)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: tegels[0]),
                  const SizedBox(width: 8),
                  Expanded(child: tegels[1]),
                ],
              ),
            )
          else if (tegels.length == 1)
            tegels[0],
          if (tegels.isNotEmpty && monteurs.isNotEmpty)
            const SizedBox(height: 8),
          if (monteurs.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: _kaartDecoratie(context, 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 32.0 + (tonen.length - 1) * 24,
                    height: 32,
                    child: Stack(
                      children: [
                        for (var i = 0; i < tonen.length; i++)
                          Positioned(
                            left: i * 24.0,
                            child: _Avatar(
                              tekst: _initialen(tonen[i].name),
                              bg: _avatarKleuren[i % _avatarKleuren.length].$1,
                              fg: _avatarKleuren[i % _avatarKleuren.length].$2,
                              ring: ring,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          monteurs.length > 1 ? 'Monteurs' : 'Monteur',
                          style: TextStyle(
                            fontSize: 12,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          monteurs.map((m) => m.name).join(', '),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.label.resolveFrom(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(36, 36),
                    onPressed: bezig ? null : onToevoegen,
                    child: bezig
                        ? const CupertinoActivityIndicator()
                        : Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.accent.withValues(alpha: 0.14),
                            ),
                            child: Icon(
                              CupertinoIcons.person_add,
                              size: 17,
                              color: AppColors.accent,
                            ),
                          ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Object: onderdelen ────────────────────────────────────────────────────────

/// Cel in het facts-grid van de objectkaart (Garantie, Volgend onderhoud...).
class _FeitCel extends StatelessWidget {
  final IconData icon;
  final Color? iconKleur;
  final String label;
  final String value;

  const _FeitCel({
    required this.icon,
    required this.label,
    required this.value,
    this.iconKleur,
  });

  @override
  Widget build(BuildContext context) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.field.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: iconKleur ?? secundair),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12, color: secundair),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// Knop met vlakke achtergrond en een donkerder "ingedrukt"-stand.
class _VlakKnop extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _VlakKnop({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_VlakKnop> createState() => _VlakKnopState();
}

class _VlakKnopState extends State<_VlakKnop> {
  bool _ingedrukt = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _ingedrukt = true),
      onTapUp: (_) => setState(() => _ingedrukt = false),
      onTapCancel: () => setState(() => _ingedrukt = false),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: _ingedrukt
              ? AppColors.border.resolveFrom(context)
              : AppColors.field.resolveFrom(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, size: 16, color: AppColors.navy.resolveFrom(context)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                widget.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Adres & contact ───────────────────────────────────────────────────────────

/// Ronde actieknop (36px) met een hit-area van 44px.
class _RondeKnop extends StatelessWidget {
  final Color kleur;
  final IconData icon;
  final VoidCallback onTap;

  const _RondeKnop({
    required this.kleur,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: kleur, shape: BoxShape.circle),
            child: Icon(icon, size: 16, color: CupertinoColors.white),
          ),
        ),
      ),
    );
  }
}

/// Getekend kaartje als plaatsaanduiding met een pin in het midden. Het is
/// bewust geen echte kaart: er zijn geen coördinaten van de bon, en een tik
/// opent toch de navigatie-app met het adres.
class _KaartPlaceholder extends StatelessWidget {
  final VoidCallback onTap;
  final Uint8List? image;
  const _KaartPlaceholder({required this.onTap, this.image});

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 110,
        width: double.infinity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: image != null
                  ? Image.memory(
                      image!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    )
                  : CustomPaint(painter: _KaartPainter(isDark: isDark)),
            ),
            if (image != null)
              Positioned(
                right: 6,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xB3FFFFFF),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text(
                    'Powered by Geoapify · © OpenStreetMap',
                    style: TextStyle(
                      fontSize: 9,
                      color: Color(0xFF3C3C43),
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0x40FF6B2B),
              ),
              alignment: Alignment.center,
              child: Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accent,
                ),
                child: const Icon(
                  CupertinoIcons.map_pin,
                  size: 16,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KaartPainter extends CustomPainter {
  final bool isDark;
  const _KaartPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final grond = Paint()
      ..color = isDark ? const Color(0xFF2A2E33) : const Color(0xFFE8EDF1);
    canvas.drawRect(Offset.zero & size, grond);

    final blok = Paint()
      ..color = isDark ? const Color(0xFF30363B) : const Color(0xFFDDE7DD);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.06, size.height * 0.12, size.width * 0.22, size.height * 0.34),
        const Radius.circular(6),
      ),
      blok,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.70, size.height * 0.58, size.width * 0.24, size.height * 0.30),
        const Radius.circular(6),
      ),
      blok,
    );

    final weg = Paint()
      ..color = isDark ? const Color(0xFF3A4046) : const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;
    weg.strokeWidth = 9;
    canvas.drawLine(
      Offset(0, size.height * 0.62),
      Offset(size.width, size.height * 0.40),
      weg,
    );
    weg.strokeWidth = 6;
    canvas.drawLine(
      Offset(size.width * 0.38, 0),
      Offset(size.width * 0.52, size.height),
      weg,
    );
    weg.strokeWidth = 4;
    canvas.drawLine(
      Offset(size.width * 0.05, size.height * 0.92),
      Offset(size.width * 0.62, size.height * 0.78),
      weg,
    );
  }

  @override
  bool shouldRepaint(_KaartPainter old) => old.isDark != isDark;
}

/// De "Adres & contact"-kaart: kaartje, adres met route-knop en het
/// contact met een belknop.
class _AdresKaart extends StatelessWidget {
  final String locationName;
  final String? address;
  final String? contactName;
  final String? contactPhone;
  final MapSnapshot? kaart;
  final VoidCallback onMaps;
  final VoidCallback onCall;

  const _AdresKaart({
    required this.locationName,
    required this.address,
    required this.contactName,
    required this.contactPhone,
    required this.kaart,
    required this.onMaps,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final label = CupertinoColors.label.resolveFrom(context);
    final rand = AppColors.border.resolveFrom(context);
    final heeftContact = contactName != null || contactPhone != null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      clipBehavior: Clip.antiAlias,
      decoration: _kaartDecoratie(context, 16),
      child: Column(
        children: [
          _KaartPlaceholder(onTap: onMaps, image: kaart?.image),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          locationName,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: label,
                          ),
                        ),
                        if (address != null && address!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            address!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: secundair),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                _RondeKnop(
                  kleur: AppColors.accent,
                  icon: CupertinoIcons.location_fill,
                  onTap: onMaps,
                ),
              ],
            ),
          ),
          if (heeftContact) ...[
            Container(
              height: 0.5,
              margin: const EdgeInsets.symmetric(horizontal: 14),
              color: rand,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
              child: Row(
                children: [
                  _Avatar(
                    tekst: contactName != null ? _initialen(contactName!) : '#',
                    bg: const Color(0xFFE6F9EC),
                    fg: const Color(0xFF248A3D),
                    size: 36,
                    fontSize: 13,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            contactName ?? contactPhone!,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: label,
                            ),
                          ),
                          if (contactName != null && contactPhone != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              contactPhone!,
                              style: TextStyle(fontSize: 13, color: secundair),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (contactPhone != null)
                    _RondeKnop(
                      kleur: const Color(0xFF34C759),
                      icon: CupertinoIcons.phone_fill,
                      onTap: onCall,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String title;
  const _SectionLabel(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
    );
  }
}

// ─── Error view ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 44,
              color: CupertinoColors.systemRed.resolveFrom(context),
            ),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            CupertinoButton(
              onPressed: onRetry,
              child: const Text('Opnieuw proberen'),
            ),
          ],
        ),
      ),
    );
  }
}
