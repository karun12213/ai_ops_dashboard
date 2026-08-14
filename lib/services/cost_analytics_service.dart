import '../models/cost_analytics.dart';
import 'api_client.dart';

class CostAnalyticsService {
  CostAnalyticsService(this._apiClient);

  final ApiClient _apiClient;

  Future<CostAnalyticsData> fetch({
    required DateTime startDate,
    required DateTime endDate,
    required String workspaceId,
    String? locationId,
    int recentLimit = 25,
  }) async {
    final cleanWorkspaceId = workspaceId.trim();
    final cleanLocationId = locationId?.trim();
    if (cleanWorkspaceId.isEmpty) {
      throw ArgumentError('workspaceId cannot be empty');
    }
    if (locationId != null && cleanLocationId!.isEmpty) {
      throw ArgumentError('locationId cannot be empty');
    }
    if (endDate.isBefore(startDate)) {
      throw ArgumentError('endDate must be on or after startDate');
    }
    if (recentLimit < 1 || recentLimit > 100) {
      throw ArgumentError.value(
        recentLimit,
        'recentLimit',
        'must be between 1 and 100',
      );
    }
    final path = Uri(
      path: '/cost-analytics',
      queryParameters: {
        'start_date': _dateParameter(startDate),
        'end_date': _dateParameter(endDate),
        'workspace_id': cleanWorkspaceId,
        'location_id': ?cleanLocationId,
        'recent_limit': recentLimit.toString(),
      },
    ).toString();
    final payload = await _apiClient.get(path);
    return CostAnalyticsData.fromJson(payload);
  }

  static String _dateParameter(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}
