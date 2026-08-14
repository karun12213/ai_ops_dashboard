import 'package:flutter/foundation.dart';

import '../models/audio_upload.dart';
import 'api_client.dart';
import 'audio_file_picker.dart';

abstract interface class AudioUploadRepository {
  Future<List<AudioUpload>> fetchHistory({
    required String workspaceId,
    required String locationId,
    int limit = 50,
  });

  Future<AudioUploadProcessingResult> upload(
    PickedAudioFile file, {
    required String locationId,
    required String languageCode,
    void Function(double progress)? onProgress,
  });

  Future<AudioUploadProcessingResult> retryProcessing(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  });

  Future<StoredAudioData> fetchAudio(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  });

  Future<void> delete(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  });
}

class StoredAudioData {
  const StoredAudioData({required this.bytes, required this.mediaType});

  final Uint8List bytes;
  final String mediaType;
}

class AudioUploadService implements AudioUploadRepository {
  AudioUploadService(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<List<AudioUpload>> fetchHistory({
    required String workspaceId,
    required String locationId,
    int limit = 50,
  }) async {
    if (limit < 1 || limit > 50) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 50');
    }
    final path = Uri(
      path: '/audio-uploads',
      queryParameters: {
        'workspace_id': workspaceId,
        'location_id': locationId,
        'limit': limit.toString(),
      },
    ).toString();
    final payload = await _apiClient.get(path);
    return AudioUpload.listFromJson(payload);
  }

  @override
  Future<AudioUploadProcessingResult> upload(
    PickedAudioFile file, {
    required String locationId,
    required String languageCode,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final payload = await _apiClient.multipartPost(
        '/audio-uploads',
        fieldName: 'file',
        filename: file.name,
        length: file.sizeBytes,
        openRead: file.openRead,
        mediaType: file.effectiveMediaType,
        fields: {'location_id': locationId, 'language_code': languageCode},
        onProgress: onProgress,
      );
      return AudioUploadProcessingResult.fromJson(payload);
    } on ApiException catch (error) {
      throw ApiException(
        _audioUploadErrorMessage(error),
        statusCode: error.statusCode,
        code: error.code,
        existingUploadId: error.existingUploadId,
        existingReportId: error.existingReportId,
      );
    } on FormatException catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Audio response contract failure: $error\n$stackTrace');
      }
      throw const ApiException(
        'The recording could not be processed.',
        code: 'invalid_audio_response',
      );
    }
  }

  @override
  Future<AudioUploadProcessingResult> retryProcessing(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  }) async {
    final path = Uri(
      path: '/audio-uploads/$uploadId/retry',
      queryParameters: {'workspace_id': workspaceId, 'location_id': locationId},
    ).toString();
    try {
      return AudioUploadProcessingResult.fromJson(await _apiClient.post(path));
    } on ApiException catch (error) {
      throw ApiException(
        _audioUploadErrorMessage(error),
        statusCode: error.statusCode,
        code: error.code,
      );
    }
  }

  @override
  Future<StoredAudioData> fetchAudio(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  }) async {
    final path = Uri(
      path: '/audio-uploads/$uploadId/audio',
      queryParameters: {'workspace_id': workspaceId, 'location_id': locationId},
    ).toString();
    final response = await _apiClient.download(path, accept: 'audio/*');
    return StoredAudioData(
      bytes: response.bytes,
      mediaType: response.contentType?.split(';').first ?? 'audio/mpeg',
    );
  }

  @override
  Future<void> delete(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  }) {
    final path = Uri(
      path: '/audio-uploads/$uploadId',
      queryParameters: {'workspace_id': workspaceId, 'location_id': locationId},
    ).toString();
    return _apiClient.delete(path);
  }
}

String _audioUploadErrorMessage(ApiException error) => switch (error.code) {
  'network_unreachable' =>
    'Cannot reach the server. Check that the backend is running.',
  'sarvam_unavailable' =>
    'Speech translation is temporarily unavailable. Please try again.',
  'openai_unavailable' =>
    'AI report generation is temporarily unavailable. Please try again.',
  'ai_busy' => 'The AI service is temporarily busy. Please try again shortly.',
  'duplicate_completed' =>
    'This recording has already been processed. Open the existing report.',
  'duplicate_processing' => 'This recording is already being processed.',
  _ => switch (error.statusCode) {
    401 => 'Your session has expired. Please sign in again.',
    403 => 'You do not have access to this restaurant location.',
    404 => 'The selected restaurant location could not be found.',
    409 =>
      'This recording has already been processed. Open the existing report.',
    413 => 'The recording is too large.',
    415 => 'This audio format is not supported.',
    422 => 'The recording could not be processed.',
    429 => 'The AI service is temporarily busy. Please try again shortly.',
    _ => 'The recording could not be processed.',
  },
};
