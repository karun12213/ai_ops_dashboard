import 'package:ai_ops_dashboard/models/workspace_context.dart';
import 'package:ai_ops_dashboard/providers/workspace_provider.dart';
import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/workspace_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('load preserves valid context and rejects invalid selections', () async {
    final repository = _FakeWorkspaceRepository(context: _context);
    final notifier = WorkspaceNotifier(
      repository,
      loadOnCreate: false,
      initialState: const WorkspaceState(
        activeWorkspaceId: 'workspace-2',
        activeLocationId: 'location-3',
        isLoading: false,
      ),
    );
    addTearDown(notifier.dispose);

    await notifier.load();

    expect(notifier.state.activeWorkspace?.id, 'workspace-2');
    expect(notifier.state.activeLocation?.id, 'location-3');
    expect(notifier.state.hasReadyContext, isTrue);

    notifier.selectLocation(
      workspaceId: 'workspace-1',
      locationId: 'not-authorized',
    );
    expect(notifier.state.activeWorkspace?.id, 'workspace-2');

    notifier.selectLocation(
      workspaceId: 'workspace-1',
      locationId: 'location-2',
    );
    expect(notifier.state.activeWorkspace?.id, 'workspace-1');
    expect(notifier.state.activeLocation?.id, 'location-2');
  });

  test('load chooses the first available authorized location', () async {
    final notifier = WorkspaceNotifier(
      _FakeWorkspaceRepository(context: _context),
      loadOnCreate: false,
      initialState: const WorkspaceState(isLoading: false),
    );
    addTearDown(notifier.dispose);

    await notifier.load();

    expect(notifier.state.activeWorkspace?.id, 'workspace-1');
    expect(notifier.state.activeLocation?.id, 'location-1');
    expect(notifier.state.loadError, isNull);
  });

  test(
    'initial load skips inaccessible empty workspaces when possible',
    () async {
      const emptyMembership = WorkspaceAccess(
        id: 'workspace-empty',
        name: 'Empty Membership',
        role: WorkspaceRole.member,
        locations: [],
      );
      final notifier = WorkspaceNotifier(
        _FakeWorkspaceRepository(
          context: const WorkspaceContext(
            workspaces: [emptyMembership, _workspaceOne],
          ),
        ),
        loadOnCreate: false,
        initialState: const WorkspaceState(isLoading: false),
      );
      addTearDown(notifier.dispose);

      await notifier.load();

      expect(notifier.state.activeWorkspace?.id, 'workspace-1');
      expect(notifier.state.activeLocation?.id, 'location-1');
    },
  );

  test(
    'creates and activates a workspace without mutating prior access',
    () async {
      final repository = _FakeWorkspaceRepository(
        context: const WorkspaceContext(workspaces: []),
        createdWorkspace: _createdWorkspace,
      );
      final notifier = WorkspaceNotifier(
        repository,
        loadOnCreate: false,
        initialState: const WorkspaceState(
          workspaces: [_workspaceOne],
          activeWorkspaceId: 'workspace-1',
          activeLocationId: 'location-1',
          isLoading: false,
        ),
      );
      addTearDown(notifier.dispose);

      final created = await notifier.createWorkspace(
        name: 'New Restaurant',
        locationName: 'Courtyard',
        currencyCode: 'USD',
      );

      expect(created, isTrue);
      expect(repository.createWorkspaceCalls, 1);
      expect(notifier.state.workspaces, [_workspaceOne, _createdWorkspace]);
      expect(notifier.state.activeWorkspace?.id, 'workspace-3');
      expect(notifier.state.activeLocation?.id, 'location-4');
    },
  );

  test('only owners can create and activate another location', () async {
    final repository = _FakeWorkspaceRepository(
      context: _context,
      createdLocation: _terrace,
    );
    final ownerNotifier = WorkspaceNotifier(
      repository,
      loadOnCreate: false,
      initialState: const WorkspaceState(
        workspaces: [_workspaceOne],
        activeWorkspaceId: 'workspace-1',
        activeLocationId: 'location-1',
        isLoading: false,
      ),
    );
    addTearDown(ownerNotifier.dispose);

    final created = await ownerNotifier.createLocation(
      name: 'Terrace',
      currencyCode: 'INR',
    );

    expect(created, isTrue);
    expect(ownerNotifier.state.activeLocation?.id, 'location-new');
    expect(ownerNotifier.state.activeWorkspace?.locations, hasLength(3));

    final memberNotifier = WorkspaceNotifier(
      repository,
      loadOnCreate: false,
      initialState: const WorkspaceState(
        workspaces: [_workspaceTwo],
        activeWorkspaceId: 'workspace-2',
        activeLocationId: 'location-3',
        isLoading: false,
      ),
    );
    addTearDown(memberNotifier.dispose);

    final denied = await memberNotifier.createLocation(
      name: 'Unauthorized',
      currencyCode: 'INR',
    );

    expect(denied, isFalse);
    expect(repository.createLocationCalls, 1);
  });

  test('exposes safe load and submission failures', () async {
    final repository = _FakeWorkspaceRepository(
      contextError: StateError('database connection details'),
      createWorkspaceError: const ApiException(
        'Workspace could not be created',
        statusCode: 409,
      ),
    );
    final notifier = WorkspaceNotifier(
      repository,
      loadOnCreate: false,
      initialState: const WorkspaceState(isLoading: false),
    );
    addTearDown(notifier.dispose);

    await notifier.load();
    expect(notifier.state.loadError, 'Workspace access could not be loaded.');
    expect(notifier.state.loadError, isNot(contains('database')));

    final created = await notifier.createWorkspace(
      name: 'Restaurant',
      locationName: 'Main',
      currencyCode: 'INR',
    );
    expect(created, isFalse);
    expect(notifier.state.submissionError, 'Workspace could not be created');
    expect(notifier.state.isSubmitting, isFalse);
  });

  test(
    'identifies an unauthorized workspace context without leaking detail',
    () async {
      final notifier = WorkspaceNotifier(
        _FakeWorkspaceRepository(
          contextError: const ApiException(
            'unsafe authentication detail',
            statusCode: 401,
          ),
        ),
        loadOnCreate: false,
        initialState: const WorkspaceState(isLoading: false),
      );
      addTearDown(notifier.dispose);

      await notifier.load();

      expect(
        notifier.state.loadError,
        'Your session has expired. Please sign in again.',
      );
      expect(notifier.state.loadError, isNot(contains('unsafe')));
    },
  );
}

const _context = WorkspaceContext(workspaces: [_workspaceOne, _workspaceTwo]);

const _workspaceOne = WorkspaceAccess(
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

const _workspaceTwo = WorkspaceAccess(
  id: 'workspace-2',
  name: 'Partner Restaurant',
  role: WorkspaceRole.member,
  locations: [
    WorkspaceLocation(
      id: 'location-3',
      name: 'Dining Room',
      currencyCode: 'INR',
    ),
  ],
);

const _createdWorkspace = WorkspaceAccess(
  id: 'workspace-3',
  name: 'New Restaurant',
  role: WorkspaceRole.owner,
  locations: [
    WorkspaceLocation(id: 'location-4', name: 'Courtyard', currencyCode: 'USD'),
  ],
);

const _terrace = WorkspaceLocation(
  id: 'location-new',
  name: 'Terrace',
  currencyCode: 'INR',
);

class _FakeWorkspaceRepository implements WorkspaceRepository {
  _FakeWorkspaceRepository({
    this.context,
    this.createdWorkspace,
    this.createdLocation,
    this.contextError,
    this.createWorkspaceError,
  });

  final WorkspaceContext? context;
  final WorkspaceAccess? createdWorkspace;
  final WorkspaceLocation? createdLocation;
  final Object? contextError;
  final Object? createWorkspaceError;
  int createWorkspaceCalls = 0;
  int createLocationCalls = 0;

  @override
  Future<WorkspaceContext> fetchContext() async {
    if (contextError case final error?) throw error;
    return context!;
  }

  @override
  Future<WorkspaceAccess> createWorkspace({
    required String name,
    required String locationName,
    required String currencyCode,
  }) async {
    createWorkspaceCalls += 1;
    if (createWorkspaceError case final error?) throw error;
    return createdWorkspace!;
  }

  @override
  Future<WorkspaceLocation> createLocation({
    required String workspaceId,
    required String name,
    required String currencyCode,
  }) async {
    createLocationCalls += 1;
    return createdLocation!;
  }
}
