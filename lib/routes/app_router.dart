import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../screens/audio_upload_screen.dart';
import '../screens/dashboard_screen.dart';
import '../screens/login_screen.dart';
import '../screens/reports_screen.dart';
import '../screens/settings_screen.dart';
import '../widgets/app_shell.dart';

abstract final class AppRoutes {
  static const login = '/login';
  static const dashboard = '/dashboard';
  static const reports = '/reports';
  static const audioUpload = '/audio-upload';
  static const settings = '/settings';
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: AppRoutes.dashboard,
    redirect: (context, state) {
      final authState = ref.read(authProvider);
      if (authState.status == AuthStatus.loading) return null;
      final atLogin = state.matchedLocation == AppRoutes.login;
      if (!authState.isAuthenticated && !atLogin) return AppRoutes.login;
      if (authState.isAuthenticated && atLogin) return AppRoutes.dashboard;
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.dashboard,
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: AppRoutes.reports,
            builder: (context, state) => const ReportsScreen(),
          ),
          GoRoute(
            path: AppRoutes.audioUpload,
            builder: (context, state) => const AudioUploadScreen(),
          ),
          GoRoute(
            path: AppRoutes.settings,
            builder: (context, state) => const SettingsScreen(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_off_outlined, size: 54),
            const SizedBox(height: 16),
            Text(
              'Page not found',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go(AppRoutes.dashboard),
              child: const Text('Return to dashboard'),
            ),
          ],
        ),
      ),
    ),
  );

  ref.listen<AuthState>(authProvider, (_, _) => router.refresh());
  ref.onDispose(router.dispose);
  return router;
});
