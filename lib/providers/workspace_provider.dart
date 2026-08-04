import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/workspace_context.dart';
import '../services/api_client.dart';
import '../services/workspace_service.dart';
import 'auth_provider.dart';

class WorkspaceState {
  const WorkspaceState({
    this.workspaces = const [],
    this.activeWorkspaceId,
    this.activeLocationId,
    this.isLoading = true,
    this.isSubmitting = false,
    this.loadError,
    this.submissionError,
  });

  final List<WorkspaceAccess> workspaces;
  final String? activeWorkspaceId;
  final String? activeLocationId;
  final bool isLoading;
  final bool isSubmitting;
  final String? loadError;
  final String? submissionError;

  WorkspaceAccess? get activeWorkspace {
    for (final workspace in workspaces) {
      if (workspace.id == activeWorkspaceId) return workspace;
    }
    return workspaces.isEmpty ? null : workspaces.first;
  }

  WorkspaceLocation? get activeLocation =>
      activeWorkspace?.locationById(activeLocationId);

  bool get hasReadyContext => activeWorkspace != null && activeLocation != null;

  WorkspaceState copyWith({
    List<WorkspaceAccess>? workspaces,
    Object? activeWorkspaceId = _unchanged,
    Object? activeLocationId = _unchanged,
    bool? isLoading,
    bool? isSubmitting,
    Object? loadError = _unchanged,
    Object? submissionError = _unchanged,
  }) {
    return WorkspaceState(
      workspaces: workspaces ?? this.workspaces,
      activeWorkspaceId: identical(activeWorkspaceId, _unchanged)
          ? this.activeWorkspaceId
          : activeWorkspaceId as String?,
      activeLocationId: identical(activeLocationId, _unchanged)
          ? this.activeLocationId
          : activeLocationId as String?,
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      loadError: identical(loadError, _unchanged)
          ? this.loadError
          : loadError as String?,
      submissionError: identical(submissionError, _unchanged)
          ? this.submissionError
          : submissionError as String?,
    );
  }
}

const _unchanged = Object();

final workspaceServiceProvider = Provider<WorkspaceRepository>((ref) {
  return WorkspaceService(ref.watch(apiClientProvider));
});

final workspaceProvider =
    StateNotifierProvider.autoDispose<WorkspaceNotifier, WorkspaceState>((ref) {
      return WorkspaceNotifier(ref.watch(workspaceServiceProvider));
    });

class WorkspaceNotifier extends StateNotifier<WorkspaceState> {
  WorkspaceNotifier(
    this._repository, {
    bool loadOnCreate = true,
    WorkspaceState? initialState,
  }) : super(initialState ?? WorkspaceState(isLoading: loadOnCreate)) {
    if (loadOnCreate) load();
  }

  final WorkspaceRepository _repository;

  Future<void> load() async {
    state = state.copyWith(isLoading: true, loadError: null);
    try {
      final context = await _repository.fetchContext();
      if (!mounted) return;
      final selection = _validSelection(
        context.workspaces,
        state.activeWorkspaceId,
        state.activeLocationId,
      );
      state = state.copyWith(
        workspaces: context.workspaces,
        activeWorkspaceId: selection.$1,
        activeLocationId: selection.$2,
        isLoading: false,
        loadError: null,
      );
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        loadError: 'Workspace access could not be loaded.',
      );
    }
  }

  void selectLocation({
    required String workspaceId,
    required String locationId,
  }) {
    final workspace = state.workspaces
        .where((item) => item.id == workspaceId)
        .firstOrNull;
    if (workspace?.locationById(locationId) == null) return;
    state = state.copyWith(
      activeWorkspaceId: workspaceId,
      activeLocationId: locationId,
    );
  }

  Future<bool> createWorkspace({
    required String name,
    required String locationName,
    required String currencyCode,
  }) async {
    state = state.copyWith(isSubmitting: true, submissionError: null);
    try {
      final created = await _repository.createWorkspace(
        name: name,
        locationName: locationName,
        currencyCode: currencyCode,
      );
      if (!mounted) return false;
      state = state.copyWith(
        workspaces: [...state.workspaces, created],
        activeWorkspaceId: created.id,
        activeLocationId: created.locations.firstOrNull?.id,
        isSubmitting: false,
        submissionError: null,
      );
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        isSubmitting: false,
        submissionError: error.message,
      );
      return false;
    } catch (_) {
      if (!mounted) return false;
      state = state.copyWith(
        isSubmitting: false,
        submissionError: 'Workspace creation could not be completed.',
      );
      return false;
    }
  }

  Future<bool> createLocation({
    required String name,
    required String currencyCode,
  }) async {
    final workspace = state.activeWorkspace;
    if (workspace == null || workspace.role != WorkspaceRole.owner) {
      return false;
    }
    state = state.copyWith(isSubmitting: true, submissionError: null);
    try {
      final location = await _repository.createLocation(
        workspaceId: workspace.id,
        name: name,
        currencyCode: currencyCode,
      );
      if (!mounted) return false;
      final updatedWorkspace = WorkspaceAccess(
        id: workspace.id,
        name: workspace.name,
        role: workspace.role,
        locations: [...workspace.locations, location],
      );
      state = state.copyWith(
        workspaces: [
          for (final item in state.workspaces)
            if (item.id == workspace.id) updatedWorkspace else item,
        ],
        activeLocationId: location.id,
        isSubmitting: false,
        submissionError: null,
      );
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        isSubmitting: false,
        submissionError: error.message,
      );
      return false;
    } catch (_) {
      if (!mounted) return false;
      state = state.copyWith(
        isSubmitting: false,
        submissionError: 'Location creation could not be completed.',
      );
      return false;
    }
  }

  void clearSubmissionError() {
    state = state.copyWith(submissionError: null);
  }

  static (String?, String?) _validSelection(
    List<WorkspaceAccess> workspaces,
    String? workspaceId,
    String? locationId,
  ) {
    WorkspaceAccess? workspace;
    for (final item in workspaces) {
      if (item.id == workspaceId) workspace = item;
    }
    workspace ??= workspaces
        .where((item) => item.locations.isNotEmpty)
        .firstOrNull;
    workspace ??= workspaces.firstOrNull;
    if (workspace == null) return (null, null);
    final location =
        workspace.locationById(locationId) ?? workspace.locations.firstOrNull;
    return (workspace.id, location?.id);
  }
}
