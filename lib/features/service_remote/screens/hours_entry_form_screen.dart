import 'package:flutter/cupertino.dart';

import '../data/hours_entry_store.dart';
import '../models/hours_entry.dart';
import '../models/work_activity.dart';

/// Add/edit form for a single day's [HoursEntry] on a job order. Saving
/// always goes through [HoursEntryStore.upsert], which enforces the
/// same-day-reuses-uniqueId rule — this screen doesn't need to know whether
/// it's creating or updating a registration.
class HoursEntryFormScreen extends StatefulWidget {
  const HoursEntryFormScreen({
    super.key,
    required this.jobOrderId,
    required this.employeeId,
    this.existing,
  });

  final int jobOrderId;
  final int employeeId;

  /// The entry being edited, if any. When null, a new day's entry is being
  /// added (starting from "now").
  final HoursEntry? existing;

  @override
  State<HoursEntryFormScreen> createState() => _HoursEntryFormScreenState();
}

class _HoursEntryFormScreenState extends State<HoursEntryFormScreen> {
  late DateTime _start;
  late DateTime _end;
  late int _workActivityId;
  late final TextEditingController _memoController;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final now = DateTime.now();
    _start = existing?.start ?? DateTime(now.year, now.month, now.day, 8);
    _end = existing?.end ?? _start.add(const Duration(hours: 1));
    _workActivityId = existing?.workActivityId ?? workActivitiesProvider().first.id;
    _memoController = TextEditingController(text: existing?.memo ?? '');
  }

  @override
  void dispose() {
    _memoController.dispose();
    super.dispose();
  }

  bool get _isValid => _end.isAfter(_start);

  void _save() {
    if (!_isValid) return;
    HoursEntryStore.instance.upsert(
      jobOrderId: widget.jobOrderId,
      employeeId: widget.employeeId,
      start: _start,
      end: _end,
      workActivityId: _workActivityId,
      memo: _memoController.text.trim().isEmpty
          ? null
          : _memoController.text.trim(),
    );
    Navigator.of(context).pop(true);
  }

  Future<void> _pickDateTime({
    required DateTime initial,
    required ValueChanged<DateTime> onChanged,
  }) {
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => Container(
        height: 260,
        color: CupertinoColors.systemBackground.resolveFrom(context),
        child: SafeArea(
          top: false,
          child: CupertinoDatePicker(
            mode: CupertinoDatePickerMode.dateAndTime,
            initialDateTime: initial,
            use24hFormat: true,
            onDateTimeChanged: onChanged,
          ),
        ),
      ),
    );
  }

  Future<void> _pickWorkActivity() {
    final activities = workActivitiesProvider();
    var selectedIndex = activities.indexWhere((a) => a.id == _workActivityId);
    if (selectedIndex == -1) selectedIndex = 0;

    return showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => Container(
        height: 260,
        color: CupertinoColors.systemBackground.resolveFrom(context),
        child: SafeArea(
          top: false,
          child: CupertinoPicker(
            itemExtent: 40,
            scrollController: FixedExtentScrollController(
              initialItem: selectedIndex,
            ),
            onSelectedItemChanged: (index) {
              setState(() => _workActivityId = activities[index].id);
            },
            children: activities
                .map((a) => Center(child: Text('${a.code} — ${a.label}')))
                .toList(),
          ),
        ),
      ),
    );
  }

  static String _formatDateTime(DateTime dt) {
    String pad2(int n) => n.toString().padLeft(2, '0');
    return '${pad2(dt.day)}-${pad2(dt.month)}-${dt.year} ${pad2(dt.hour)}:${pad2(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final activities = workActivitiesProvider();
    final selectedActivity = activities.firstWhere(
      (a) => a.id == _workActivityId,
      orElse: () => activities.first,
    );

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.existing == null ? 'Uren toevoegen' : 'Uren bewerken'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _isValid ? _save : null,
          child: const Text('Opslaan'),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            CupertinoListSection.insetGrouped(
              children: [
                CupertinoListTile(
                  title: const Text('Start'),
                  additionalInfo: Text(_formatDateTime(_start)),
                  onTap: () => _pickDateTime(
                    initial: _start,
                    onChanged: (value) => setState(() => _start = value),
                  ),
                ),
                CupertinoListTile(
                  title: const Text('Einde'),
                  additionalInfo: Text(_formatDateTime(_end)),
                  onTap: () => _pickDateTime(
                    initial: _end,
                    onChanged: (value) => setState(() => _end = value),
                  ),
                ),
                CupertinoListTile(
                  title: const Text('Werkzaamheid'),
                  additionalInfo: Text(selectedActivity.code),
                  onTap: _pickWorkActivity,
                ),
              ],
            ),
            if (!_isValid)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  'Eindtijd moet na de starttijd liggen.',
                  style: TextStyle(color: CupertinoColors.destructiveRed),
                ),
              ),
            const SizedBox(height: 16),
            CupertinoTextField(
              controller: _memoController,
              placeholder: 'Notitie (optioneel)',
              padding: const EdgeInsets.all(14),
              minLines: 2,
              maxLines: 5,
            ),
          ],
        ),
      ),
    );
  }
}
