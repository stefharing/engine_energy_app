import 'package:flutter/cupertino.dart';

import '../data/planning_repository.dart';

class RelationDetailScreen extends StatefulWidget {
  final String productionOrderId;

  const RelationDetailScreen({super.key, required this.productionOrderId});

  @override
  State<RelationDetailScreen> createState() => _RelationDetailScreenState();
}

class _RelationDetailScreenState extends State<RelationDetailScreen> {
  Map<String, dynamic>? _relation;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final order = await PlanningRepository.instance
          .fetchProductionOrder(widget.productionOrderId);
      final relationId =
          (order?['relation'] as Map<String, dynamic>?)?['id']?.toString();
      if (relationId == null) throw Exception('Geen klant gevonden');
      final relation =
          await PlanningRepository.instance.fetchRelation(relationId);
      setState(() { _relation = relation; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor =
        isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
    final sectionBg =
        isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9);
    final name = _relation?['name']?.toString() ?? 'Klant';

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.white,
        border: null,
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.black,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: Text(
          _loading ? 'Klant' : name,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: CupertinoColors.black,
          ),
        ),
      ),
      child: SafeArea(
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : _error != null
                ? _buildError()
                : _buildContent(sectionBg, borderColor),
      ),
    );
  }

  Widget _buildError() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(CupertinoIcons.exclamationmark_circle,
                  size: 40, color: CupertinoColors.destructiveRed),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              CupertinoButton.filled(
                  onPressed: _load, child: const Text('Opnieuw')),
            ],
          ),
        ),
      );

  Widget _buildContent(Color bg, Color border) {
    final r = _relation!;
    String str(String k) => r[k]?.toString() ?? '';

    final address = (r['visitingaddress']
            as Map<String, dynamic>?)?['recordtag']
        ?.toString() ?? '';

    final rows = <_InfoRow>[];
    final name = str('name');
    final code = str('code');
    final phone = str('phone1');
    final phone2 = str('phone2');
    final email = str('email');
    final website = str('website');
    final vat = str('vatnumber');
    final coc = str('cocnumber');
    final debtorNr = (r['debtor'] as Map<String, dynamic>?)?['debtornumber']
        ?.toString() ?? '';

    if (name.isNotEmpty)
      rows.add(_InfoRow(
          icon: CupertinoIcons.building_2_fill, label: 'Naam', value: name));
    if (code.isNotEmpty)
      rows.add(_InfoRow(
          icon: CupertinoIcons.number, label: 'Relatienummer', value: code));
    if (debtorNr.isNotEmpty)
      rows.add(_InfoRow(
          icon: CupertinoIcons.doc_text, label: 'Debiteurnummer', value: debtorNr));

    final contactRows = <_InfoRow>[];
    if (phone.isNotEmpty)
      contactRows.add(_InfoRow(
          icon: CupertinoIcons.phone, label: 'Telefoon', value: phone));
    if (phone2.isNotEmpty)
      contactRows.add(_InfoRow(
          icon: CupertinoIcons.phone, label: 'Telefoon 2', value: phone2));
    if (email.isNotEmpty)
      contactRows.add(_InfoRow(
          icon: CupertinoIcons.mail, label: 'E-mail', value: email));
    if (website.isNotEmpty)
      contactRows.add(_InfoRow(
          icon: CupertinoIcons.globe, label: 'Website', value: website));

    final addressRows = <_InfoRow>[];
    if (address.isNotEmpty)
      addressRows.add(_InfoRow(
          icon: CupertinoIcons.map_pin, label: 'Adres', value: address));

    final legalRows = <_InfoRow>[];
    if (vat.isNotEmpty)
      legalRows.add(_InfoRow(
          icon: CupertinoIcons.doc, label: 'BTW-nummer', value: vat));
    if (coc.isNotEmpty)
      legalRows.add(_InfoRow(
          icon: CupertinoIcons.doc, label: 'KvK-nummer', value: coc));

    return ListView(
      padding: const EdgeInsets.only(top: 24, bottom: 40),
      children: [
        if (rows.isNotEmpty) ...[
          _SectionBlock(title: 'Relatie', rows: rows, bg: bg, border: border),
          const SizedBox(height: 20),
        ],
        if (contactRows.isNotEmpty) ...[
          _SectionBlock(title: 'Contact', rows: contactRows, bg: bg, border: border),
          const SizedBox(height: 20),
        ],
        if (addressRows.isNotEmpty) ...[
          _SectionBlock(title: 'Adres', rows: addressRows, bg: bg, border: border),
          const SizedBox(height: 20),
        ],
        if (legalRows.isNotEmpty)
          _SectionBlock(title: 'Juridisch', rows: legalRows, bg: bg, border: border),
      ],
    );
  }
}

// ─── Shared widgets ────────────────────────────────────────────────────────────

class _SectionBlock extends StatelessWidget {
  final String title;
  final List<_InfoRow> rows;
  final Color bg;
  final Color border;

  const _SectionBlock({
    required this.title,
    required this.rows,
    required this.bg,
    required this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
              letterSpacing: 0.5,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              top: BorderSide(color: border),
              bottom: BorderSide(color: border),
            ),
          ),
          child: Column(
            children: [
              for (int i = 0; i < rows.length; i++) ...[
                rows[i],
                if (i < rows.length - 1)
                  Padding(
                    padding: const EdgeInsets.only(left: 56),
                    child: Container(height: 0.5, color: border),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      child: Row(
        children: [
          Icon(icon, size: 18, color: CupertinoColors.secondaryLabel.resolveFrom(context)),
          const SizedBox(width: 14),
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: isDark
                    ? CupertinoColors.label.resolveFrom(context)
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.label.resolveFrom(context),
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
