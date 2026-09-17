import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;

import 'core/auth/auth_service.dart';
import 'features/planning/screens/planning_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'screens/projecten_screen.dart';

void main() {
  runApp(const EngineEnergyApp());
}

class EngineEnergyApp extends StatelessWidget {
  const EngineEnergyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      title: 'Engine Energy',
      theme: CupertinoThemeData(barBackgroundColor: CupertinoColors.white),
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
  late final Future<void> _bootstrap = AuthService.instance.bootstrap();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrap,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const CupertinoPageScaffold(
            child: Center(child: CupertinoActivityIndicator()),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: AuthService.instance.isLoggedInListenable,
          builder: (context, isLoggedIn, _) {
            return isLoggedIn ? const MainTabView() : const LoginScreen();
          },
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
