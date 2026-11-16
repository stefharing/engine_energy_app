import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;

import 'core/api/api_client.dart';
import 'core/auth/auth_service.dart';
import 'core/firebase/firebase_bootstrap.dart';
import 'core/theme/app_colors.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/onboarding_service.dart';
import 'features/planning/screens/planning_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'screens/projecten_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FirebaseBootstrap.init();
  await ApiClient.loadSavedEnvironment();
  runApp(const EngineEnergyApp());
}

class EngineEnergyApp extends StatelessWidget {
  const EngineEnergyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      title: 'Engine Energy',
      theme: CupertinoThemeData(barBackgroundColor: AppColors.navBar),
      localizationsDelegates: [
        DefaultMaterialLocalizations.delegate,
        DefaultCupertinoLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
      home: AuthGate(),
    );
  }
}

/// Decides between [LoginScreen] and [MainTabView] based on
/// [AuthService.isLoggedInListenable]. Loads any Keychain-stored
/// credentials once at startup before rendering either.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  /// Laadt de inloggegevens en kijkt of de welkomstuitleg nog getoond moet
  /// worden; levert `true` als dat zo is.
  late final Future<bool> _bootstrap = _start();

  /// Wordt `true` zodra de welkomstuitleg is afgerond of overgeslagen.
  bool _onboardingKlaar = false;

  Future<bool> _start() async {
    final resultaten = await Future.wait<Object?>([
      AuthService.instance.bootstrap(),
      OnboardingService.instance.moetTonen(),
    ]);
    return resultaten[1] as bool;
  }

  void _rondOnboardingAf() {
    OnboardingService.instance.markeerGezien();
    setState(() => _onboardingKlaar = true);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _bootstrap,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const CupertinoPageScaffold(
            child: Center(child: CupertinoActivityIndicator()),
          );
        }
        final toonOnboarding = snapshot.data == true && !_onboardingKlaar;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          child: toonOnboarding
              ? OnboardingScreen(
                  key: const ValueKey('onboarding'),
                  onKlaar: _rondOnboardingAf,
                )
              : ValueListenableBuilder<bool>(
                  key: const ValueKey('app'),
                  valueListenable: AuthService.instance.isLoggedInListenable,
                  builder: (context, isLoggedIn, _) {
                    return isLoggedIn
                        ? const MainTabView()
                        : const LoginScreen();
                  },
                ),
        );
      },
    );
  }
}

class MainTabView extends StatelessWidget {
  const MainTabView({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        iconSize: 20,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.house),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.calendar),
            label: 'Planning',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.folder),
            label: 'Bonnen',
          ),
        ],
      ),
      tabBuilder: (context, index) {
        switch (index) {
          case 0:
            return const DashboardScreen();
          case 1:
            return const PlanningScreen();
          case 2:
            return const ProjectenScreen();
          default:
            return const DashboardScreen();
        }
      },
    );
  }
}
