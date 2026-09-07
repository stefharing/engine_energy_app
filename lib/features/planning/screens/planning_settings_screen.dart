import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show
        ReorderableListView,
        ReorderableDelayedDragStartListener,
        Theme,
        ThemeData;
import 'package:flutter/services.dart' show HapticFeedback;
import '../../../widgets/nav_border.dart';

import '../../../core/storage/settings_service.dart';
import '../models/job_order.dart';

class PlanningSettingsScreen extends StatefulWidget {
  final List<ServicePerson> employees;

  const PlanningSettingsScreen({super.key, required this.employees});

  @override
  State<PlanningSettingsScreen> createState() =>
      _PlanningSettingsScreenState();
}

class _PlanningSettingsScreenState extends State<PlanningSettingsScreen> {
  Set<int> _hiddenIds = {};
  List<ServicePerson> _ordered = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ids = await SettingsService.instance.loadHiddenIds();
    final order = await SettingsService.instance.loadEmployeeOrder();
    setState(() {
      _hiddenIds = ids;
      _ordered = _applyOrder(widget.employees, order);
      _loaded = true;
    });
  }

  List<ServicePerson> _applyOrder(
      List<ServicePerson> employees, List<int> order) {
    final map = {for (final e in employees) e.id: e};
    final result = <ServicePerson>[];
    for (final id in order) {
      if (map.containsKey(id)) result.add(map[id]!);
    }
    for (final e in employees) {
      if (!order.contains(e.id)) result.add(e);
    }
    return result;
  }

  Future<void> _toggle(int id) async {
    setState(() {
      if (_hiddenIds.contains(id)) {
        _hiddenIds.remove(id);
      } else {
        _hiddenIds.add(id);
      }
    });
    await SettingsService.instance.saveHiddenIds(_hiddenIds);
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final item = _ordered.removeAt(oldIndex);
      _ordered.insert(newIndex, item);
    });
    await SettingsService.instance
        .saveEmployeeOrder(_ordered.map((e) => e.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor =
        isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.white,
        border: null,
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.black,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: const Text(
          'Planning opties',
          style: TextStyle(color: CupertinoColors.black),
        ),
      ),
      child: SafeArea(
        child: !_loaded
            ? const Center(child: CupertinoActivityIndicator())
            : Column(children: [
                const NavBorder(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'MEDEWERKERS',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.secondaryLabel,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Theme(
                    data: ThemeData(
                      canvasColor: CupertinoColors.systemBackground
                          .resolveFrom(context),
                    ),
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: _ordered.length,
                      onReorder: _reorder,
                      itemBuilder: (context, i) {
                        final employee = _ordered[i];
                        final isLast = i == _ordered.length - 1;
                        return _EmployeeRow(
                          key: ValueKey(employee.id),
                          index: i,
                          employee: employee,
                          isHidden: _hiddenIds.contains(employee.id),
                          showDivider: !isLast,
                          borderColor: borderColor,
                          onToggle: () => _toggle(employee.id),
                        );
                      },
                    ),
                  ),
                ),
              ]),
      ),
    );
  }
}

class _EmployeeRow extends StatelessWidget {
  final int index;
  final ServicePerson employee;
  final bool isHidden;
  final bool showDivider;
  final Color borderColor;
  final VoidCallback onToggle;

  const _EmployeeRow({
    super.key,
    required this.index,
    required this.employee,
    required this.isHidden,
    required this.showDivider,
    required this.borderColor,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: CupertinoColors.systemBackground.resolveFrom(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // Eye toggle
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minSize: 0,
                  onPressed: onToggle,
                  child: Icon(
                    isHidden
                        ? CupertinoIcons.eye_slash
                        : CupertinoIcons.eye,
                    size: 22,
                    color: isHidden
                        ? CupertinoColors.secondaryLabel
                        : CupertinoColors.activeBlue,
                  ),
                ),
                const SizedBox(width: 14),
                // Name
                Expanded(
                  child: Text(
                    employee.name,
                    style: TextStyle(
                      fontSize: 16,
                      color: isHidden
                          ? CupertinoColors.secondaryLabel
                          : CupertinoTheme.of(context)
                              .textTheme
                              .textStyle
                              .color,
                    ),
                  ),
                ),
                // Drag handle
                GestureDetector(
                  onLongPressStart: (_) => HapticFeedback.mediumImpact(),
                  child: ReorderableDelayedDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 12),
                      child: Icon(
                        CupertinoIcons.line_horizontal_3,
                        size: 20,
                        color: CupertinoColors.tertiaryLabel,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (showDivider)
            Padding(
              padding: const EdgeInsets.only(left: 52),
              child: Container(height: 0.5, color: borderColor),
            ),
        ],
      ),
    );
  }
}
