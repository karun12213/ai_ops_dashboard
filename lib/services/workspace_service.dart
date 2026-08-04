import '../models/workspace_context.dart';
import 'api_client.dart';

abstract interface class WorkspaceRepository {
  Future<WorkspaceContext> fetchContext();

  Future<WorkspaceAccess> createWorkspace({
    required String name,
    required String locationName,
    required String currencyCode,
  });

  Future<WorkspaceLocation> createLocation({
    required String workspaceId,
    required String name,
    required String currencyCode,
  });
}

class WorkspaceService implements WorkspaceRepository {
  WorkspaceService(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<WorkspaceContext> fetchContext() async {
    final payload = await _apiClient.get('/workspaces/context');
    return WorkspaceContext.fromJson(payload);
  }

  @override
  Future<WorkspaceAccess> createWorkspace({
    required String name,
    required String locationName,
    required String currencyCode,
  }) async {
    final payload = await _apiClient.post(
      '/workspaces',
      body: {
        'name': name,
        'location_name': locationName,
        'currency_code': currencyCode,
      },
    );
    return WorkspaceAccess.fromJson(payload);
  }

  @override
  Future<WorkspaceLocation> createLocation({
    required String workspaceId,
    required String name,
    required String currencyCode,
  }) async {
    final payload = await _apiClient.post(
      '/workspaces/$workspaceId/locations',
      body: {'name': name, 'currency_code': currencyCode},
    );
    return WorkspaceLocation.fromJson(payload);
  }
}
