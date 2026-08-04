import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/dashboard_data.dart';
import '../services/dashboard_service.dart';
import 'auth_provider.dart';
import 'workspace_provider.dart';

/// The service date currently selected on the Dashboard.
final dashboardDateProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

/// API-backed service used to load Dashboard data.
final dashboardServiceProvider = Provider<DashboardService>((ref) {
  return DashboardService(ref.watch(apiClientProvider));
});

/// Live Dashboard payload for the selected service date.
final dashboardProvider = FutureProvider.autoDispose<DashboardData>((ref) {
  final date = ref.watch(dashboardDateProvider);
  final workspaceState = ref.watch(workspaceProvider);
  final workspace = workspaceState.activeWorkspace;
  final location = workspaceState.activeLocation;
  if (workspace == null || location == null) {
    throw StateError('Workspace location context is required.');
  }
  return ref
      .watch(dashboardServiceProvider)
      .fetch(
        serviceDate: date,
        workspaceId: workspace.id,
        locationId: location.id,
      );
});
