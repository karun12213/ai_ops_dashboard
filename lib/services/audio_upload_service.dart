import '../models/audio_upload.dart';
import 'api_client.dart';
import 'audio_file_picker.dart';

abstract interface class AudioUploadRepository {
  Future<List<AudioUpload>> fetchHistory({int limit = 50});

  Future<AudioUpload> upload(
    PickedAudioFile file, {
    void Function(double progress)? onProgress,
  });

  Future<void> delete(String uploadId);
}

class AudioUploadService implements AudioUploadRepository {
  AudioUploadService(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<List<AudioUpload>> fetchHistory({int limit = 50}) async {
    if (limit < 1 || limit > 50) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 50');
    }
    final payload = await _apiClient.get('/audio-uploads?limit=$limit');
    return AudioUpload.listFromJson(payload);
  }

  @override
  Future<AudioUpload> upload(
    PickedAudioFile file, {
    void Function(double progress)? onProgress,
  }) async {
    final payload = await _apiClient.multipartPost(
      '/audio-uploads',
      fieldName: 'file',
      filename: file.name,
      length: file.sizeBytes,
      openRead: file.openRead,
      onProgress: onProgress,
    );
    return AudioUpload.fromJson(payload);
  }

  @override
  Future<void> delete(String uploadId) {
    return _apiClient.delete('/audio-uploads/$uploadId');
  }
}
