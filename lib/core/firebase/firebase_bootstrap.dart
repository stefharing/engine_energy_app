import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';
import '../auth/microsoft_auth_config.dart';

/// Start Firebase op. Inloggen gaat met het Microsoft-werkaccount van de
/// monteur ([signInWithMicrosoft]); er wordt niet meer anoniem ingelogd.
///
/// Als Firebase (nog) niet geconfigureerd is of opstarten mislukt, draait
/// de app gewoon door zonder; [isReady] is dan `false`.
class FirebaseBootstrap {
  FirebaseBootstrap._();

  static bool _ready = false;
  static bool get isReady => _ready;

  /// Firebase draait én er is een Microsoft-gebruiker — pas dan kan de
  /// gedeelde tussenopslag gelezen en geschreven worden. Een oude anonieme
  /// sessie telt niet mee.
  static bool get isSignedIn {
    if (!_ready) return false;
    final user = FirebaseAuth.instance.currentUser;
    return user != null && !user.isAnonymous;
  }

  static Future<void> init() async {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      // Offline cache aan (standaard op mobiel, expliciet voor web) —
      // regels overleven zo een crash of een tijdje zonder bereik.
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );
      _ready = true;
    } catch (e, st) {
      debugPrint('[Firebase] niet gestart: $e\n$st');
      return;
    }
    // Wacht heel even tot de opgeslagen sessie is hersteld, en ruim een
    // oude anonieme sessie (uit eerdere versies) op: die geeft geen toegang
    // meer en moet vervangen worden door Microsoft-login.
    try {
      final auth = FirebaseAuth.instance;
      final user = await auth
          .authStateChanges()
          .first
          .timeout(const Duration(seconds: 3), onTimeout: () => auth.currentUser);
      if (user != null && user.isAnonymous) {
        await auth.signOut();
      }
    } catch (e) {
      debugPrint('[Firebase] sessie herstellen mislukt: $e');
    }
  }

  /// De ingelogde Microsoft-gebruiker. Gooit als er niemand (meer) is
  /// ingelogd. Na het inloggen onthoudt Firebase de sessie, ook offline.
  static Future<User> ensureSignedIn() async {
    if (!_ready) {
      throw StateError('Firebase is niet gestart.');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.isAnonymous) {
      throw StateError('Niet ingelogd met een Microsoft-account.');
    }
    return user;
  }

  /// Logt in met het Microsoft-werkaccount (Entra ID), beperkt tot de tenant
  /// van Engine Energy. Geeft de gebruiker en de e-mailadressen terug waarmee
  /// het account in Ridder gezocht kan worden. Gooit [MicrosoftLoginException]
  /// met een leesbare melding als het niet lukt of de gebruiker annuleert.
  static Future<({User user, Set<String> emails})> signInWithMicrosoft() async {
    if (!_ready) {
      throw MicrosoftLoginException(
        'Inloggen is nu niet mogelijk (Firebase is niet gestart).',
      );
    }
    if (!MicrosoftAuthConfig.isConfigured) {
      throw MicrosoftLoginException(
        'Microsoft-login is nog niet ingesteld (tenant-id ontbreekt).',
      );
    }
    final provider = OAuthProvider('microsoft.com')
      ..setCustomParameters({
        'tenant': MicrosoftAuthConfig.tenantId,
        'prompt': 'select_account',
      });
    try {
      final cred = await FirebaseAuth.instance.signInWithProvider(provider);
      final user = cred.user;
      if (user == null) {
        throw MicrosoftLoginException('Inloggen mislukt. Probeer het opnieuw.');
      }
      final profile = cred.additionalUserInfo?.profile;
      final emails = <String>{
        ?user.email,
        for (final p in user.providerData) ?p.email,
        ?(profile?['mail'] as String?),
        ?(profile?['userPrincipalName'] as String?),
      }.map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toSet();
      return (user: user, emails: emails);
    } on MicrosoftLoginException {
      rethrow;
    } on FirebaseAuthException catch (e) {
      throw MicrosoftLoginException(switch (e.code) {
        'web-context-canceled' ||
        'canceled' ||
        'popup-closed-by-user' => 'Inloggen geannuleerd.',
        'network-request-failed' =>
          'Geen verbinding. Controleer je internet en probeer het opnieuw.',
        _ => 'Inloggen met Microsoft mislukt (${e.code}).',
      });
    }
  }

  static Future<void> signOut() async {
    if (!_ready) return;
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('[Firebase] uitloggen mislukt: $e');
    }
  }
}

class MicrosoftLoginException implements Exception {
  MicrosoftLoginException(this.message);
  final String message;
  @override
  String toString() => message;
}
