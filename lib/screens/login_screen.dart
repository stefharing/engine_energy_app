import 'package:flutter/cupertino.dart';

import '../core/api/api_client.dart';
import '../core/api/api_config.dart';
import '../core/auth/auth_service.dart';
import '../core/auth/employee.dart';
import '../core/auth/employee_repository.dart';
import '../core/auth/microsoft_auth_config.dart';
import '../core/firebase/firebase_bootstrap.dart' show MicrosoftLoginException;
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
  // De medewerkerskeuze is er alleen als MicrosoftAuthConfig
  // .medewerkerskeuzeTonen aanstaat, of zolang Microsoft-login uitstaat.
  static bool get _toonMedewerkers =>
      MicrosoftAuthConfig.medewerkerskeuzeTonen ||
      !MicrosoftAuthConfig.enabled;
  bool _loadingEmployees = false;
  bool _submitting = false;
  String? _error;
  String? _msError;

  @override
  void initState() {
    super.initState();
    if (_toonMedewerkers) _loadEmployees();
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

  bool get _isTest => ApiConfig.environment == ApiEnvironment.test;

  /// Switches between the live and test administration. The mechanics
  /// differ per administration, so the picked one is cleared and the list
  /// reloaded from the newly selected environment.
  Future<void> _setTestEnvironment(bool test) async {
    await ApiClient.instance.useEnvironment(
      test ? ApiEnvironment.test : ApiEnvironment.live,
    );
    if (!mounted) return;
    setState(() => _selected = null);
    if (_toonMedewerkers) await _loadEmployees();
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

  Future<void> _loginWithMicrosoft() async {
    setState(() {
      _submitting = true;
      _msError = null;
    });
    try {
      await AuthService.instance.loginWithMicrosoft();
      // AuthService.isLoggedInListenable flips to true; the root widget
      // swaps this screen out.
    } on MicrosoftLoginException catch (e) {
      if (mounted) setState(() => _msError = e.message);
    } on LoginException catch (e) {
      if (mounted) {
        setState(() {
          _msError = switch (e.reason) {
            LoginFailureReason.invalidCredentials =>
              'Ridder weigerde de inlog. Neem contact op met kantoor.',
            LoginFailureReason.network =>
              'Geen verbinding met de server. Probeer het opnieuw.',
          };
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _msError = 'Inloggen mislukt. Probeer het opnieuw.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = CupertinoColors.systemGrey4.resolveFrom(context);

    return CupertinoPageScaffold(
      child: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: _EnvironmentToggle(
                isTest: _isTest,
                enabled: !_submitting,
                onChanged: _setTestEnvironment,
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: EngineLogo(height: 64)),
                      if (_isTest) ...[
                        const SizedBox(height: 12),
                        const Center(child: _TestBadge()),
                      ],
                      const SizedBox(height: 48),
                      if (MicrosoftAuthConfig.enabled) ...[
                      Text(
                        'Log in met je Engine Energy-account.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      CupertinoButton(
                        color: _accentOrange,
                        onPressed: _submitting ? null : _loginWithMicrosoft,
                        child: _submitting
                            ? const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              )
                            : const Text(
                                'Inloggen met Microsoft',
                                style: TextStyle(color: CupertinoColors.white),
                              ),
                      ),
                      if (_msError != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _msError!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: CupertinoColors.destructiveRed.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ],
                      ],
                      if (_toonMedewerkers) ...[
                        SizedBox(height: MicrosoftAuthConfig.enabled ? 40 : 0),
                        Text(
                          MicrosoftAuthConfig.enabled
                              ? 'Ontwikkeling: kies een monteur'
                              : 'Kies je naam om in te loggen.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: CupertinoColors.tertiaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      if (_loadingEmployees)
                        const Center(child: CupertinoActivityIndicator())
                      else if (_employees == null || _employees!.isEmpty) ...[
                        Text(
                          _error ?? 'Geen monteurs gevonden.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: CupertinoColors.destructiveRed.resolveFrom(context),
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
                            style: TextStyle(
                              color: CupertinoColors.destructiveRed.resolveFrom(context),
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
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Testomgeving" + switch, top right of the login screen.
class _EnvironmentToggle extends StatelessWidget {
  final bool isTest;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _EnvironmentToggle({
    required this.isTest,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Testomgeving',
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(width: 8),
          CupertinoSwitch(
            value: isTest,
            activeTrackColor: _accentOrange,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

/// Makes it obvious the app is pointed at the test administration.
class _TestBadge extends StatelessWidget {
  const _TestBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _accentOrange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'TESTOMGEVING · ${ApiConfig.administrationId}',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: _accentOrange,
        ),
      ),
    );
  }
}
