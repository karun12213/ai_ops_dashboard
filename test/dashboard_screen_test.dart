import 'dart:async';

import 'package:ai_ops_dashboard/models/dashboard_data.dart';
import 'package:ai_ops_dashboard/models/workspace_context.dart';
import 'package:ai_ops_dashboard/providers/dashboard_provider.dart';
import 'package:ai_ops_dashboard/providers/workspace_provider.dart';
import 'package:ai_ops_dashboard/screens/dashboard_screen.dart';
import 'package:ai_ops_dashboard/services/dashboard_service.dart';
import 'package:ai_ops_dashboard/services/workspace_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a loading state while Dashboard data is pending', (
    tester,
  ) async {
    final completer = Completer<DashboardData>();
    await _pumpDashboard(
      tester,
      _FakeDashboardService((_) => completer.future),
    );

    expect(find.text('Loading Dashboard…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(_emptyData);
    await tester.pumpAndSettle();
  });

  testWidgets('shows the API empty state without manufactured metrics', (
    tester,
  ) async {
    await _pumpDashboard(
      tester,
      _FakeDashboardService((_) async => _emptyData),
    );
    await tester.pumpAndSettle();

    expect(find.text('No Dashboard data yet'), findsOneWidget);
    expect(find.text('Net sales'), findsNothing);
    expect(find.text('Dinner shift opened'), findsNothing);
  });

  testWidgets('shows a safe error and retries the Dashboard request', (
    tester,
  ) async {
    var requests = 0;
    final service = _FakeDashboardService((_) async {
      requests += 1;
      if (requests == 1) throw StateError('Sensitive backend detail');
      return _emptyData;
    });
    await _pumpDashboard(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('Dashboard data is unavailable'), findsOneWidget);
    expect(find.text('Sensitive backend detail'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pumpAndSettle();

    expect(requests, 2);
    expect(find.text('No Dashboard data yet'), findsOneWidget);
  });

  testWidgets('renders live metrics, pulse, sales, and activity data', (
    tester,
  ) async {
    await _pumpDashboard(
      tester,
      _FakeDashboardService((_) async => _populatedData),
    );
    await tester.pumpAndSettle();

    expect(find.text('\u20B9102'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('\u20B925.50'), findsOneWidget);
    expect(find.text('47 min'), findsOneWidget);
    expect(find.text('11 of 20 tables'), findsOneWidget);
    expect(find.text('7 active tickets'), findsOneWidget);
    expect(find.text('Dinner shift opened'), findsOneWidget);
    expect(find.text('Floor Manager'), findsOneWidget);
    expect(find.text('No Dashboard data yet'), findsNothing);
  });
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  DashboardService service,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workspaceProvider.overrideWith(
          (ref) => WorkspaceNotifier(
            _UnusedWorkspaceRepository(),
            loadOnCreate: false,
            initialState: _workspaceState,
          ),
        ),
        dashboardDateProvider.overrideWith((ref) => DateTime(2026, 8, 3)),
        dashboardServiceProvider.overrideWith((ref) => service),
      ],
      child: const MaterialApp(home: Scaffold(body: DashboardScreen())),
    ),
  );
  await tester.pump();
}

class _FakeDashboardService implements DashboardService {
  _FakeDashboardService(this.onFetch);

  final Future<DashboardData> Function(DateTime date) onFetch;

  @override
  Future<DashboardData> fetch({
    required DateTime serviceDate,
    required String workspaceId,
    required String locationId,
    int activityLimit = 10,
  }) => onFetch(serviceDate);
}

const _workspace = WorkspaceAccess(
  id: 'workspace-1',
  name: 'Restaurant',
  role: WorkspaceRole.owner,
  locations: [
    WorkspaceLocation(
      id: 'location-1',
      name: 'Main Floor',
      currencyCode: 'INR',
    ),
  ],
);

const _workspaceState = WorkspaceState(
  workspaces: [_workspace],
  activeWorkspaceId: 'workspace-1',
  activeLocationId: 'location-1',
  isLoading: false,
);

class _UnusedWorkspaceRepository implements WorkspaceRepository {
  @override
  Future<WorkspaceContext> fetchContext() => throw UnimplementedError();

  @override
  Future<WorkspaceAccess> createWorkspace({
    required String name,
    required String locationName,
    required String currencyCode,
  }) => throw UnimplementedError();

  @override
  Future<WorkspaceLocation> createLocation({
    required String workspaceId,
    required String name,
    required String currencyCode,
  }) => throw UnimplementedError();
}

final _emptyData = DashboardData(
  serviceDate: DateTime(2026, 8, 3),
  snapshot: null,
  recentActivity: const [],
);

final _populatedData = DashboardData(
  serviceDate: DateTime(2026, 8, 3),
  snapshot: DashboardSnapshot(
    updatedAt: DateTime.utc(2026, 8, 3, 12, 30),
    serviceOpen: true,
    metrics: const DashboardMetrics(
      currencyCode: 'INR',
      netSalesMinor: 10200,
      netSalesChangePercent: 12.4,
      ordersServed: 4,
      ordersChangePercent: 8.1,
      averageTicketMinor: 2550,
      averageTicketChangePercent: null,
      averageTableTurnMinutes: 47,
      tableTurnChangePercent: -5.2,
    ),
    hourlySales: const [
      DashboardHourlySales(hour: 17, netSalesMinor: 3000),
      DashboardHourlySales(hour: 18, netSalesMinor: 7200),
    ],
    servicePulse: const DashboardServicePulse(
      occupiedTables: 11,
      totalTables: 20,
      activeKitchenTickets: 7,
      kitchenCapacity: 16,
      pickupOrders: 3,
      pickupCapacity: 10,
      staffOnShift: 15,
      staffScheduled: 18,
    ),
  ),
  recentActivity: [
    DashboardActivity(
      id: '95cd56e6-228e-47dc-8fb4-3ac8760c2082',
      occurredAt: DateTime.utc(2026, 8, 3, 17, 2),
      title: 'Dinner shift opened',
      actor: 'Floor Manager',
      category: 'service',
    ),
  ],
);
