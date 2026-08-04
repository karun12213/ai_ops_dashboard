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
  }) async {
    final date = _dateParameter(serviceDate);
    final path = Uri(
      path: '/dashboard',
      queryParameters: {
        'service_date': date,
        'workspace_id': workspaceId,
        'location_id': locationId,
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
