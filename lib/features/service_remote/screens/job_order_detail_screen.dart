import 'package:flutter/cupertino.dart';

import '../../../core/auth/auth_service.dart';
import '../data/hours_entry_store.dart';
import '../data/job_order_repository.dart';
import '../models/hours_entry.dart';
import '../models/job_order.dart';
import '../models/work_activity.dart';
import 'hours_entry_form_screen.dart';

/// State of the (separate) "Einde werkdag" submission flow — kept apart
/// from [_status]/[_error], which only track opening the job order and its
/// appointment.
enum _SubmissionState {
  idle,
  submitting,
  succeeded,
  failedLogin,
  failedAppointmentClose,
  failedPost,
}

class JobOrderDetailScreen extends StatefulWidget {
  const JobOrderDetailScreen({super.key, required this.jobOrderId});
  final int jobOrderId;
  @override
  State<JobOrderDetailScreen> createState() => _JobOrderDetailScreenState();
}

class _JobOrderDetailScreenState extends State<JobOrderDetailScreen> {
  JobOrder? _jobOrder; // Full, unmodified API object retained for phase 5.
  String _status = 'Bon laden…';
  Object? _error;

  int? _appointmentId;
  bool _appointmentOpened = false;

  _SubmissionState _submissionState = _SubmissionState.idle;
  Object? _submissionError;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    setState(() {
      _status = 'Bon laden…';
      _error = null;
    });
    try {
      final mechanicId = AuthService.instance.currentMechanicId;
      if (mechanicId == null) {
        debugPrint('[diag] _open: no currentMechanicId — not logged in?');
        throw StateError('De ingelogde monteur kon niet worden bepaald.');
      }
      debugPrint(
        '[diag] _open: GET job order ${widget.jobOrderId} for mechanicId=$mechanicId',
      );
      final jobOrder = await JobOrderRepository.instance.getJobOrderDetail(
        widget.jobOrderId,
      );
      debugPrint(
        '[diag] _open: job order fetched OK — id=${jobOrder.id}, '
        'employees=${jobOrder.employees.map((e) => '{id: ${e.id}, employee: ${e.employeeId}}').toList()}',
      );
      // Retain the full server response before any appointment-specific work.
      // Phase 5 edits this exact object and submits it back in full.
      if (!mounted) return;
      setState(() => _jobOrder = jobOrder);

      final AppointmentEntry appointment;
      try {
        appointment = appointmentForMechanic(jobOrder, mechanicId);
      } on MechanicAppointmentNotFound {
        debugPrint(
          '[diag] _open: NO employees[] entry matches mechanicId=$mechanicId '
          '(job order has ${jobOrder.employees.length} employees[] entries)',
        );
        rethrow;
      }
      debugPrint(
        '[diag] _open: matched appointment id=${appointment.id} for mechanicId=$mechanicId',
      );

      setState(() {
        _status = 'Afspraak openen…';
        _appointmentId = appointment.id;
      });
      // openAppointment() now either returns true or throws
      // AppointmentOpenFailed — a 2xx with an empty/non-boolean body is a
      // real success for this endpoint, see isAppointmentCallSuccessful.
      await JobOrderRepository.instance.openAppointment(appointment.id!);
      debugPrint('[diag] _open: openAppointment(${appointment.id}) -> true');
      if (mounted) {
        setState(() {
          _status = 'Afspraak is geopend.';
          _appointmentOpened = true;
        });
      }
    } catch (error) {
      debugPrint('[diag] _open: FAILED — ${error.runtimeType}: $error');
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _addOrEditHours({HoursEntry? existing}) async {
    final mechanicId = AuthService.instance.currentMechanicId;
    if (mechanicId == null) return;
    final saved = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => HoursEntryFormScreen(
          jobOrderId: widget.jobOrderId,
          employeeId: mechanicId,
          existing: existing,
        ),
      ),
    );
    // The store already holds the update; this just repaints the list.
    if (saved == true && mounted) setState(() {});
  }

  bool get _canSubmit =>
      _appointmentOpened &&
      _jobOrder != null &&
      _appointmentId != null &&
      _submissionState != _SubmissionState.submitting &&
      _submissionState != _SubmissionState.succeeded;

  Future<void> _submit() async {
    final jobOrder = _jobOrder;
    final appointmentId = _appointmentId;
    if (jobOrder == null || appointmentId == null) return;

    setState(() {
      _submissionState = _SubmissionState.submitting;
      _submissionError = null;
    });
    try {
      await JobOrderRepository.instance.submitJobOrder(
        jobOrder,
        appointmentId,
      );
      if (mounted) setState(() => _submissionState = _SubmissionState.succeeded);
    } on JobOrderSubmissionLoginFailed catch (e) {
      _failSubmission(_SubmissionState.failedLogin, e);
    } on JobOrderSubmissionAppointmentCloseFailed catch (e) {
      _failSubmission(_SubmissionState.failedAppointmentClose, e);
    } on JobOrderSubmissionPostFailed catch (e) {
      _failSubmission(_SubmissionState.failedPost, e);
    } catch (e) {
      // Anything unexpected is attributed to the last (riskiest) step
      // rather than silently swallowed.
      _failSubmission(_SubmissionState.failedPost, e);
    }
  }

  /// TEMPORARY EXPERIMENT trigger — tests whether readyForSignature:false
  /// + a placeholder signature avoids the live 500. Not the real submit
  /// flow; see JobOrderRepository.submitJobOrderWithSignatureExperiment.
  /// Remove this button once the hypothesis is confirmed or ruled out.
  Future<void> _submitExperiment() async {
    final jobOrder = _jobOrder;
    final appointmentId = _appointmentId;
    if (jobOrder == null || appointmentId == null) return;

    setState(() {
      _submissionState = _SubmissionState.submitting;
      _submissionError = null;
    });
    try {
      await JobOrderRepository.instance.submitJobOrderWithSignatureExperiment(
        jobOrder,
        appointmentId,
      );
      if (mounted) setState(() => _submissionState = _SubmissionState.succeeded);
    } on JobOrderSubmissionLoginFailed catch (e) {
      _failSubmission(_SubmissionState.failedLogin, e);
    } on JobOrderSubmissionAppointmentCloseFailed catch (e) {
      _failSubmission(_SubmissionState.failedAppointmentClose, e);
    } on JobOrderSubmissionPostFailed catch (e) {
      _failSubmission(_SubmissionState.failedPost, e);
    } catch (e) {
      _failSubmission(_SubmissionState.failedPost, e);
    }
  }

  /// TEMPORARY EXPERIMENT #3 trigger — tests whether POSTing the job order
  /// BEFORE closing the appointment (reversed order) avoids the live 500.
  /// Not the real submit flow; see
  /// JobOrderRepository.submitJobOrderReversedOrderExperiment. Remove this
  /// button once the hypothesis is confirmed or ruled out.
  Future<void> _submitExperiment3() async {
    final jobOrder = _jobOrder;
    final appointmentId = _appointmentId;
    if (jobOrder == null || appointmentId == null) return;

    setState(() {
      _submissionState = _SubmissionState.submitting;
      _submissionError = null;
    });
    try {
      await JobOrderRepository.instance.submitJobOrderReversedOrderExperiment(
        jobOrder,
        appointmentId,
      );
      if (mounted) setState(() => _submissionState = _SubmissionState.succeeded);
    } on JobOrderSubmissionLoginFailed catch (e) {
      _failSubmission(_SubmissionState.failedLogin, e);
    } on JobOrderSubmissionAppointmentCloseFailed catch (e) {
      _failSubmission(_SubmissionState.failedAppointmentClose, e);
    } on JobOrderSubmissionPostFailed catch (e) {
      _failSubmission(_SubmissionState.failedPost, e);
    } catch (e) {
      _failSubmission(_SubmissionState.failedPost, e);
    }
  }

  void _failSubmission(_SubmissionState state, Object error) {
    if (!mounted) return;
    setState(() {
      _submissionState = state;
      _submissionError = error;
    });
  }

  /// Distinct, recognizable text per failure mode of [_open] — these used
  /// to collapse into one generic "Bon of afspraak openen mislukt.", which
  /// hid whether the GET, the mechanic match, or the open-appointment call
  /// was the actual problem (and, for the open call, its real status/body).
  static String _openErrorMessage(Object? error) {
    if (error is MechanicAppointmentNotFound) {
      return 'Deze bon is niet aan jou toegewezen.';
    }
    if (error is JobOrderDetailFetchFailed) {
      return 'Bon ophalen mislukt (status ${error.statusCode}).\n${error.body}';
    }
    if (error is AppointmentOpenFailed) {
      return 'Afspraak openen mislukt (status ${error.statusCode}).\n${error.body}';
    }
    return 'Bon of afspraak openen mislukt.\n$error';
  }

  @override
  Widget build(BuildContext context) {
    final mechanicId = AuthService.instance.currentMechanicId;
    final jobOrder = _jobOrder;

    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Bon')),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: _error != null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _openErrorMessage(_error),
                          textAlign: TextAlign.center,
                        ),
                        CupertinoButton(
                          onPressed: _open,
                          child: const Text('Opnieuw proberen'),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _status == 'Afspraak is geopend.'
                            ? const Icon(
                                CupertinoIcons.check_mark_circled,
                                color: CupertinoColors.activeGreen,
                                size: 42,
                              )
                            : const CupertinoActivityIndicator(),
                        const SizedBox(height: 12),
                        Text(_status),
                        if (jobOrder != null && jobOrder.recordTag.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            jobOrder.recordTag,
                            style: const TextStyle(
                              color: CupertinoColors.secondaryLabel,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
            if (jobOrder != null && mechanicId != null)
              Expanded(
                child: _HoursSection(
                  jobOrderId: widget.jobOrderId,
                  enabled: _submissionState != _SubmissionState.succeeded,
                  onAdd: () => _addOrEditHours(),
                  onEdit: (entry) => _addOrEditHours(existing: entry),
                ),
              ),
            if (jobOrder != null && mechanicId != null) _buildSubmitBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitBar() {
    String? statusText;
    Color? statusColor;
    switch (_submissionState) {
      case _SubmissionState.idle:
        statusText = null;
      case _SubmissionState.submitting:
        statusText = 'Versturen…';
      case _SubmissionState.succeeded:
        statusText = 'Verstuurd.';
        statusColor = CupertinoColors.activeGreen;
      case _SubmissionState.failedLogin:
        statusText =
            'Inloggen mislukt bij versturen — probeer opnieuw.\n$_submissionError';
        statusColor = CupertinoColors.destructiveRed;
      case _SubmissionState.failedAppointmentClose:
        statusText =
            'Afspraak afsluiten mislukt — probeer opnieuw.\n$_submissionError';
        statusColor = CupertinoColors.destructiveRed;
      case _SubmissionState.failedPost:
        statusText =
            'Versturen van de bon mislukt — probeer opnieuw.\n$_submissionError';
        statusColor = CupertinoColors.destructiveRed;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (statusText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                statusText,
                textAlign: TextAlign.center,
                style: TextStyle(color: statusColor),
              ),
            ),
          CupertinoButton.filled(
            onPressed: _canSubmit ? _submit : null,
            child: _submissionState == _SubmissionState.submitting
                ? const CupertinoActivityIndicator(
                    color: CupertinoColors.white,
                  )
                : Text(
                    _submissionState == _SubmissionState.succeeded
                        ? 'Verstuurd'
                        : 'Einde werkdag / Versturen',
                  ),
          ),
          // TEMPORARY EXPERIMENT — remove once the readyForSignature/
          // signature hypothesis is confirmed or ruled out. Not the real
          // submit flow.
          if (_canSubmit)
            CupertinoButton(
              onPressed: _submitExperiment,
              child: const Text(
                'TEST: met signature-placeholder (tijdelijk)',
                style: TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.systemOrange,
                ),
              ),
            ),
          // TEMPORARY EXPERIMENT #3 — remove once the ordering hypothesis
          // is confirmed or ruled out. Not the real submit flow.
          if (_canSubmit)
            CupertinoButton(
              onPressed: _submitExperiment3,
              child: const Text(
                'TEST: POST vóór close (tijdelijk)',
                style: TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.systemOrange,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Local (not-yet-submitted) hours entries for this job order. Purely reads
/// from [HoursEntryStore] — nothing here calls the API. Once submission
/// succeeds, [enabled] is false: entries have been sent (and cleared from
/// the store by `submitJobOrder`), so this no longer offers add/edit.
class _HoursSection extends StatelessWidget {
  const _HoursSection({
    required this.jobOrderId,
    required this.enabled,
    required this.onAdd,
    required this.onEdit,
  });

  final int jobOrderId;
  final bool enabled;
  final VoidCallback onAdd;
  final ValueChanged<HoursEntry> onEdit;

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  static String _formatDay(DateTime dt) =>
      '${_pad2(dt.day)}-${_pad2(dt.month)}-${dt.year}';

  static String _formatTime(DateTime dt) => '${_pad2(dt.hour)}:${_pad2(dt.minute)}';

  static String _formatDuration(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}u' : '${h}u ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final entries = HoursEntryStore.instance.entriesFor(jobOrderId);
    final activities = workActivitiesProvider();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Uren',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    enabled
                        ? 'Nog geen uren toegevoegd.'
                        : 'Uren zijn verstuurd.',
                  ),
                )
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final activity = activities.firstWhere(
                      (a) => a.id == entry.workActivityId,
                      orElse: () => activities.first,
                    );
                    final subtitle = StringBuffer(
                      '${_formatTime(entry.start)}–${_formatTime(entry.end)} · '
                      '${activity.code} · ${_formatDuration(entry.totalTime)}',
                    );
                    if (entry.memo != null && entry.memo!.isNotEmpty) {
                      subtitle.write('\n${entry.memo}');
                    }
                    return CupertinoListTile(
                      title: Text(_formatDay(entry.start)),
                      subtitle: Text(subtitle.toString()),
                      trailing: enabled
                          ? const CupertinoListTileChevron()
                          : null,
                      onTap: enabled ? () => onEdit(entry) : null,
                    );
                  },
                ),
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.all(16),
            child: CupertinoButton.filled(
              onPressed: onAdd,
              child: const Text('Uren toevoegen'),
            ),
          ),
      ],
    );
  }
}
