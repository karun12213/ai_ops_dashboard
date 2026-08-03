import 'dart:async';
import 'dart:convert';

import 'package:ai_ops_dashboard/models/audio_upload.dart';
import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/audio_file_picker.dart';
import 'package:ai_ops_dashboard/services/audio_upload_service.dart';
import 'package:ai_ops_dashboard/services/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'uploads authenticated multipart bytes and reports file progress',
    () async {
      var openCount = 0;
      final progress = <double>[];
      final apiClient = ApiClient(
        tokenStorage: _MemoryTokenStorage(accessToken: 'audio-access-token'),
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(
            request.url,
            Uri.parse('http://localhost:8000/api/v1/audio-uploads'),
          );
          expect(request.headers['authorization'], 'Bearer audio-access-token');
          expect(
            request.headers['content-type'],
            startsWith('multipart/form-data;'),
          );
          final body = latin1.decode(request.bodyBytes);
          expect(body, contains('name="file"'));
          expect(body, contains('filename="shift-note.mp3"'));
          expect(body, contains('ID3audio-data'));
          return http.Response(jsonEncode(_audioJson), 201);
        }),
      );
      final file = PickedAudioFile(
        name: 'shift-note.mp3',
        sizeBytes: 13,
        openRead: () {
          openCount += 1;
          return Stream.fromIterable([
            [73, 68, 51],
            utf8.encode('audio-data'),
          ]);
        },
      );

      final uploaded = await AudioUploadService(
        apiClient,
      ).upload(file, onProgress: progress.add);

      expect(openCount, 1);
      expect(progress.first, 0);
      expect(progress.last, 1);
      expect(uploaded.id, _audioJson['id']);
      expect(uploaded.status, AudioUploadStatus.ready);
      expect(uploaded.scanStatus, AudioScanStatus.clean);
    },
  );

  test('loads bounded history and deletes the exact upload', () async {
    var requestCount = 0;
    final apiClient = ApiClient(
      tokenStorage: _MemoryTokenStorage(accessToken: 'audio-access-token'),
      client: MockClient((request) async {
        requestCount += 1;
        expect(request.headers['authorization'], 'Bearer audio-access-token');
        if (requestCount == 1) {
          expect(request.method, 'GET');
          expect(
            request.url,
            Uri.parse('http://localhost:8000/api/v1/audio-uploads?limit=25'),
          );
          return http.Response(
            jsonEncode({
              'items': [_audioJson],
            }),
            200,
          );
        }
        expect(request.method, 'DELETE');
        expect(
          request.url,
          Uri.parse(
            'http://localhost:8000/api/v1/audio-uploads/${_audioJson['id']}',
          ),
        );
        return http.Response('', 204);
      }),
    );
    final service = AudioUploadService(apiClient);

    final history = await service.fetchHistory(limit: 25);
    await service.delete(history.single.id);

    expect(history.single.originalFilename, 'shift-note.mp3');
    expect(history.single.sizeBytes, 13);
    expect(requestCount, 2);
    expect(() => service.fetchHistory(limit: 51), throwsArgumentError);
  });

  test('rejects malformed status and list contracts', () {
    expect(
      () => AudioUpload.fromJson({..._audioJson, 'status': 'unknown'}),
      throwsFormatException,
    );
    expect(
      () => AudioUpload.listFromJson({'items': 'not-a-list'}),
      throwsFormatException,
    );
    expect(
      () => AudioUpload.fromJson({..._audioJson, 'size_bytes': 0}),
      throwsFormatException,
    );
  });
}

final _audioJson = <String, dynamic>{
  'id': 'b4754746-c6b4-4ca7-b8aa-c00dcac9ea4d',
  'original_filename': 'shift-note.mp3',
  'media_type': 'audio/mpeg',
  'extension': 'mp3',
  'size_bytes': 13,
  'status': 'ready',
  'scan_status': 'clean',
  'created_at': '2026-08-03T10:00:00Z',
  'updated_at': '2026-08-03T10:00:01Z',
};

class _MemoryTokenStorage extends TokenStorage {
  _MemoryTokenStorage({this.accessToken});

  String? accessToken;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => null;
}
