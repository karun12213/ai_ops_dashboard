enum AudioUploadStatus { processing, ready, failed, quarantined }

enum AudioScanStatus { notConfigured, clean, infected, error }

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

  factory AudioUpload.fromJson(Map<String, dynamic> json) {
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
}
