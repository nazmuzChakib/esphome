import 'package:go_router/go_router.dart';
import '../../features/splash/presentation/splash_screen.dart';
import '../../features/setup/presentation/setup_wizard_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/registration_screen.dart';
import '../../features/auth/presentation/forget_password_screen.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/control/presentation/node_control_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/settings/presentation/security_settings_screen.dart';
import '../../features/settings/presentation/global_rules_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/admin/presentation/access_control_screen.dart';
import '../../features/settings/presentation/database_inspector_screen.dart';
import '../../features/settings/presentation/debug_monitor_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/splash',
  routes: [
    GoRoute(path: '/splash', builder: (context, state) => const SplashScreen()),
    GoRoute(
      path: '/wizard',
      builder: (context, state) => const SetupWizardScreen(),
    ),
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(
      path: '/register',
      builder: (context, state) => const RegistrationScreen(),
    ),
    GoRoute(
      path: '/forget-password',
      builder: (context, state) => const ForgetPasswordScreen(),
    ),
    GoRoute(
      path: '/dashboard',
      builder: (context, state) => const DashboardScreen(),
    ),
    GoRoute(
      path: '/node/:mac',
      builder: (context, state) {
        final mac = state.pathParameters['mac'] ?? 'Unknown';
        final extra = state.extra as Map<String, dynamic>?;
        final ip = extra?['ip'] ?? '';
        final name = extra?['name'] ?? '';
        final sensors = List<String>.from(
          extra?['sensors'] ?? const ['temperature', 'humidity'],
        );
        return NodeControlScreen(
          mac: mac,
          ip: ip,
          name: name,
          sensors: sensors,
        );
      },
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/profile',
      builder: (context, state) => const ProfileScreen(),
    ),
    GoRoute(
      path: '/settings/security',
      builder: (context, state) => const SecuritySettingsScreen(),
    ),

    GoRoute(
      path: '/settings/bulk-rules',
      builder: (context, state) => const BulkRulesScreen(),
    ),
    GoRoute(
      path: '/settings/access-control',
      builder: (context, state) => const AccessControlScreen(),
    ),
    GoRoute(
      path: '/settings/db-inspector',
      builder: (context, state) => const DatabaseInspectorScreen(),
    ),
    GoRoute(
      path: '/settings/debug-monitor',
      builder: (context, state) => const DebugMonitorScreen(),
    ),
  ],
);
