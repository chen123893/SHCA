import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'firebase_options.dart';
import 'screens/auth/choose_role_screen.dart';
import 'screens/auth/auth_gate.dart';
import 'screens/auth/caregiver_profile.dart';
import 'screens/auth/login.dart';
import 'screens/auth/register.dart';
import 'screens/auth/verify_email.dart';
import 'screens/auth/pairing.dart';
import 'screens/auth/elderly_home.dart';
import 'screens/auth/elderly_monitoring.dart';
import 'screens/auth/elderly_profile.dart';
import 'screens/auth/home_router.dart';
import 'screens/auth/knowledge.dart';
import 'screens/auth/statistics.dart';
import 'screens/auth/link_elderly.dart';
import 'screens/auth/medication.dart';
import 'services/phone_fall_monitor.dart';
import 'services/phone_monitoring_background.dart';
import 'services/push_notification_service.dart';
import 'services/watch_schedule_sync.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

@pragma('vm:entry-point')
Future<void> phoneMonitoringMain() => runPhoneMonitoring();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  WatchScheduleSync.instance.start();
  try {
    await PushNotificationService.instance.initialize();
  } catch (error, stackTrace) {
    // Notification setup must never prevent the health and SOS app from
    // opening. The service can retry when a notification feature is used.
    debugPrint('Notification setup was deferred: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
  runApp(const SHCAApp());
}

class SHCAApp extends StatefulWidget {
  const SHCAApp({super.key});

  @override
  State<SHCAApp> createState() => _SHCAAppState();
}

class _SHCAAppState extends State<SHCAApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _notificationTapSubscription;
  String? _activeMedicationTarget;

  @override
  void initState() {
    super.initState();
    final notifications = PushNotificationService.instance;
    _notificationTapSubscription = notifications.notificationTapPayloads.listen(
      (payload) {
        notifications.takePendingNotificationPayload();
        _openMedicationAlert(payload);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final payload = notifications.takePendingNotificationPayload();
      if (payload != null) _openMedicationAlert(payload);
    });
  }

  void _openMedicationAlert(String payload) {
    final target = MedicationNotificationTarget.fromPayload(payload);
    final navigator = _navigatorKey.currentState;
    if (target == null || navigator == null) return;
    if (!target.belongsTo(FirebaseAuth.instance.currentUser?.uid)) return;
    final targetKey =
        '${target.elderlyId}:${target.medicationId}:'
        '${target.scheduledAt?.millisecondsSinceEpoch ?? ''}:'
        '${target.reminderAt?.millisecondsSinceEpoch ?? ''}';
    if (_activeMedicationTarget == targetKey) return;
    _activeMedicationTarget = targetKey;
    unawaited(
      navigator
          .push<void>(
            PageRouteBuilder<void>(
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
              pageBuilder: (_, _, _) => MedicationAlertScreen(
                elderlyId: target.elderlyId,
                medicationId: target.medicationId,
                scheduledAt: target.scheduledAt,
                reminderAt: target.reminderAt,
                initialMedication: target.medicationSnapshot,
              ),
            ),
          )
          .whenComplete(() {
            if (_activeMedicationTarget == targetKey) {
              _activeMedicationTarget = null;
            }
          }),
    );
  }

  @override
  void dispose() {
    unawaited(_notificationTapSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'SHCA',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF8128),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFFFF8F0),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const AuthGate(),
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const RegisterScreen(),
        '/verify-email': (context) => const VerifyEmailScreen(),
        '/choose-role': (context) => const ChooseRoleScreen(),
        '/pairing': (context) => const PairingScreen(),
        '/home': (context) => const RoleHomeRouter(),
        '/knowledge': (context) => const KnowledgeScreen(),
        '/statistics': (context) => const StatisticsScreen(),
        '/elderly-home': (context) => const ElderlyHomeScreen(),
        '/link-elderly': (context) => const LinkElderlyScreen(),
        '/medication': (context) => const MedicationReminderScreen(),
        '/monitoring': (context) =>
            ElderlyMonitoringScreen(activityMonitor: phoneActivityMonitor()),
        '/elderly-profile': (context) =>
            ElderlyProfileScreen(activityMonitor: phoneActivityMonitor()),
        '/caregiver-profile': (context) => const CaregiverProfileScreen(),
      },
    );
  }
}
