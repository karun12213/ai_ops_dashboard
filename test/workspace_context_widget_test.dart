import 'package:ai_ops_dashboard/app.dart';
import 'package:ai_ops_dashboard/models/dashboard_data.dart';
import 'package:ai_ops_dashboard/models/user.dart';
import 'package:ai_ops_dashboard/models/workspace_context.dart';
import 'package:ai_ops_dashboard/providers/auth_provider.dart';
import 'package:ai_ops_dashboard/providers/dashboard_provider.dart';
import 'package:ai_ops_dashboard/providers/workspace_provider.dart';
import 'package:ai_ops_dashboard/services/auth_service.dart';
import 'package:ai_ops_dashboard/services/dashboard_service.dart';
import 'package:ai_ops_dashboard/services/workspace_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('blocks Dashboard until an explicit workspace is created', (
    tester,
  ) async {
    final repository = _WidgetWorkspaceRepository(
      createdWorkspace: _ownerWorkspace,
    );
    final dashboard = _RecordingDashboardService();
    await _pumpAuthenticatedApp(
      tester,
      repository: repository,
      dashboard: dashboard,
      workspaceState: const WorkspaceState(isLoading: false),
    );

    expect(find.text('Create your workspace'), findsOneWidget);
    expect(dashboard.locationIds, isEmpty);

    await tester.enterText(
      find.byKey(const Key('workspace-name-field')),
      'Restaurant Group',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-location-field')),
      'Main Floor',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-currency-field')),
      'inr',
    );
    await tester.tap(find.byKey(const Key('workspace-submit-button')));
    await tester.pumpAndSettle();

    expect(repository.createWorkspaceCalls, 1);
    expect(find.text('Create your workspace'), findsNothing);
    expect(dashboard.locationIds, isNotEmpty);
    expect(dashboard.locationIds.last, 'location-1');
  });

  testWidgets('members cannot create a missing workspace location', (
    tester,
  ) async {
    final dashboard = _RecordingDashboardService();
    await _pumpAuthenticatedApp(
      tester,
      repository: _WidgetWorkspaceRepository(),
      dashboard: dashboard,
      workspaceState: const WorkspaceState(
        workspaces: [_memberWorkspaceWithoutLocations],
        activeWorkspaceId: 'workspace-member',
        isLoading: false,
      ),
    );

    expect(find.text('Add your first location'), findsOneWidget);
    expect(
      find.text(
        'A workspace owner must add a location before Dashboard, Reports, and Audio uploads are available.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('workspace-submit-button')), findsNothing);
    expect(find.byKey(const Key('workspace-retry-button')), findsOneWidget);
    expect(dashboard.locationIds, isEmpty);
  });

  testWidgets('switching authorized locations reloads Dashboard context', (
    tester,
  ) async {
    final dashboard = _RecordingDashboardService();
    await _pumpAuthenticatedApp(
      tester,
      repository: _WidgetWorkspaceRepository(),
      dashboard: dashboard,
      workspaceState: const WorkspaceState(
        workspaces: [_ownerWorkspace],
        activeWorkspaceId: 'workspace-1',
        activeLocationId: 'location-1',
        isLoading: false,
      ),
    );

    expect(dashboard.locationIds.last, 'location-1');

    await tester.tap(find.byKey(const Key('workspace-location-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terrace').last);
    await tester.pumpAndSettle();

    expect(dashboard.workspaceIds.last, 'workspace-1');
    expect(dashboard.locationIds.last, 'location-2');
  });
}

Future<void> _pumpAuthenticatedApp(
  WidgetTester tester, {
  required _WidgetWorkspaceRepository repository,
  required _RecordingDashboardService dashboard,
  required WorkspaceState workspaceState,
}) async {
  tester.view.physicalSize = const Size(1000, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(
          (ref) => AuthNotifier(_AuthenticatedAuthService()),
        ),
        workspaceProvider.overrideWith(
          (ref) => WorkspaceNotifier(
            repository,
            loadOnCreate: false,
            initialState: workspaceState,
          ),
        ),
        dashboardServiceProvider.overrideWithValue(dashboard),
      ],
      child: const RestaurantOpsApp(),
    ),
  );
  await tester.pumpAndSettle();
}

const _user = User(
  id: 'user-1',
  email: 'operator@example.com',
  fullName: 'Test Operator',
  isActive: true,
  isSuperuser: false,
);

const _ownerWorkspace = WorkspaceAccess(
  id: 'workspace-1',
  name: 'Restaurant Group',
  role: WorkspaceRole.owner,
  locations: [
    WorkspaceLocation(
      id: 'location-1',
      name: 'Main Floor',
      currencyCode: 'INR',
    ),
    WorkspaceLocation(id: 'location-2', name: 'Terrace', currencyCode: 'INR'),
  ],
);

const _memberWorkspaceWithoutLocations = WorkspaceAccess(
  id: 'workspace-member',
  name: 'Partner Restaurant',
  role: WorkspaceRole.member,
  locations: [],
);

class _AuthenticatedAuthService implements AuthService {
  @override
  Future<User?> restoreSession() async => _user;

  @override
  Future<User> login({required String email, required String password}) =>
      throw UnimplementedError();

  @override
  Future<void> logout() async {}

  @override
  Future<User> currentUser() async => _user;
}

class _WidgetWorkspaceRepository implements WorkspaceRepository {
  _WidgetWorkspaceRepository({this.createdWorkspace});

  final WorkspaceAccess? createdWorkspace;
  int createWorkspaceCalls = 0;

  @override
  Future<WorkspaceContext> fetchContext() async =>
      const WorkspaceContext(workspaces: []);

  @override
  Future<WorkspaceAccess> createWorkspace({
    required String name,
    required String locationName,
    required String currencyCode,
  }) async {
    createWorkspaceCalls += 1;
    expect(name, 'Restaurant Group');
    expect(locationName, 'Main Floor');
    expect(currencyCode, 'INR');
    return createdWorkspace!;
  }

  @override
  Future<WorkspaceLocation> createLocation({
    required String workspaceId,
    required String name,
    required String currencyCode,
  }) => throw UnimplementedError();
}

class _RecordingDashboardService implements DashboardService {
  final workspaceIds = <String>[];
  final locationIds = <String>[];

  @override
  Future<DashboardData> fetch({
    required DateTime serviceDate,
    required String workspaceId,
    required String locationId,
    int activityLimit = 10,
  }) async {
    workspaceIds.add(workspaceId);
    locationIds.add(locationId);
    return DashboardData(
      serviceDate: serviceDate,
      snapshot: null,
      recentActivity: const [],
    );
  }
}
