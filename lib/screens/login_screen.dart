import 'package:flutter/cupertino.dart';

import '../core/auth/auth_service.dart';
import '../widgets/engine_logo.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocusNode = FocusNode();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty) {
      setState(() => _error = 'Vul een gebruikersnaam in.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await AuthService.instance.login(username, password);
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
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                CupertinoTextField(
                  controller: _usernameController,
                  placeholder: 'Gebruikersnaam',
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  padding: const EdgeInsets.all(14),
                  onSubmitted: (_) => _passwordFocusNode.requestFocus(),
                ),
                const SizedBox(height: 12),
                CupertinoTextField(
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  placeholder: 'Wachtwoord',
                  obscureText: true,
                  padding: const EdgeInsets.all(14),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: CupertinoColors.destructiveRed),
                  ),
                ],
                const SizedBox(height: 24),
                CupertinoButton.filled(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const CupertinoActivityIndicator()
                      : const Text('Inloggen'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
