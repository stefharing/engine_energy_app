import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/planning_repository.dart';
import '../models/job_order.dart';
import 'declarations_screen.dart';
import 'hours_week_screen.dart';
import 'parts_list_screen.dart';
import 'relation_detail_screen.dart';
import 'service_object_detail_screen.dart';

class OrderDetailScreen extends StatefulWidget {
  final ServiceOrder order;

  const OrderDetailScreen({super.key, required this.order});

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  Map<String, dynamic>? _contract;
  bool _contractLoading = false;
  Map<String, dynamic>? _address;
  String? _contactName;
  String? _contactPhone;

  @override
  void initState() {
    super.initState();
    _loadContract();
    _loadObjectAddress();
    _loadContact();
  }

  Future<void> _loadContract() async {
    final id = widget.order.serviceContractId;
    if (id == null) return;
    setState(() => _contractLoading = true);
    final data = await PlanningRepository.instance.fetchServiceContract(id);
    setState(() {
      _contract = data;
      _contractLoading = false;
    });
  }

  Future<void> _loadObjectAddress() async {
    final objectId = widget.order.serviceObjectId;
    if (objectId == null) return;
    final objectData = await PlanningRepository.instance.fetchServiceObject(
      objectId,
    );
    if (objectData == null) return;
    final locationId =
        (objectData['objectlocation'] as Map<String, dynamic>?)?['id']
            ?.toString();
    if (locationId != null) {
      final delivery = await PlanningRepository.instance.fetchDeliveryAddress(
        locationId,
      );
      final addressId = (delivery?['address'] as Map<String, dynamic>?)?['id']
          ?.toString();
      if (addressId != null) {
        final addr = await PlanningRepository.instance.fetchAddress(addressId);
        if (addr != null && mounted) {
          setState(() => _address = addr);
          return;
        }
      }
    }
  }

  Future<void> _loadContact() async {
    final orderId = widget.order.productionOrderId;
    if (orderId == null) return;
    final order = await PlanningRepository.instance.fetchProductionOrder(
      orderId,
    );
    if (order == null || !mounted) return;

    final contactRef = order['contact'] as Map<String, dynamic>?;
    if (contactRef == null) return;

    final name = contactRef['recordtag']?.toString() ?? '';
    final contactId = contactRef['id']?.toString();

    // Fetch full contact record for phone number
    String phone = '';
    if (contactId != null) {
      final contact = await PlanningRepository.instance.fetchContact(contactId);
      if (contact != null) {
        phone =
            contact['phone']?.toString() ??
            contact['mobile']?.toString() ??
            contact['phone1']?.toString() ??
            contact['mobilephone']?.toString() ??
            '';
      }
    }

    if (!mounted) return;
    if (name.isNotEmpty || phone.isNotEmpty) {
      setState(() {
        _contactName = name.isNotEmpty ? name : null;
        _contactPhone = phone.isNotEmpty ? phone : null;
      });
    }
  }

  Future<void> _callContact() async {
    final phone = _contactPhone;
    if (phone == null) return;
    final uri = Uri.parse('tel:${phone.replaceAll(' ', '')}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  String _formatAddress(Map<String, dynamic> addr) {
    final street = addr['street']?.toString() ?? '';
    final number = addr['housenumber']?.toString() ?? '';
    final zipcode = addr['zipcode']?.toString() ?? '';
    final city = addr['city']?.toString() ?? '';
    final line1 = '$street $number'.trim();
    final line2 = '$zipcode $city'.trim();
    return [line1, line2].where((s) => s.isNotEmpty).join('\n');
  }

  Color _stateColor(String state) {
    final s = state.toLowerCase();
    if (s.contains('nieuw') || s.contains('new'))
      return const Color(0xFF4A90D9);
    if (s.contains('uitvoering') || s.contains('progress'))
      return const Color(0xFFF5A623);
    if (s.contains('gereed') || s.contains('done') || s.contains('klaar'))
      return const Color(0xFF50C878);
    if (s.contains('gepland') || s.contains('planned'))
      return const Color(0xFF9B59B6);
    return const Color(0xFFAAAAAA);
  }

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

  String _fmt(DateTime? d) {
    if (d == null) return '—';
    return '${d.day} ${_months[d.month]} ${d.year}';
  }

  Future<void> _openMaps() async {
    final rawAddress = _address != null
        ? _formatAddress(_address!).replaceAll('\n', ', ')
        : widget.order.location;
    final q = Uri.encodeComponent(rawAddress);

    // Build list of available map apps
    final options = <(String, Uri)>[];
    if (await canLaunchUrl(Uri.parse('maps://'))) {
      options.add(('Apple Maps', Uri.parse('maps://?q=$q')));
    }
    if (await canLaunchUrl(Uri.parse('comgooglemaps://'))) {
      options.add(('Google Maps', Uri.parse('comgooglemaps://?q=$q')));
    }
    if (await canLaunchUrl(Uri.parse('waze://'))) {
      options.add(('Waze', Uri.parse('waze://?q=$q')));
    }

    // Only one option → open directly
    if (options.length == 1) {
      await launchUrl(options.first.$2);
      return;
    }

    // Multiple options → show action sheet
    if (!mounted) return;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Navigeer naar locatie'),
        message: Text(rawAddress),
        actions: [
          for (final (name, uri) in options)
            CupertinoActionSheetAction(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await launchUrl(uri);
              },
              child: Text(name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDestructiveAction: false,
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuleren'),
        ),
      ),
    );
  }

  void _openParts() {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => PartsListScreen(order: widget.order),
      ),
    );
  }

  void _openDeclarations() {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => DeclarationsScreen(order: widget.order),
      ),
    );
  }

  void _openHoursRegistration() {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => HoursWeekScreen(order: widget.order),
      ),
    );
  }

  void _openRelation() {
    final id = widget.order.productionOrderId;
    if (id == null) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => RelationDetailScreen(productionOrderId: id),
      ),
    );
  }

  void _openServiceObject() {
    final id = widget.order.serviceObjectId;
    if (id == null) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => ServiceObjectDetailScreen(
          serviceObjectId: id,
          name: widget.order.serviceObjectTag,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final stateColor = _stateColor(order.workflowState);
    final borderColor = isDark
        ? const Color(0xFF38383A)
        : const Color(0xFFE5E5EA);
    final cardBg = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.systemBackground,
        border: null,
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.label.resolveFrom(context),
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: Text(
          order.orderNumber.isNotEmpty ? order.orderNumber : 'Order',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 48),
          children: [
            // ── Hero ──────────────────────────────────────────────────────
            _HeroHeader(order: order, stateColor: stateColor, fmt: _fmt),

            const SizedBox(height: 20),

            // ── Uren knoppen band ─────────────────────────────────────────
            _TimeActionBar(
              onUren: _openHoursRegistration,
              onOnderdelen: _openParts,
              onDeclaraties: _openDeclarations,
            ),

            const SizedBox(height: 28),

            // ── Klus ──────────────────────────────────────────────────────
            _SectionLabel('Klus'),
            _Card(
              bg: cardBg,
              border: borderColor,
              children: [
                if (order.mechanic != null)
                  _InfoRow(
                    icon: CupertinoIcons.person,
                    label: 'Monteur',
                    value: order.mechanic!.name,
                  ),
                if (order.serviceType.isNotEmpty)
                  _InfoRow(
                    icon: CupertinoIcons.wrench,
                    label: 'Type service',
                    value: order.serviceType,
                  ),
                if (order.orderNumber.isNotEmpty)
                  _InfoRow(
                    icon: CupertinoIcons.doc_text,
                    label: 'Ordernummer',
                    value: order.orderNumber,
                  ),
              ],
            ),
            const SizedBox(height: 20),

            // ── Adres & contact ───────────────────────────────────────────
            if (order.location.isNotEmpty) ...[
              _SectionLabel('Adres & contact'),
              _Card(
                bg: cardBg,
                border: borderColor,
                children: [
                  _NavRow(
                    icon: CupertinoIcons.map_pin_ellipse,
                    label: order.location,
                    subtitle: _address != null
                        ? _formatAddress(_address!).replaceAll('\n', ', ')
                        : null,
                    onTap: _openMaps,
                  ),
                  if (_contactName != null || _contactPhone != null)
                    _NavRow(
                      icon: CupertinoIcons.phone,
                      label: _contactName ?? _contactPhone!,
                      subtitle: _contactPhone,
                      onTap: _callContact,
                    ),
                ],
              ),
              const SizedBox(height: 20),
            ],

            // ── Gerelateerd ───────────────────────────────────────────────
            // if (order.productionOrderId != null ||
            //     order.serviceObjectId != null) ...[
            //   _SectionLabel('Gerelateerd'),
            //   _Card(
            //     bg: cardBg,
            //     border: borderColor,
            //     children: [
            //       if (order.productionOrderId != null)
            //         _NavRow(
            //           icon: CupertinoIcons.building_2_fill,
            //           label: 'Klant',
            //           onTap: _openRelation,
            //         ),
            //       if (order.serviceObjectId != null)
            //         _NavRow(
            //           icon: CupertinoIcons.wrench_fill,
            //           label: 'Service object',
            //           subtitle: order.serviceObjectTag.isNotEmpty
            //               ? order.serviceObjectTag
            //               : null,
            //           onTap: _openServiceObject,
            //         ),
            //     ],
            //   ),
            //   const SizedBox(height: 20),
            // ],

            // ── Servicecontract ───────────────────────────────────────────
            if (_contractLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(child: CupertinoActivityIndicator()),
              )
            else if (_contract != null) ...[
              _SectionLabel('Servicecontract'),
              _ContractCard(
                contract: _contract!,
                bg: cardBg,
                border: borderColor,
                fmt: _fmt,
              ),
              const SizedBox(height: 20),
            ],

            // ── Tijdregistratie (placeholder) ─────────────────────────────
            // _SectionLabel('Tijdregistratie'),
            // _Card(
            //   bg: cardBg,
            //   border: borderColor,
            //   children: [
            //     _TimeRow(icon: CupertinoIcons.wrench, label: 'Werktijd'),
            //     _TimeRow(icon: CupertinoIcons.car, label: 'Reistijd'),
            //   ],
            // ),
            // const SizedBox(height: 20),

            // ── Werkbon (placeholder) ─────────────────────────────────────
            // _SectionLabel('Werkbon'),
            // _WorkbonCard(bg: cardBg, border: borderColor),
            // const SizedBox(height: 20),

            // ── Materialen (placeholder) ──────────────────────────────────
            // _SectionLabel('Materialen'),
            // _Card(
            //   bg: cardBg,
            //   border: borderColor,
            //   children: [
            //     _PlaceholderRow(
            //       icon: CupertinoIcons.cube_box,
            //       label: 'Nog geen materialen gekoppeld',
            //     ),
            //     _ActionRow(
            //       icon: CupertinoIcons.plus_circle,
            //       label: 'Materiaal toevoegen',
            //       color: CupertinoColors.systemGrey,
            //       onTap: null,
            //     ),
            //   ],
            // ),
          ],
        ),
      ),
    );
  }
}

// ─── Hero header ───────────────────────────────────────────────────────────────

class _HeroHeader extends StatelessWidget {
  final ServiceOrder order;
  final Color stateColor;
  final String Function(DateTime?) fmt;

  const _HeroHeader({
    required this.order,
    required this.stateColor,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final title = order.description.isNotEmpty
        ? order.description
        : order.orderNumber;

    return Container(
      color: stateColor.withValues(alpha: 0.08),
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _StatusPill(label: order.workflowState, color: stateColor),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              height: 1.3,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          if (order.serviceObjectTag.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              order.serviceObjectTag,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
          const SizedBox(height: 18),
          // Date range chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: stateColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.calendar, size: 13, color: stateColor),
                const SizedBox(width: 6),
                Text(
                  fmt(order.startDate),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: stateColor,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(
                    CupertinoIcons.arrow_right,
                    size: 10,
                    color: stateColor.withValues(alpha: 0.6),
                  ),
                ),
                Text(
                  fmt(order.endTime ?? order.startDate),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: stateColor,
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

// ─── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String title;
  const _SectionLabel(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
    );
  }
}

// ─── Card ──────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final List<Widget> children;
  final Color bg;
  final Color border;

  const _Card({required this.children, required this.bg, required this.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          top: BorderSide(color: border, width: 0.5),
          bottom: BorderSide(color: border, width: 0.5),
        ),
      ),
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: Container(height: 0.5, color: border),
              ),
          ],
        ],
      ),
    );
  }
}

// ─── Info row ──────────────────────────────────────────────────────────────────

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
            width: 110,
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

// ─── Nav row ───────────────────────────────────────────────────────────────────

class _NavRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _NavRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 20,
          vertical: subtitle != null ? 14 : 13,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: subtitle != null
                          ? FontWeight.w500
                          : FontWeight.w400,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 14,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
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
}

// ─── Action row (tappable with color) ─────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = onTap != null
        ? color
        : CupertinoColors.tertiaryLabel.resolveFrom(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 18, color: effectiveColor),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: effectiveColor,
                ),
              ),
            ),
            if (onTap != null)
              Icon(
                CupertinoIcons.arrow_up_right_square,
                size: 16,
                color: effectiveColor,
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Time row (placeholder) ────────────────────────────────────────────────────

class _TimeRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TimeRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(width: 14),
          Expanded(
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
          Text(
            '00:00',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w400,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          Opacity(
            opacity: 0.4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF34C759).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'START',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF34C759),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Workbon card (placeholder) ────────────────────────────────────────────────

class _WorkbonCard extends StatelessWidget {
  final Color bg;
  final Color border;

  const _WorkbonCard({required this.bg, required this.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          top: BorderSide(color: border, width: 0.5),
          bottom: BorderSide(color: border, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Text area placeholder
          Container(
            width: double.infinity,
            height: 90,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CupertinoColors.systemBackground.resolveFrom(context),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border),
            ),
            child: Text(
              'Omschrijf de uitgevoerde werkzaamheden...',
              style: TextStyle(
                fontSize: 14,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Action icons row
          Row(
            children: [
              _IconButton(
                icon: CupertinoIcons.camera,
                label: "Foto's",
                context: context,
              ),
              const SizedBox(width: 16),
              _IconButton(
                icon: CupertinoIcons.signature,
                label: 'Handtekening',
                context: context,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final BuildContext context;

  const _IconButton({
    required this.icon,
    required this.label,
    required this.context,
  });

  @override
  Widget build(BuildContext ctx) {
    return Opacity(
      opacity: 0.4,
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: CupertinoColors.secondaryLabel.resolveFrom(ctx),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: CupertinoColors.secondaryLabel.resolveFrom(ctx),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Placeholder row ───────────────────────────────────────────────────────────

class _PlaceholderRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _PlaceholderRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: CupertinoColors.tertiaryLabel.resolveFrom(context),
          ),
          const SizedBox(width: 14),
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Status pill ───────────────────────────────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ─── Contract card ─────────────────────────────────────────────────────────────

class _ContractCard extends StatelessWidget {
  final Map<String, dynamic> contract;
  final Color bg;
  final Color border;
  final String Function(DateTime?) fmt;

  const _ContractCard({
    required this.contract,
    required this.bg,
    required this.border,
    required this.fmt,
  });

  String _str(String key) => contract[key]?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];

    final recordTag = _str('recordtag');
    final description = _str('description');
    final startDate = contract['startdate'] != null
        ? DateTime.tryParse(contract['startdate'].toString())
        : null;
    final endDate = contract['enddate'] != null
        ? DateTime.tryParse(contract['enddate'].toString())
        : null;

    if (recordTag.isNotEmpty)
      rows.add(
        _InfoRow(
          icon: CupertinoIcons.doc,
          label: 'Contractnummer',
          value: recordTag,
        ),
      );
    if (description.isNotEmpty)
      rows.add(
        _InfoRow(
          icon: CupertinoIcons.text_alignleft,
          label: 'Omschrijving',
          value: description,
        ),
      );
    if (startDate != null)
      rows.add(
        _InfoRow(
          icon: CupertinoIcons.calendar,
          label: 'Contract van',
          value: fmt(startDate),
        ),
      );
    if (endDate != null)
      rows.add(
        _InfoRow(
          icon: CupertinoIcons.calendar_badge_minus,
          label: 'Contract tot',
          value: fmt(endDate),
        ),
      );

    if (rows.isEmpty) return const SizedBox.shrink();

    return _Card(bg: bg, border: border, children: rows);
  }
}

// ─── Time action bar ────────────────────────────────────────────────────────────

class _TimeActionBar extends StatelessWidget {
  final VoidCallback? onUren;
  final VoidCallback? onOnderdelen;
  final VoidCallback? onDeclaraties;
  const _TimeActionBar({this.onUren, this.onOnderdelen, this.onDeclaraties});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _TimeActionButton(
            icon: CupertinoIcons.clock,
            label: 'Uren',
            color: const Color(0xFF34C759),
            onTap: onUren,
          ),
          const SizedBox(width: 8),
          _TimeActionButton(
            icon: CupertinoIcons.cube_box,
            label: 'Onderdelen',
            color: CupertinoColors.systemOrange,
            onTap: onOnderdelen,
          ),
          const SizedBox(width: 8),
          _TimeActionButton(
            icon: CupertinoIcons.creditcard,
            label: 'Declaraties',
            color: const Color(0xFF5E5CE6),
            onTap: onDeclaraties,
          ),
        ],
      ),
    );
  }
}

class _TimeActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _TimeActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.30), width: 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
