import 'dart:typed_data';

import '../models/report_data.dart';
import 'api_client.dart';

class ReportExport {
  const ReportExport({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

class ReportService {
  ReportService(this._apiClient);

  final ApiClient _apiClient;

  Future<ReportData> fetch({
    required DateTime startDate,
    required DateTime endDate,
    String? locationId,
  }) async {
    final payload = await _apiClient.get(
      _path('/reports', startDate, endDate, locationId),
    );
    return ReportData.fromJson(payload);
  }

  Future<ReportExport> exportCsv({
    required DateTime startDate,
    required DateTime endDate,
    String? locationId,
  }) async {
    final response = await _apiClient.download(
      _path('/reports/export.csv', startDate, endDate, locationId),
    );
    final fallback =
        'reports_${_dateParameter(startDate)}_to_${_dateParameter(endDate)}.csv';
    return ReportExport(
      bytes: response.bytes,
      filename: _safeFilename(response.filename ?? fallback, fallback),
    );
  }

  static String _path(
    String path,
    DateTime startDate,
    DateTime endDate,
    String? locationId,
  ) {
    return Uri(
      path: path,
      queryParameters: {
        'start_date': _dateParameter(startDate),
        'end_date': _dateParameter(endDate),
        'location_id': ?locationId,
      },
    ).toString();
  }

  static String _dateParameter(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }

  static String _safeFilename(String value, String fallback) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty || safe == '.' || safe == '..') return fallback;
    return safe.toLowerCase().endsWith('.csv') ? safe : '$safe.csv';
  }
}
