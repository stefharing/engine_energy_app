import 'package:flutter/cupertino.dart';

import '../core/auth/auth_service.dart';
import '../core/auth/employee.dart';
import '../core/auth/employee_repository.dart';
import '../widgets/engine_logo.dart';

const _accentOrange = Color(0xFFFF6B2B);

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  List<Employee>? _employees;
  Employee? _selected;
  bool _loadingEmployees = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadEmployees();
  }

  Future<void> _loadEmployees() async {
    setState(() {
      _loadingEmployees = true;
      _error = null;
    });
    try {
      final employees = await EmployeeRepository.instance.fetchFieldEngineers();
      if (!mounted) return;
      setState(() {
        _employees = employees;
        _loadingEmployees = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Kon monteurs niet ophalen. Probeer het opnieuw.';
        _loadingEmployees = false;
      });
    }
  }

  Future<void> _pickEmployee() async {
    final employees = _employees;
    if (employees == null || employees.isEmpty) return;

    var index = _selected == null ? 0 : employees.indexOf(_selected!);
    if (index < 0) index = 0;

    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 280,
        color: CupertinoColors.systemBackground.resolveFrom(context),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Annuleren'),
                  ),
                  CupertinoButton(
                    onPressed: () {
                      setState(() => _selected = employees[index]);
                      Navigator.of(ctx).pop();
                    },
                    child: const Text(
                      'Gereed',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: CupertinoPicker(
                  scrollController: FixedExtentScrollController(
                    initialItem: index,
                  ),
                  itemExtent: 40,
                  onSelectedItemChanged: (i) => index = i,
                  children: [
                    for (final e in employees)
                      Center(
                        child: Text(e.name, style: const TextStyle(fontSize: 18)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final employee = _selected;
    if (employee == null) {
      setState(() => _error = 'Selecteer eerst een monteur.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await AuthService.instance.login(employee);
      // On success AuthService.isLoggedInListenable flips to true; the root
      // widget listening to it swaps this screen out. Nothing to navigate
      // to here.
    } on LoginException catch (e) {
      setState(() {
        _error = switch (e.reason) {
          LoginFailureReason.invalidCredentials => 'Ongeldige inloggegevens.',
          LoginFailureReason.network =>
            'Geen verbinding met de server. Probeer het opnieuw.',
        };
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = CupertinoColors.systemGrey4.resolveFrom(context);

    return CupertinoPageScaffold(
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: EngineLogo(height: 64)),
                const SizedBox(height: 48),
                if (_loadingEmployees)
                  const Center(child: CupertinoActivityIndicator())
                else if (_employees == null || _employees!.isEmpty) ...[
                  Text(
                    _error ?? 'Geen monteurs gevonden.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: CupertinoColors.destructiveRed,
                    ),
                  ),
                  const SizedBox(height: 12),
                  CupertinoButton(
                    onPressed: _loadEmployees,
                    child: const Text('Opnieuw proberen'),
                  ),
                ] else ...[
                  GestureDetector(
                    onTap: _pickEmployee,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        border: Border.all(color: borderColor),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _selected?.name ?? 'Selecteer een monteur',
                              style: TextStyle(
                                fontSize: 16,
                                color: _selected != null
                                    ? CupertinoColors.label.resolveFrom(context)
                                    : CupertinoColors.placeholderText
                                          .resolveFrom(context),
                              ),
                            ),
                          ),
                          Icon(
                            CupertinoIcons.chevron_down,
                            size: 18,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: CupertinoColors.destructiveRed,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  CupertinoButton(
                    color: _accentOrange,
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const CupertinoActivityIndicator(
                            color: CupertinoColors.white,
                          )
                        : const Text(
                            'Inloggen',
                            style: TextStyle(color: CupertinoColors.white),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
