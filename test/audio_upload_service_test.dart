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
          expect(body.toLowerCase(), contains('content-type: audio/mpeg'));
          expect(body, contains('name="location_id"'));
          expect(body, contains('location-1'));
          expect(body, contains('name="language_code"'));
          expect(body, contains('ne-IN'));
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

      final result = await AudioUploadService(apiClient).upload(
        file,
        locationId: 'location-1',
        languageCode: 'ne-IN',
        onProgress: progress.add,
      );

      expect(openCount, 1);
      expect(progress.first, 0);
      expect(progress.last, 1);
      expect(result.upload.id, _audioJson['id']);
      expect(result.upload.status, AudioUploadStatus.ready);
      expect(result.upload.scanStatus, AudioScanStatus.clean);
      expect(result.activityId, _audioJson['activity_id']);
      expect(result.reportId, _audioJson['report_id']);
      expect(result.locationName, 'Main Floor');
      expect(result.analysis.severity, AudioAnalysisSeverity.high);
      expect(result.upload.apiCost.audioDurationSeconds, 2);
      expect(result.upload.apiCost.sarvamModel, 'saaras:v3');
      expect(result.upload.apiCost.sarvamEstimatedCostInr, 0.01666667);
      expect(result.upload.apiCost.openaiInputTokens, 150);
      expect(result.upload.apiCost.openaiCachedInputTokens, 20);
      expect(result.upload.apiCost.openaiOutputTokens, 15);
      expect(result.upload.apiCost.openaiTotalTokens, 165);
      expect(result.upload.apiCost.openaiEstimatedCostUsd, 0.0005);
      expect(result.upload.apiCost.totalInr, 0.01666667);
      expect(result.upload.apiCost.totalUsd, 0.0005);
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
          expect(request.url.path, '/api/v1/audio-uploads');
          expect(request.url.queryParameters, {
            'workspace_id': 'workspace-1',
            'location_id': 'location-1',
            'limit': '25',
          });
          return http.Response(
            jsonEncode({
              'items': [_audioJson],
            }),
            200,
          );
        }
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/v1/audio-uploads/${_audioJson['id']}');
        expect(request.url.queryParameters, {
          'workspace_id': 'workspace-1',
          'location_id': 'location-1',
        });
        return http.Response('', 204);
      }),
    );
    final service = AudioUploadService(apiClient);

    final history = await service.fetchHistory(
      workspaceId: 'workspace-1',
      locationId: 'location-1',
      limit: 25,
    );
    await service.delete(
      history.single.id,
      workspaceId: 'workspace-1',
      locationId: 'location-1',
    );

    expect(history.single.originalFilename, 'shift-note.mp3');
    expect(history.single.sizeBytes, 13);
    expect(history.single.apiCost.openaiTotalTokens, 165);
    expect(requestCount, 2);
    expect(
      () => service.fetchHistory(
        workspaceId: 'workspace-1',
        locationId: 'location-1',
        limit: 51,
      ),
      throwsArgumentError,
    );
  });

  test(
    'fetches stored audio bytes through the authenticated audio endpoint',
    () async {
      final apiClient = ApiClient(
        tokenStorage: _MemoryTokenStorage(accessToken: 'audio-access-token'),
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url.path,
            '/api/v1/audio-uploads/${_audioJson['id']}/audio',
          );
          expect(request.url.queryParameters, {
            'workspace_id': 'workspace-1',
            'location_id': 'location-1',
          });
          expect(request.headers['authorization'], 'Bearer audio-access-token');
          expect(request.headers['accept'], 'audio/*');
          return http.Response.bytes(
            [73, 68, 51, 1, 2, 3],
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }),
      );

      final audio = await AudioUploadService(apiClient).fetchAudio(
        _audioJson['id'] as String,
        workspaceId: 'workspace-1',
        locationId: 'location-1',
      );

      expect(audio.bytes, [73, 68, 51, 1, 2, 3]);
      expect(audio.mediaType, 'audio/mpeg');
    },
  );

  test(
    'refreshes an expired token and rebuilds authenticated multipart data',
    () async {
      final storage = _MemoryTokenStorage(
        accessToken: 'expired-access-token',
        refreshToken: 'valid-refresh-token',
      );
      var uploadRequests = 0;
      var openCount = 0;
      final client = ApiClient(
        tokenStorage: storage,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            expect(jsonDecode(request.body), {
              'refresh_token': 'valid-refresh-token',
            });
            return http.Response(
              jsonEncode({
                'access_token': 'fresh-access-token',
                'refresh_token': 'rotated-refresh-token',
              }),
              200,
            );
          }
          uploadRequests += 1;
          expect(request.url.path.endsWith('/audio-uploads'), isTrue);
          expect(
            request.headers['authorization'],
            uploadRequests == 1
                ? 'Bearer expired-access-token'
                : 'Bearer fresh-access-token',
          );
          return uploadRequests == 1
              ? http.Response(jsonEncode({'detail': 'expired'}), 401)
              : http.Response(jsonEncode(_audioJson), 201);
        }),
      );
      final file = PickedAudioFile(
        name: 'shift-note.mp3',
        sizeBytes: 3,
        openRead: () {
          openCount += 1;
          return Stream.value([73, 68, 51]);
        },
      );

      final result = await AudioUploadService(
        client,
      ).upload(file, locationId: 'location-1', languageCode: 'ne-IN');

      expect(result.reportId, _audioJson['report_id']);
      expect(uploadRequests, 2);
      expect(openCount, 2);
      expect(storage.accessToken, 'fresh-access-token');
      expect(storage.refreshToken, 'rotated-refresh-token');
    },
  );

  test(
    'failed refresh clears tokens and reports session expiry once',
    () async {
      final storage = _MemoryTokenStorage(
        accessToken: 'expired-access-token',
        refreshToken: 'invalid-refresh-token',
      );
      var expirySignals = 0;
      var openCount = 0;
      final client = ApiClient(
        tokenStorage: storage,
        onSessionExpired: () => expirySignals += 1,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            return http.Response(
              jsonEncode({'detail': 'invalid refresh'}),
              401,
            );
          }
          return http.Response(jsonEncode({'detail': 'expired'}), 401);
        }),
      );
      final file = PickedAudioFile(
        name: 'shift-note.mp3',
        sizeBytes: 3,
        openRead: () {
          openCount += 1;
          return Stream.value([73, 68, 51]);
        },
      );

      await expectLater(
        AudioUploadService(
          client,
        ).upload(file, locationId: 'location-1', languageCode: 'unknown'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 401)
              .having(
                (error) => error.message,
                'message',
                'Your session has expired. Please sign in again.',
              ),
        ),
      );
      expect(storage.accessToken, isNull);
      expect(storage.refreshToken, isNull);
      expect(expirySignals, 1);
      expect(openCount, 1);
    },
  );

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
    expect(
      () => AudioUploadProcessingResult.fromJson({
        ..._audioJson,
        'analysis': {..._audioJson['analysis'] as Map, 'severity': 'unknown'},
      }),
      throwsFormatException,
    );
  });

  test('accepts historical uploads without API cost data', () {
    final historical = Map<String, dynamic>.from(_audioJson);
    for (final field in const [
      'audio_duration_seconds',
      'sarvam_model',
      'sarvam_estimated_cost_inr',
      'openai_model',
      'openai_input_tokens',
      'openai_cached_input_tokens',
      'openai_output_tokens',
      'openai_total_tokens',
      'openai_estimated_cost_usd',
      'total_estimated_cost',
    ]) {
      historical.remove(field);
    }

    expect(AudioUpload.fromJson(historical).apiCost.isAvailable, isFalse);
  });

  test('maps upload failures to safe status-specific messages', () async {
    const cases = <int, String>{
      401: 'Your session has expired. Please sign in again.',
      403: 'You do not have access to this restaurant location.',
      404: 'The selected restaurant location could not be found.',
      409:
          'This recording has already been processed. Open the existing report.',
      413: 'The recording is too large.',
      415: 'This audio format is not supported.',
      422: 'The recording could not be processed.',
      429: 'The AI service is temporarily busy. Please try again shortly.',
      500: 'The recording could not be processed.',
      503: 'The recording could not be processed.',
    };
    for (final entry in cases.entries) {
      final service = AudioUploadService(
        ApiClient(
          tokenStorage: _MemoryTokenStorage(accessToken: 'audio-access-token'),
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({'detail': 'sensitive internal or provider response'}),
              entry.key,
            ),
          ),
        ),
      );
      final file = PickedAudioFile(
        name: 'shift-note.mp3',
        sizeBytes: 3,
        openRead: () => Stream.value([73, 68, 51]),
      );

      await expectLater(
        service.upload(file, locationId: 'location-1', languageCode: 'ne-IN'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', entry.key)
              .having((error) => error.message, 'message', entry.value),
        ),
        reason: 'Unexpected message for HTTP ${entry.key}',
      );
    }
  });

  test(
    'preserves safe duplicate identifiers for View Existing Report',
    () async {
      final service = AudioUploadService(
        ApiClient(
          tokenStorage: _MemoryTokenStorage(accessToken: 'audio-access-token'),
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'detail': {
                  'code': 'duplicate_completed',
                  'message': 'safe message',
                  'existing_upload_id': 'existing-upload',
                  'existing_report_id': 'existing-report',
                },
              }),
              409,
            ),
          ),
        ),
      );

      await expectLater(
        service.upload(
          PickedAudioFile(
            name: 'shift-note.mp3',
            sizeBytes: 3,
            openRead: () => Stream.value([73, 68, 51]),
          ),
          locationId: 'location-1',
          languageCode: 'unknown',
        ),
        throwsA(
          isA<ApiException>()
              .having(
                (error) => error.existingUploadId,
                'existingUploadId',
                'existing-upload',
              )
              .having(
                (error) => error.existingReportId,
                'existingReportId',
                'existing-report',
              ),
        ),
      );
    },
  );
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
  'audio_duration_seconds': 2.0,
  'sarvam_model': 'saaras:v3',
  'sarvam_estimated_cost_inr': '0.01666667',
  'openai_model': 'gpt-4o-2024-11-20',
  'openai_input_tokens': 150,
  'openai_cached_input_tokens': 20,
  'openai_output_tokens': 15,
  'openai_total_tokens': 165,
  'openai_estimated_cost_usd': '0.00050000',
  'total_estimated_cost': {'INR': '0.01666667', 'USD': '0.00050000'},
  'transcript': 'The dinner station is running low on plates.',
  'analysis': {
    'summary': 'Restock plates at the dinner station',
    'category': 'inventory',
    'severity': 'high',
    'requires_attention': true,
    'recommended_action': 'Move clean plates to the station.',
  },
  'activity_id': 'fe67a667-135d-46e6-9c1a-04ba3fc7d258',
  'report_id': '9ec4682a-cd7c-4d2f-b462-f8280638a29d',
  'workspace_id': 'e65551f4-5d31-44a4-8750-bc507711ba56',
  'location_id': '95cd56e6-228e-47dc-8fb4-3ac8760c2082',
  'location_name': 'Main Floor',
  'processed_at': '2026-08-03T10:00:02Z',
  'source': 'AI Audio Monitor',
};

class _MemoryTokenStorage extends TokenStorage {
  _MemoryTokenStorage({this.accessToken, this.refreshToken});

  String? accessToken;
  String? refreshToken;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
  }

  @override
  Future<void> clear() async {
    accessToken = null;
    refreshToken = null;
  }
}
