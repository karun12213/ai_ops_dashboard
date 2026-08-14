class CostAnalyticsData {
  const CostAnalyticsData({
    required this.startDate,
    required this.endDate,
    required this.locationId,
    required this.metrics,
    required this.byLocation,
    required this.bySeverity,
    required this.byCategory,
    required this.recentUsage,
  });

  final DateTime startDate;
  final DateTime endDate;
  final String? locationId;
  final CostAnalyticsMetrics metrics;
  final List<CostAnalyticsBreakdown> byLocation;
  final List<CostAnalyticsBreakdown> bySeverity;
  final List<CostAnalyticsBreakdown> byCategory;
  final List<CostAnalyticsRecentUsage> recentUsage;

  factory CostAnalyticsData.fromJson(Map<String, dynamic> json) {
    return CostAnalyticsData(
      startDate: DateTime.parse(_string(json, 'start_date')),
      endDate: DateTime.parse(_string(json, 'end_date')),
      locationId: _nullableString(json['location_id']),
      metrics: CostAnalyticsMetrics.fromJson(_map(json['metrics'], 'metrics')),
      byLocation: _list(json, 'by_location')
          .map(
            (item) =>
                CostAnalyticsBreakdown.fromJson(_map(item, 'by_location item')),
          )
          .toList(growable: false),
      bySeverity: _list(json, 'by_severity')
          .map(
            (item) =>
                CostAnalyticsBreakdown.fromJson(_map(item, 'by_severity item')),
          )
          .toList(growable: false),
      byCategory: _list(json, 'by_category')
          .map(
            (item) =>
                CostAnalyticsBreakdown.fromJson(_map(item, 'by_category item')),
          )
          .toList(growable: false),
      recentUsage: _list(json, 'recent_usage')
          .map(
            (item) => CostAnalyticsRecentUsage.fromJson(
              _map(item, 'recent_usage item'),
            ),
          )
          .toList(growable: false),
    );
  }
}

class CostAnalyticsMetrics {
  const CostAnalyticsMetrics({
    required this.totalAudioUploads,
    required this.costedAudioUploads,
    required this.missingCostDataUploads,
    required this.totalRecordedAudioDurationSeconds,
    required this.costedAudioDurationSeconds,
    required this.totalSarvamCostInr,
    required this.totalOpenAiCostUsd,
    required this.averageSarvamCostPerUploadInr,
    required this.averageOpenAiCostPerUploadUsd,
    required this.averageSarvamCostPerRecordedMinuteInr,
    required this.averageOpenAiCostPerRecordedMinuteUsd,
    required this.estimatedSarvamCostPerRecordedHourInr,
    required this.estimatedOpenAiCostPerRecordedHourUsd,
  });

  final int totalAudioUploads;
  final int costedAudioUploads;
  final int missingCostDataUploads;
  final double totalRecordedAudioDurationSeconds;
  final double costedAudioDurationSeconds;
  final double? totalSarvamCostInr;
  final double? totalOpenAiCostUsd;
  final double? averageSarvamCostPerUploadInr;
  final double? averageOpenAiCostPerUploadUsd;
  final double? averageSarvamCostPerRecordedMinuteInr;
  final double? averageOpenAiCostPerRecordedMinuteUsd;
  final double? estimatedSarvamCostPerRecordedHourInr;
  final double? estimatedOpenAiCostPerRecordedHourUsd;

  factory CostAnalyticsMetrics.fromJson(Map<String, dynamic> json) {
    return CostAnalyticsMetrics(
      totalAudioUploads: _integer(json, 'total_audio_uploads'),
      costedAudioUploads: _integer(json, 'costed_audio_uploads'),
      missingCostDataUploads: _integer(json, 'missing_cost_data_uploads'),
      totalRecordedAudioDurationSeconds: _number(
        json,
        'total_recorded_audio_duration_seconds',
      ),
      costedAudioDurationSeconds: _number(
        json,
        'costed_audio_duration_seconds',
      ),
      totalSarvamCostInr: _nullableNumber(json['total_sarvam_cost_inr']),
      totalOpenAiCostUsd: _nullableNumber(json['total_openai_cost_usd']),
      averageSarvamCostPerUploadInr: _nullableNumber(
        json['average_sarvam_cost_per_upload_inr'],
      ),
      averageOpenAiCostPerUploadUsd: _nullableNumber(
        json['average_openai_cost_per_upload_usd'],
      ),
      averageSarvamCostPerRecordedMinuteInr: _nullableNumber(
        json['average_sarvam_cost_per_recorded_minute_inr'],
      ),
      averageOpenAiCostPerRecordedMinuteUsd: _nullableNumber(
        json['average_openai_cost_per_recorded_minute_usd'],
      ),
      estimatedSarvamCostPerRecordedHourInr: _nullableNumber(
        json['estimated_sarvam_cost_per_recorded_hour_inr'],
      ),
      estimatedOpenAiCostPerRecordedHourUsd: _nullableNumber(
        json['estimated_openai_cost_per_recorded_hour_usd'],
      ),
    );
  }
}

class CostAnalyticsBreakdown {
  const CostAnalyticsBreakdown({
    required this.key,
    required this.label,
    required this.totalAudioUploads,
    required this.costedAudioUploads,
    required this.missingCostDataUploads,
    required this.recordedAudioDurationSeconds,
    required this.sarvamCostInr,
    required this.openAiCostUsd,
  });

  final String key;
  final String label;
  final int totalAudioUploads;
  final int costedAudioUploads;
  final int missingCostDataUploads;
  final double recordedAudioDurationSeconds;
  final double? sarvamCostInr;
  final double? openAiCostUsd;

  factory CostAnalyticsBreakdown.fromJson(Map<String, dynamic> json) {
    return CostAnalyticsBreakdown(
      key: _string(json, 'key'),
      label: _string(json, 'label'),
      totalAudioUploads: _integer(json, 'total_audio_uploads'),
      costedAudioUploads: _integer(json, 'costed_audio_uploads'),
      missingCostDataUploads: _integer(json, 'missing_cost_data_uploads'),
      recordedAudioDurationSeconds: _number(
        json,
        'recorded_audio_duration_seconds',
      ),
      sarvamCostInr: _nullableNumber(json['sarvam_cost_inr']),
      openAiCostUsd: _nullableNumber(json['openai_cost_usd']),
    );
  }
}

class CostAnalyticsRecentUsage {
  const CostAnalyticsRecentUsage({
    required this.uploadId,
    required this.processedAt,
    required this.originalFilename,
    required this.audioDurationSeconds,
    required this.category,
    required this.severity,
    required this.sarvamEstimatedCostInr,
    required this.openAiEstimatedCostUsd,
    required this.openAiTotalTokens,
  });

  final String uploadId;
  final DateTime processedAt;
  final String originalFilename;
  final double? audioDurationSeconds;
  final String category;
  final String severity;
  final double? sarvamEstimatedCostInr;
  final double? openAiEstimatedCostUsd;
  final int? openAiTotalTokens;

  bool get hasCostData =>
      sarvamEstimatedCostInr != null && openAiEstimatedCostUsd != null;

  factory CostAnalyticsRecentUsage.fromJson(Map<String, dynamic> json) {
    return CostAnalyticsRecentUsage(
      uploadId: _string(json, 'upload_id'),
      processedAt: DateTime.parse(_string(json, 'processed_at')),
      originalFilename: _string(json, 'original_filename'),
      audioDurationSeconds: _nullableNumber(json['audio_duration_seconds']),
      category: _string(json, 'category'),
      severity: _string(json, 'severity'),
      sarvamEstimatedCostInr: _nullableNumber(
        json['sarvam_estimated_cost_inr'],
      ),
      openAiEstimatedCostUsd: _nullableNumber(
        json['openai_estimated_cost_usd'],
      ),
      openAiTotalTokens: _nullableInteger(json['openai_total_tokens']),
    );
  }
}

Map<String, dynamic> _map(Object? value, String label) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('Invalid cost analytics $label.');
  }
  return value;
}

List<dynamic> _list(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('Invalid cost analytics $key.');
  return value;
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid cost analytics $key.');
  }
  return value;
}

String? _nullableString(Object? value) {
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw const FormatException('Invalid nullable cost analytics string.');
  }
  return value;
}

int _integer(Map<String, dynamic> json, String key) {
  final value = _nullableInteger(json[key]);
  if (value == null) throw FormatException('Invalid cost analytics $key.');
  return value;
}

int? _nullableInteger(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw const FormatException('Invalid cost analytics integer.');
}

double _number(Map<String, dynamic> json, String key) {
  final value = _nullableNumber(json[key]);
  if (value == null) throw FormatException('Invalid cost analytics $key.');
  return value;
}

double? _nullableNumber(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw const FormatException('Invalid cost analytics number.');
}
