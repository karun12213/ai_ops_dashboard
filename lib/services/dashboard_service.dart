import '../models/dashboard_data.dart';
import 'api_client.dart';

class DashboardService {
  DashboardService(this._apiClient);

  final ApiClient _apiClient;

  /// Loads the operational Dashboard snapshot for one local service date.
  Future<DashboardData> fetch({
    required DateTime serviceDate,
    required String workspaceId,
    required String locationId,
    int activityLimit = 10,
  }) async {
    final cleanWorkspaceId = workspaceId.trim();
    final cleanLocationId = locationId.trim();

    if (cleanWorkspaceId.isEmpty) {
      throw ArgumentError('workspaceId cannot be empty');
    }

    if (cleanLocationId.isEmpty) {
      throw ArgumentError('locationId cannot be empty');
    }

    if (activityLimit < 1 || activityLimit > 50) {
      throw ArgumentError.value(
        activityLimit,
        'activityLimit',
        'must be between 1 and 50',
      );
    }

    final date = _dateParameter(serviceDate);

    final path = Uri(
      path: '/dashboard',
      queryParameters: {
        'service_date': date,
        'workspace_id': cleanWorkspaceId,
        'location_id': cleanLocationId,
        'activity_limit': activityLimit.toString(),
      },
    ).toString();

    final payload = await _apiClient.get(path);

    return DashboardData.fromJson(payload);
  }

  static String _dateParameter(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');

    return '${value.year}-$month-$day';
  }
}
