import '../models/dashboard_data.dart';
import 'api_client.dart';

class DashboardService {
  DashboardService(this._apiClient);

  final ApiClient _apiClient;

  /// Loads the operational Dashboard snapshot for one local service date.
  Future<DashboardData> fetch(DateTime serviceDate) async {
    final date = _dateParameter(serviceDate);
    final payload = await _apiClient.get('/dashboard?service_date=$date');
    return DashboardData.fromJson(payload);
  }

  static String _dateParameter(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}
