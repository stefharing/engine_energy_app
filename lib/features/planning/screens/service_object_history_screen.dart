import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../core/theme/app_colors.dart';
import '../data/planning_repository.dart';

/// Historie van een serviceobject als verticale tijdlijn: links de datum,
/// in het midden een lijn met een stip per dag, rechts compacte kaarten per
/// bon. Een tik klapt een bon open (opdracht → oplossing, notitie, onderdelen
/// en uren; die laatste twee worden pas dan opgehaald).
class ServiceObjectHistoryScreen extends StatefulWidget {
  final String serviceObjectId;
  final String objectTitel;

  /// De bon vanwaar we komen; die laten we buiten de lijst.
  final String huidigeBonId;

  const ServiceObjectHistoryScreen({
    super.key,
    required this.serviceObjectId,
    required this.objectTitel,
    required this.huidigeBonId,
  });

  @override
  State<ServiceObjectHistoryScreen> createState() =>
      _ServiceObjectHistoryScreenState();
}

class _Detail {
  List<Map<String, dynamic>>? uren;
  List<Map<String, dynamic>>? onderdelen;
  bool fout = false;
}

const _navy = Color(0xFF2C3E6B);
const _storing = Color(0xFFD70015);
const _succes = Color(0xFF34C759);
const _lijnKleur = CupertinoDynamicColor.withBrightness(
  color: Color(0xFFD1D1D6),
  darkColor: Color(0xFF38383A),
);

class _ServiceObjectHistoryScreenState
    extends State<ServiceObjectHistoryScreen> {
  static const _maanden = [
    '', 'JAN', 'FEB', 'MRT', 'APR', 'MEI', 'JUN',
    'JUL', 'AUG', 'SEP', 'OKT', 'NOV', 'DEC',
  ];

  List<Map<String, dynamic>>? _bonnen;
  bool _laden = true;
  bool _fout = false;
  String? _typeFilter; // null = alle
  final Set<String> _open = {};
  final Map<String, _Detail> _details = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool stil = false}) async {
    if (!stil) setState(() => _laden = true);
    try {
      final lijst = await PlanningRepository.instance
          .fetchServiceObjectHistory(widget.serviceObjectId);
      if (!mounted) return;
      setState(() {
        _bonnen = lijst
            .where((b) => b['id']?.toString() != widget.huidigeBonId)
            .toList();
        _fout = false;
        _laden = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _fout = _bonnen == null;
        _laden = false;
      });
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  static String? _t(dynamic v) {
    final t = v?.toString().trim() ?? '';
    return t.isEmpty ? null : t;
  }

  /// Tekstveld uit Ridder: HTML eruit; leeg, "0" en "0.0" tellen als leeg.
  static String? _tekst(dynamic v) {
    final t = (v?.toString() ?? '')
        .replaceAll(RegExp(r'<br\s*/?>|</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'[ \t]*\r?\n[ \t]*(\r?\n[ \t]*)+'), '\n')
        .trim();
    if (t.isEmpty || t == '0' || t == '0.0' || t == '0,0') return null;
    return t;
  }

  static DateTime? _dt(dynamic v) => v == null ? null : DateTime.tryParse('$v');

  static String? _bonType(Map<String, dynamic> b) =>
      _t((b['servicetype'] as Map<String, dynamic>?)?['description']);

  /// "Aangenomen werk" → "Werk"; andere types blijven zoals ze zijn.
  static String _kort(String type) =>
      type.toLowerCase().contains('aangenomen') ? 'Werk' : type;

  static bool _isStoring(String? type) =>
      type != null && type.toLowerCase().contains('storing');

  static DateTime? _dag(Map<String, dynamic> b) {
    final d = _dt(b['startdate']) ?? _dt(b['dateproductionfinished']);
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  static int _minuten(dynamic v) {
    final delen = '${v ?? ''}'.split(':');
    if (delen.length < 2) return 0;
    return (int.tryParse(delen[0]) ?? 0) * 60 + (int.tryParse(delen[1]) ?? 0);
  }

  static String _urenTekst(int min) {
    final u = min / 60;
    final s = u % 1 == 0 ? u.toInt().toString() : u.toStringAsFixed(1).replaceAll('.', ',');
    return '$s uur';
  }

  static String _aantal(num n) =>
      n % 1 == 0 ? n.toInt().toString() : n.toString().replaceAll('.', ',');

  /// (achtergrond licht, tekst licht, kleur voor dark mode)
  (Color, Color, Color) _statusKleuren(String state) {
    final s = state.toLowerCase();
    if (s.contains('gepland')) {
      return (const Color(0xFFF1E9FD), const Color(0xFF7A4FC4), const Color(0xFFCFB0F5));
    }
    if (s.contains('nieuw')) {
      return (const Color(0xFFE3F0FF), const Color(0xFF1565C0), const Color(0xFF64B5F6));
    }
    if (s.contains('uitvoering')) {
      return (const Color(0xFFFFF6D6), const Color(0xFF8A6D00), const Color(0xFFFFCC02));
    }
    if (s.contains('gereed')) {
      return (const Color(0xFFE6F9EC), const Color(0xFF248A3D), const Color(0xFF4CD964));
    }
    return (const Color(0xFFF2F2F7), const Color(0x993C3C43), const Color(0x99EBEBF5));
  }

  Future<void> _wissel(Map<String, dynamic> b) async {
    final id = b['id'].toString();
    if (_open.contains(id)) {
      setState(() => _open.remove(id));
      return;
    }
    setState(() => _open.add(id));
    if (_details[id] != null && !_details[id]!.fout) return;
    final det = _Detail();
    _details[id] = det;
    try {
      final r = await Future.wait([
        PlanningRepository.instance.fetchJobOrderHours(id),
        PlanningRepository.instance.fetchJobOrderParts(id),
      ]);
      det.uren = r[0];
      det.onderdelen = r[1];
    } catch (_) {
      det.fout = true; // opnieuw proberen bij de volgende keer uitklappen
    }
    if (mounted) setState(() {});
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final bonnen = _bonnen;

    return CupertinoPageScaffold(
      backgroundColor: AppColors.page.resolveFrom(context),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        previousPageTitle: 'Terug',
        middle: Text(
          'Historie',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.navForeground.resolveFrom(context),
          ),
        ),
      ),
      child: SafeArea(
        child: _laden && bonnen == null
            ? const Center(child: CupertinoActivityIndicator())
            : _fout
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Historie laden mislukt',
                      style: TextStyle(fontSize: 15, color: secundair),
                    ),
                    CupertinoButton(
                      onPressed: _load,
                      child: const Text('Opnieuw proberen'),
                    ),
                  ],
                ),
              )
            : (bonnen == null || bonnen.isEmpty)
            ? Center(
                child: Text(
                  'Nog geen historie voor dit object',
                  style: TextStyle(fontSize: 15, color: secundair),
                ),
              )
            : _inhoud(bonnen),
      ),
    );
  }

  Widget _inhoud(List<Map<String, dynamic>> bonnen) {
    // Tellingen per type (volgorde van eerste voorkomen).
    final tellingen = <String, int>{};
    for (final b in bonnen) {
      final t = _bonType(b);
      if (t != null) tellingen[t] = (tellingen[t] ?? 0) + 1;
    }
    final zichtbaar = bonnen
        .where((b) => _typeFilter == null || _bonType(b) == _typeFilter)
        .toList();

    // Groeperen per kalenderdag, nieuwste bovenaan.
    final perDag = <DateTime?, List<Map<String, dynamic>>>{};
    for (final b in zichtbaar) {
      perDag.putIfAbsent(_dag(b), () => []).add(b);
    }
    final dagen = perDag.entries.toList()
      ..sort((a, b) {
        if (a.key == null) return 1;
        if (b.key == null) return -1;
        return b.key!.compareTo(a.key!);
      });

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        CupertinoSliverRefreshControl(onRefresh: () => _load(stil: true)),
        SliverToBoxAdapter(child: _filterRij(bonnen.length, tellingen)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
          sliver: SliverList.builder(
            itemCount: dagen.length,
            itemBuilder: (_, i) => _dagRij(
              dagen[i].key,
              dagen[i].value,
              laatste: i == dagen.length - 1,
            ),
          ),
        ),
      ],
    );
  }

  // ── Filter ─────────────────────────────────────────────────────────────

  Widget _filterRij(int totaal, Map<String, int> tellingen) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);

    Widget pill(String tekst, bool actief, VoidCallback onTap) => GestureDetector(
      onTap: actief ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: actief ? AppColors.accent : AppColors.card.resolveFrom(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: actief ? AppColors.accent : AppColors.border.resolveFrom(context),
          ),
        ),
        child: Text(
          tekst,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: actief
                ? CupertinoColors.white
                : CupertinoColors.label.resolveFrom(context),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.objectTitel.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: secundair,
              ),
            ),
          ),
          const SizedBox(width: 8),
          pill('Alle $totaal', _typeFilter == null, () {
            setState(() => _typeFilter = null);
          }),
          for (final e in tellingen.entries) ...[
            const SizedBox(width: 8),
            pill(
              '${_kort(e.key)} ${e.value}',
              _typeFilter == e.key,
              () => setState(() => _typeFilter = e.key),
            ),
          ],
        ],
      ),
    );
  }

  // ── Tijdlijn ───────────────────────────────────────────────────────────

  Widget _dagRij(
    DateTime? dag,
    List<Map<String, dynamic>> bonnen, {
    required bool laatste,
  }) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final pagina = AppColors.page.resolveFrom(context);
    final lijn = _lijnKleur.resolveFrom(context);

    // Stipkleur: storing gaat voor, anders die van de eerste bon.
    final heeftStoring = bonnen.any((b) => _isStoring(_bonType(b)));
    final stip = heeftStoring ? _storing : _navy;

    final jaar = dag != null && dag.year != DateTime.now().year;

    return Padding(
      padding: EdgeInsets.only(bottom: laatste ? 0 : 14),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 44,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      dag == null ? '–' : '${dag.day}',
                      style: TextStyle(
                        fontSize: 18,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                    if (dag != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        _maanden[dag.month],
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: secundair,
                        ),
                      ),
                      if (jaar)
                        Text(
                          '${dag.year}',
                          style: TextStyle(fontSize: 11, color: secundair),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 18,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.topCenter,
                children: [
                  Positioned(
                    top: 0,
                    bottom: laatste ? null : -14, // door de ruimte tussen dagen
                    height: laatste ? 14 : null,
                    child: Container(width: 2, color: lijn),
                  ),
                  Positioned(
                    top: 14,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: stip,
                        shape: BoxShape.circle,
                        border: Border.all(color: pagina, width: 3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < bonnen.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    _bonKaart(bonnen[i]),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Kaart ──────────────────────────────────────────────────────────────

  Widget _statusPill(String state) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final (bg, tekst, donker) = _statusKleuren(state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? donker.withValues(alpha: 0.2) : bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        state,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isDark ? donker : tekst,
        ),
      ),
    );
  }

  Widget _bonKaart(Map<String, dynamic> b) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final label = CupertinoColors.label.resolveFrom(context);
    final id = b['id'].toString();
    final open = _open.contains(id);
    final nummer = _t(b['recordtag']) ?? _t(b['jobordernumber']) ?? '';
    final omschrijving = _t(b['description']);
    final type = _bonType(b);
    final status = _t((b['workflowstate'] as Map<String, dynamic>?)?['state']);
    final monteur = _t((b['servicemechanic'] as Map<String, dynamic>?)?['recordtag']);
    final sub = [nummer, monteur].where((x) => x != null && x.isNotEmpty).join(' · ');

    return GestureDetector(
      onTap: () => _wissel(b),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: open ? 10 : 9),
        decoration: BoxDecoration(
          color: AppColors.card.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
        ),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (omschrijving != null)
                          Text(
                            omschrijving,
                            maxLines: open ? null : 2,
                            overflow: open ? null : TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: label,
                            ),
                          )
                        else
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: type ?? 'Bon',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: label,
                                  ),
                                ),
                                if (nummer.isNotEmpty)
                                  TextSpan(
                                    text: '  $nummer',
                                    style: TextStyle(fontSize: 12, color: secundair),
                                  ),
                              ],
                            ),
                          ),
                        if (sub.isNotEmpty && omschrijving != null) ...[
                          const SizedBox(height: 1),
                          Text(
                            sub,
                            style: TextStyle(fontSize: 12, color: secundair),
                          ),
                        ] else if (omschrijving == null && monteur != null) ...[
                          const SizedBox(height: 1),
                          Text(
                            monteur,
                            style: TextStyle(fontSize: 12, color: secundair),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (status != null) ...[
                    const SizedBox(width: 8),
                    _statusPill(status),
                  ],
                ],
              ),
              if (open) _uitgeklapt(b, storing: _isStoring(type)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _uitgeklapt(Map<String, dynamic> b, {required bool storing}) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final label = CupertinoColors.label.resolveFrom(context);
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final id = b['id'].toString();
    final det = _details[id];

    final opdracht = _tekst(b['memo']);
    final oplossing = _tekst(b['possiblesolution']);
    final resultaat = _tekst(b['productionresult']);
    final intern = _tekst(b['internalmemo']);
    final accent = storing ? _storing : _navy;

    Widget bolletje(Widget stip, String tekst) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 14,
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Align(alignment: Alignment.topLeft, child: stip),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tekst,
              style: TextStyle(fontSize: 14, height: 1.35, color: label),
            ),
          ),
        ],
      ),
    );

    final ring = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: accent, width: 2),
      ),
    );
    Widget vol(Color c) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (opdracht != null || oplossing != null || resultaat != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              children: [
                if (opdracht != null) bolletje(ring, opdracht),
                if (oplossing != null) bolletje(vol(_succes), oplossing),
                if (resultaat != null) bolletje(vol(secundair), resultaat),
              ],
            ),
          ),
        if (intern != null)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFFFF9500).withValues(alpha: 0.15)
                  : const Color(0xFFFFF4E0),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(
                    CupertinoIcons.doc_text,
                    size: 14,
                    color: Color(0xFFFF9500),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    intern,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? const Color(0xFFFFD59A)
                          : const Color(0xFF5C3B00),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: AppColors.border.resolveFrom(context),
                width: 0.5,
              ),
            ),
          ),
          child: (det == null || (det.uren == null && !det.fout))
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Center(child: CupertinoActivityIndicator(radius: 8)),
                )
              : det.fout
              ? Text(
                  'Onderdelen en uren laden mislukt. Klap de bon in en weer uit om het opnieuw te proberen.',
                  style: TextStyle(fontSize: 12, color: secundair),
                )
              : _onderdelenEnUren(det),
        ),
      ],
    );
  }

  Widget _onderdelenEnUren(_Detail det) {
    final secundair = CupertinoColors.secondaryLabel.resolveFrom(context);
    final label = CupertinoColors.label.resolveFrom(context);
    final uren = det.uren ?? const <Map<String, dynamic>>[];
    final regels = det.onderdelen ?? const <Map<String, dynamic>>[];

    var km = 0.0;
    final onderdelen = <Widget>[];
    for (final d in regels) {
      final item = d['item'] as Map<String, dynamic>?;
      final tag = _t((d['joborderdetailitem'] as Map<String, dynamic>?)?['recordtag']) ?? '';
      // "200040.1 CA130180" → "CA130180" (bonnummer eraf).
      final code = tag.contains(' ') ? tag.substring(tag.indexOf(' ') + 1) : tag;
      final aantal = d['quantity'] is num ? d['quantity'] as num : 0;
      if (code.toUpperCase() == 'KM') {
        km += aantal.toDouble();
        continue;
      }
      final naam = _t(item?['description']) ?? _t(item?['recordtag']) ?? code;
      onderdelen.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: naam),
                      if (code.isNotEmpty && code != naam)
                        TextSpan(
                          text: '  $code',
                          style: TextStyle(color: secundair),
                        ),
                    ],
                  ),
                  style: TextStyle(fontSize: 13, color: label),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_aantal(aantal)}×',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: label,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final minuten = uren.fold<int>(0, (s, u) => s + _minuten(u['timeemployee']));
    final namen = <String>{
      for (final u in uren)
        if (_t((u['employee'] as Map<String, dynamic>?)?['recordtag']) != null)
          _t((u['employee'] as Map<String, dynamic>)['recordtag'])!,
    };
    final urenRegel = [
      if (minuten > 0) [_urenTekst(minuten), if (namen.isNotEmpty) namen.join(', ')].join(' · '),
      if (minuten == 0) 'Geen uren geregistreerd',
      if (km > 0) '${_aantal(km)} km',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...onderdelen,
        Padding(
          padding: EdgeInsets.only(top: onderdelen.isEmpty ? 0 : 2),
          child: Text(
            urenRegel,
            style: TextStyle(fontSize: 12, color: secundair),
          ),
        ),
      ],
    );
  }
}
