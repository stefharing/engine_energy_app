import 'package:flutter/cupertino.dart';
import '../data/planning_repository.dart';

class ServiceObjectDetailScreen extends StatefulWidget {
  final String serviceObjectId;
  final String name;

  const ServiceObjectDetailScreen({
    super.key,
    required this.serviceObjectId,
    required this.name,
  });

  @override
  State<ServiceObjectDetailScreen> createState() =>
      _ServiceObjectDetailScreenState();
}

class _ServiceObjectDetailScreenState extends State<ServiceObjectDetailScreen> {
  Map<String, dynamic>? _object;
  Map<String, dynamic>? _address;
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
      final data = await PlanningRepository.instance.fetchServiceObject(
        widget.serviceObjectId,
      );
      if (data == null) throw Exception('Service object niet gevonden');
      setState(() {
        _object = data;
        _loading = false;
      });
      _loadAddress(data);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadAddress(Map<String, dynamic> objectData) async {
    // Prefer objectlocation address (delivery address) over relation address
    final locationId =
        (objectData['objectlocation'] as Map<String, dynamic>?)?['id']
            ?.toString();

    if (locationId != null) {
      final deliveryAddress = await PlanningRepository.instance
          .fetchDeliveryAddress(locationId);
      final addressId =
          (deliveryAddress?['address'] as Map<String, dynamic>?)?['id']
              ?.toString();
      if (addressId != null) {
        final address = await PlanningRepository.instance.fetchAddress(
          addressId,
        );
        if (address != null && mounted) {
          setState(() => _address = address);
          return;
        }
      }
    }

    // Fallback: visiting address of the relation
    final relationId =
        (objectData['objectrelation'] as Map<String, dynamic>?)?['id']
            ?.toString();
    if (relationId == null) return;

    final relation = await PlanningRepository.instance.fetchRelation(
      relationId,
    );
    final addressId =
        (relation?['visitingaddress'] as Map<String, dynamic>?)?['id']
            ?.toString();
    if (addressId == null) return;

    final address = await PlanningRepository.instance.fetchAddress(addressId);
    if (address != null && mounted) {
      setState(() => _address = address);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final sectionBg = isDark
        ? const Color(0xFF1C1C1E)
        : const Color(0xFFF9F9F9);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.white,
        border: null,
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.black,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: Text(
          widget.name.isNotEmpty ? widget.name : 'Service object',
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
          const Icon(
            CupertinoIcons.exclamationmark_circle,
            size: 40,
            color: CupertinoColors.destructiveRed,
          ),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          CupertinoButton.filled(
            onPressed: _load,
            child: const Text('Opnieuw'),
          ),
        ],
      ),
    ),
  );

  Widget _buildContent(Color bg, Color border) {
    final o = _object!;
    String str(String k) => o[k]?.toString() ?? '';

    final objectNumber = str('objectnumber');
    final description = str('description');
    final serialNumber = str('serialnumber');
    final memo = str('memo');
    final typeName =
        (o['serviceobjecttype'] as Map<String, dynamic>?)?['description']
            ?.toString() ??
        '';
    final state =
        (o['workflowstate'] as Map<String, dynamic>?)?['state']?.toString() ??
        '';
    final location =
        (o['objectlocation'] as Map<String, dynamic>?)?['name']?.toString() ??
        '';
    final relationName =
        (o['objectrelation'] as Map<String, dynamic>?)?['name']?.toString() ??
        '';
    final commDate = o['commissioningdate'] != null
        ? DateTime.tryParse(o['commissioningdate'].toString())
        : null;
    final buildDate = o['builddate'] != null
        ? DateTime.tryParse(o['builddate'].toString())
        : null;

    String fmt(DateTime? d) {
      if (d == null) return '—';
      const months = [
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
      return '${d.day} ${months[d.month]} ${d.year}';
    }

    // Object info
    final objectRows = <_InfoRow>[];
    if (objectNumber.isNotEmpty) {
      objectRows.add(
        _InfoRow(
          icon: CupertinoIcons.tag,
          label: 'Objectnummer',
          value: objectNumber,
        ),
      );
    }
    if (typeName.isNotEmpty) {
      objectRows.add(
        _InfoRow(icon: CupertinoIcons.cube_box, label: 'Type', value: typeName),
      );
    }
    if (state.isNotEmpty) {
      objectRows.add(
        _InfoRow(
          icon: CupertinoIcons.checkmark_circle,
          label: 'Status',
          value: state,
        ),
      );
    }
    if (serialNumber.isNotEmpty) {
      objectRows.add(
        _InfoRow(
          icon: CupertinoIcons.barcode,
          label: 'Serienummer',
          value: serialNumber,
        ),
      );
    }
    if (description.isNotEmpty && description != '-') {
      objectRows.add(
        _InfoRow(
          icon: CupertinoIcons.text_alignleft,
          label: 'Omschrijving',
          value: description,
        ),
      );
    }

    // Location / relation
    final locationRows = <_InfoRow>[];
    if (relationName.isNotEmpty) {
      locationRows.add(
        _InfoRow(
          icon: CupertinoIcons.building_2_fill,
          label: 'Klant',
          value: relationName,
        ),
      );
    }
    if (location.isNotEmpty) {
      locationRows.add(
        _InfoRow(
          icon: CupertinoIcons.map_pin,
          label: 'Locatie',
          value: location,
        ),
      );
    }

    if (_address != null) {
      final street = _address!['street']?.toString() ?? '';
      final nr = _address!['housenumber']?.toString() ?? '';
      final addition = _address!['additionhousenumber']?.toString() ?? '';
      final zip = _address!['zipcode']?.toString() ?? '';
      final city = _address!['city']?.toString() ?? '';

      final streetLine = [
        street,
        nr,
        addition,
      ].where((s) => s.isNotEmpty && s != '0').join(' ');
      final cityLine = [zip, city].where((s) => s.isNotEmpty).join(' ');

      if (streetLine.isNotEmpty) {
        locationRows.add(
          _InfoRow(
            icon: CupertinoIcons.house,
            label: 'Straat',
            value: streetLine,
          ),
        );
      }
      if (cityLine.isNotEmpty) {
        locationRows.add(
          _InfoRow(icon: CupertinoIcons.map, label: 'Stad', value: cityLine),
        );
      }
    }

    final dateRows = <_InfoRow>[];
    if (buildDate != null) {
      dateRows.add(
        _InfoRow(
          icon: CupertinoIcons.wrench,
          label: 'Bouwdatum',
          value: fmt(buildDate),
        ),
      );
    }
    if (commDate != null) {
      dateRows.add(
        _InfoRow(
          icon: CupertinoIcons.calendar,
          label: 'Inbedrijfstelling',
          value: fmt(commDate),
        ),
      );
    }

    final noteRows = <_InfoRow>[];
    if (memo.isNotEmpty) {
      noteRows.add(
        _InfoRow(icon: CupertinoIcons.doc_text, label: 'Memo', value: memo),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 24, bottom: 40),
      children: [
        if (objectRows.isNotEmpty) ...[
          _SectionBlock(
            title: 'Object',
            rows: objectRows,
            bg: bg,
            border: border,
          ),
          const SizedBox(height: 20),
        ],
        if (locationRows.isNotEmpty) ...[
          _SectionBlock(
            title: 'Locatie',
            rows: locationRows,
            bg: bg,
            border: border,
          ),
          const SizedBox(height: 20),
        ],
        if (dateRows.isNotEmpty) ...[
          _SectionBlock(
            title: 'Datums',
            rows: dateRows,
            bg: bg,
            border: border,
          ),
          const SizedBox(height: 20),
        ],
        if (noteRows.isNotEmpty)
          _SectionBlock(
            title: 'Notities',
            rows: noteRows,
            bg: bg,
            border: border,
          ),
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
              top: BorderSide(color: border, width: 0.5),
              bottom: BorderSide(color: border, width: 0.5),
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
          Icon(
            icon,
            size: 18,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 130,
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
