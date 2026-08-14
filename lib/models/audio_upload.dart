import 'audio_api_cost.dart';

enum AudioUploadStatus { processing, ready, failed, quarantined }

enum AudioScanStatus { notConfigured, clean, infected, error }

enum AudioAnalysisSeverity { low, medium, high, critical }

enum AudioProcessingStage {
  uploaded,
  validating,
  normalizing,
  transcribing,
  translating,
  analyzing,
  savingReport,
  completed,
  failed,
}

class AudioUpload {
  const AudioUpload({
    required this.id,
    required this.originalFilename,
    required this.mediaType,
    required this.extension,
    required this.sizeBytes,
    required this.status,
    required this.scanStatus,
    required this.createdAt,
    required this.updatedAt,
    this.locationId,
    this.languageCode,
    this.detectedLanguageCode,
    this.processingStage = AudioProcessingStage.uploaded,
    this.failureStage,
    this.failureCode,
    this.failureMessage,
    this.retryable = true,
    this.audioContainer,
    this.audioCodec,
    this.audioDurationSeconds,
    this.audioSampleRate,
    this.audioChannels,
    this.transcriptionStrategy,
    this.transcriptAvailable = false,
    this.reportId,
    this.severity,
    this.processedAt,
    this.locationName,
    this.source,
    this.apiCost = const AudioApiCost(),
  });

  final String id;
  final String originalFilename;
  final String mediaType;
  final String extension;
  final int sizeBytes;
  final AudioUploadStatus status;
  final AudioScanStatus scanStatus;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? locationId;
  final String? languageCode;
  final String? detectedLanguageCode;
  final AudioProcessingStage processingStage;
  final String? failureStage;
  final String? failureCode;
  final String? failureMessage;
  final bool retryable;
  final String? audioContainer;
  final String? audioCodec;
  final double? audioDurationSeconds;
  final int? audioSampleRate;
  final int? audioChannels;
  final String? transcriptionStrategy;
  final bool transcriptAvailable;
  final String? reportId;
  final AudioAnalysisSeverity? severity;
  final DateTime? processedAt;
  final String? locationName;
  final String? source;
  final AudioApiCost apiCost;

  factory AudioUpload.fromJson(Map<String, dynamic> json) {
    final apiCost = AudioApiCost.fromJson(json);
    return AudioUpload(
      id: _string(json, 'id'),
      originalFilename: _string(json, 'original_filename'),
      mediaType: _string(json, 'media_type'),
      extension: _string(json, 'extension'),
      sizeBytes: _positiveInteger(json, 'size_bytes'),
      status: _parseStatus(_string(json, 'status')),
      scanStatus: _parseScanStatus(_string(json, 'scan_status')),
      createdAt: _dateTime(json, 'created_at'),
      updatedAt: _dateTime(json, 'updated_at'),
      locationId: _nullableString(json, 'location_id'),
      languageCode: _nullableString(json, 'language_code'),
      detectedLanguageCode: _nullableString(json, 'detected_language_code'),
      processingStage: _parseProcessingStage(
        _nullableString(json, 'processing_stage') ?? 'uploaded',
      ),
      failureStage: _nullableString(json, 'failure_stage'),
      failureCode: _nullableString(json, 'failure_code'),
      failureMessage: _nullableString(json, 'failure_message'),
      retryable: json['retryable'] is bool ? json['retryable'] as bool : true,
      audioContainer: _nullableString(json, 'audio_container'),
      audioCodec: _nullableString(json, 'audio_codec'),
      audioDurationSeconds: _nullableDouble(json, 'audio_duration_seconds'),
      audioSampleRate: _nullableInt(json, 'audio_sample_rate'),
      audioChannels: _nullableInt(json, 'audio_channels'),
      transcriptionStrategy: _nullableString(json, 'transcription_strategy'),
      transcriptAvailable: json['transcript_available'] == true,
      reportId: _nullableString(json, 'report_id'),
      severity: _nullableSeverity(json['severity']),
      processedAt: _nullableDateTime(json, 'processed_at'),
      locationName: _nullableString(json, 'location_name'),
      source: _nullableString(json, 'source'),
      apiCost: apiCost,
    );
  }

  static List<AudioUpload> listFromJson(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) {
      throw const FormatException('Invalid audio upload list.');
    }
    return items
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException('Invalid audio upload item.');
          }
          return AudioUpload.fromJson(item);
        })
        .toList(growable: false);
  }

  static String _string(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Invalid audio upload $key.');
    }
    return value;
  }

  static int _positiveInteger(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! int || value <= 0) {
      throw FormatException('Invalid audio upload $key.');
    }
    return value;
  }

  static DateTime _dateTime(Map<String, dynamic> json, String key) {
    final value = _string(json, key);
    final parsed = DateTime.tryParse(value);
    if (parsed == null) throw FormatException('Invalid audio upload $key.');
    return parsed;
  }

  static String? _nullableString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is String && value.isNotEmpty) return value;
    throw FormatException('Invalid audio upload $key.');
  }

  static DateTime? _nullableDateTime(Map<String, dynamic> json, String key) {
    final value = _nullableString(json, key);
    if (value == null) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) throw FormatException('Invalid audio upload $key.');
    return parsed;
  }

  static double? _nullableDouble(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is num && value >= 0) return value.toDouble();
    throw FormatException('Invalid audio upload $key.');
  }

  static int? _nullableInt(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is int && value >= 0) return value;
    throw FormatException('Invalid audio upload $key.');
  }

  static AudioUploadStatus _parseStatus(String value) => switch (value) {
    'processing' => AudioUploadStatus.processing,
    'ready' => AudioUploadStatus.ready,
    'failed' => AudioUploadStatus.failed,
    'quarantined' => AudioUploadStatus.quarantined,
    _ => throw const FormatException('Invalid audio upload status.'),
  };

  static AudioScanStatus _parseScanStatus(String value) => switch (value) {
    'not_configured' => AudioScanStatus.notConfigured,
    'clean' => AudioScanStatus.clean,
    'infected' => AudioScanStatus.infected,
    'error' => AudioScanStatus.error,
    _ => throw const FormatException('Invalid audio scan status.'),
  };

  static AudioProcessingStage _parseProcessingStage(String value) =>
      switch (value) {
        'uploaded' => AudioProcessingStage.uploaded,
        'validating' => AudioProcessingStage.validating,
        'normalizing' => AudioProcessingStage.normalizing,
        'transcribing' => AudioProcessingStage.transcribing,
        'translating' => AudioProcessingStage.translating,
        'analyzing' => AudioProcessingStage.analyzing,
        'saving_report' => AudioProcessingStage.savingReport,
        'completed' => AudioProcessingStage.completed,
        'failed' => AudioProcessingStage.failed,
        _ => AudioProcessingStage.uploaded,
      };

  static AudioAnalysisSeverity? _nullableSeverity(Object? value) =>
      switch (value) {
        null => null,
        'low' => AudioAnalysisSeverity.low,
        'medium' => AudioAnalysisSeverity.medium,
        'high' => AudioAnalysisSeverity.high,
        'critical' => AudioAnalysisSeverity.critical,
        _ => throw const FormatException('Invalid audio upload severity.'),
      };
}

class AudioAnalysis {
  const AudioAnalysis({
    required this.summary,
    required this.category,
    required this.severity,
    required this.requiresAttention,
    required this.recommendedAction,
  });

  final String summary;
  final String category;
  final AudioAnalysisSeverity severity;
  final bool requiresAttention;
  final String recommendedAction;

  factory AudioAnalysis.fromJson(Map<String, dynamic> json) {
    final requiresAttention = json['requires_attention'];
    if (requiresAttention is! bool) {
      throw const FormatException('Invalid audio analysis attention flag.');
    }
    return AudioAnalysis(
      summary: _requiredString(json, 'summary', 'audio analysis'),
      category: _requiredString(json, 'category', 'audio analysis'),
      severity: switch (_requiredString(json, 'severity', 'audio analysis')) {
        'low' => AudioAnalysisSeverity.low,
        'medium' => AudioAnalysisSeverity.medium,
        'high' => AudioAnalysisSeverity.high,
        'critical' => AudioAnalysisSeverity.critical,
        _ => throw const FormatException('Invalid audio analysis severity.'),
      },
      requiresAttention: requiresAttention,
      recommendedAction: _requiredString(
        json,
        'recommended_action',
        'audio analysis',
      ),
    );
  }
}

class AudioUploadProcessingResult {
  const AudioUploadProcessingResult({
    required this.upload,
    required this.transcript,
    required this.analysis,
    required this.activityId,
    required this.reportId,
    required this.workspaceId,
    required this.locationId,
    required this.locationName,
    required this.processedAt,
    required this.source,
  });

  final AudioUpload upload;
  final String transcript;
  final AudioAnalysis analysis;
  final String activityId;
  final String reportId;
  final String workspaceId;
  final String locationId;
  final String locationName;
  final DateTime processedAt;
  final String source;

  factory AudioUploadProcessingResult.fromJson(Map<String, dynamic> json) {
    final rawAnalysis = json['analysis'];
    if (rawAnalysis is! Map<String, dynamic>) {
      throw const FormatException('Invalid audio analysis response.');
    }
    return AudioUploadProcessingResult(
      upload: AudioUpload.fromJson(json),
      transcript: _requiredString(json, 'transcript', 'audio processing'),
      analysis: AudioAnalysis.fromJson(rawAnalysis),
      activityId: _requiredString(json, 'activity_id', 'audio processing'),
      reportId: _requiredString(json, 'report_id', 'audio processing'),
      workspaceId: _requiredString(json, 'workspace_id', 'audio processing'),
      locationId: _requiredString(json, 'location_id', 'audio processing'),
      locationName: _requiredString(json, 'location_name', 'audio processing'),
      processedAt: _requiredDateTime(json, 'processed_at', 'audio processing'),
      source: _requiredString(json, 'source', 'audio processing'),
    );
  }
}

DateTime _requiredDateTime(
  Map<String, dynamic> json,
  String key,
  String contract,
) {
  final raw = _requiredString(json, key, contract);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw FormatException('Invalid $contract $key.');
  return parsed;
}

String _requiredString(Map<String, dynamic> json, String key, String contract) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid $contract $key.');
  }
  return value;
}
