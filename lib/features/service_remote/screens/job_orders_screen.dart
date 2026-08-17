import 'package:flutter/cupertino.dart';

import '../data/job_order_repository.dart';
import '../models/job_order.dart';
import 'job_order_detail_screen.dart';

class JobOrdersScreen extends StatefulWidget {
  const JobOrdersScreen({super.key});

  @override
  State<JobOrdersScreen> createState() => _JobOrdersScreenState();
}

class _JobOrdersScreenState extends State<JobOrdersScreen> {
  List<JobOrderSummary>? _jobs;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _jobs = null;
      _error = null;
    });
    try {
      final jobs = await JobOrderRepository.instance.getActiveJobOrders();
      if (mounted) setState(() => _jobs = jobs);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: const CupertinoNavigationBar(middle: Text('Mijn bonnen')),
    child: SafeArea(
      child: _jobs == null
          ? _error == null
                ? const Center(child: CupertinoActivityIndicator())
                : _Failure(message: 'Bonnen laden mislukt.', onRetry: _load)
          : _jobs!.isEmpty
          ? const Center(child: Text('Er zijn geen actieve bonnen.'))
          : ListView.builder(
              itemCount: _jobs!.length,
              itemBuilder: (context, index) {
                final job = _jobs![index];
                return CupertinoListTile(
                  title: Text(
                    job.recordTag.isEmpty ? job.description : job.recordTag,
                  ),
                  subtitle: Text(
                    [
                      job.description,
                      job.serviceObject?.description,
                    ].whereType<String>().where((v) => v.isNotEmpty).join('\n'),
                  ),
                  trailing: const CupertinoListTileChevron(),
                  onTap: job.id == null
                      ? null
                      : () => Navigator.of(context).push(
                          CupertinoPageRoute<void>(
                            builder: (_) =>
                                JobOrderDetailScreen(jobOrderId: job.id!),
                          ),
                        ),
                );
              },
            ),
    ),
  );
}

class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message),
        CupertinoButton(
          onPressed: onRetry,
          child: const Text('Opnieuw proberen'),
        ),
      ],
    ),
  );
}
