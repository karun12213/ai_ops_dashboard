import 'dart:convert';

import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/cost_analytics_service.dart';
import 'package:ai_ops_dashboard/services/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('loads and parses the authenticated cost analytics contract', () async {
    final apiClient = ApiClient(
      tokenStorage: _MemoryTokenStorage(accessToken: 'cost-access-token'),
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url,
          Uri.parse(
            'http://localhost:8000/api/v1/cost-analytics'
            '?start_date=2026-08-08&end_date=2026-08-14'
            '&workspace_id=workspace-1&location_id=location-1&recent_limit=25',
          ),
        );
        expect(request.headers['authorization'], 'Bearer cost-access-token');
        return http.Response(
          jsonEncode(_payload),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final data = await CostAnalyticsService(apiClient).fetch(
      startDate: DateTime(2026, 8, 8),
      endDate: DateTime(2026, 8, 14),
      workspaceId: 'workspace-1',
      locationId: 'location-1',
    );

    expect(data.metrics.totalAudioUploads, 3);
    expect(data.metrics.missingCostDataUploads, 1);
    expect(data.metrics.totalSarvamCostInr, 1.5);
    expect(data.metrics.totalOpenAiCostUsd, 0.008);
    expect(data.bySeverity.last.label, 'High');
    expect(data.recentUsage.first.originalFilename, 'inventory-note.wav');
    expect(data.recentUsage.first.openAiTotalTokens, 2750);
  });

  test('validates date, workspace, and recent usage bounds locally', () async {
    final service = CostAnalyticsService(
      ApiClient(
        tokenStorage: _MemoryTokenStorage(accessToken: 'token'),
        client: MockClient((_) async => throw StateError('must not request')),
      ),
    );

    expect(
      () => service.fetch(
        startDate: DateTime(2026, 8, 14),
        endDate: DateTime(2026, 8, 13),
        workspaceId: 'workspace-1',
      ),
      throwsArgumentError,
    );
    expect(
      () => service.fetch(
        startDate: DateTime(2026, 8, 14),
        endDate: DateTime(2026, 8, 14),
        workspaceId: '   ',
      ),
      throwsArgumentError,
    );
    expect(
      () => service.fetch(
        startDate: DateTime(2026, 8, 14),
        endDate: DateTime(2026, 8, 14),
        workspaceId: 'workspace-1',
        recentLimit: 101,
      ),
      throwsArgumentError,
    );
  });
}

const _payload = <String, dynamic>{
  'start_date': '2026-08-08',
  'end_date': '2026-08-14',
  'location_id': 'location-1',
  'metrics': {
    'total_audio_uploads': 3,
    'costed_audio_uploads': 2,
    'missing_cost_data_uploads': 1,
    'total_recorded_audio_duration_seconds': 210.0,
    'costed_audio_duration_seconds': 180.0,
    'total_sarvam_cost_inr': '1.50000000',
    'total_openai_cost_usd': '0.00800000',
    'average_sarvam_cost_per_upload_inr': '0.75000000',
    'average_openai_cost_per_upload_usd': '0.00400000',
    'average_sarvam_cost_per_recorded_minute_inr': '0.50000000',
    'average_openai_cost_per_recorded_minute_usd': '0.00266667',
    'estimated_sarvam_cost_per_recorded_hour_inr': '30.00000000',
    'estimated_openai_cost_per_recorded_hour_usd': '0.16000000',
  },
  'by_location': [
    {
      'key': 'location-1',
      'label': 'Main Kitchen',
      'total_audio_uploads': 3,
      'costed_audio_uploads': 2,
      'missing_cost_data_uploads': 1,
      'recorded_audio_duration_seconds': 210.0,
      'sarvam_cost_inr': '1.50000000',
      'openai_cost_usd': '0.00800000',
    },
  ],
  'by_severity': [
    {
      'key': 'low',
      'label': 'Low',
      'total_audio_uploads': 1,
      'costed_audio_uploads': 1,
      'missing_cost_data_uploads': 0,
      'recorded_audio_duration_seconds': 60.0,
      'sarvam_cost_inr': '0.50000000',
      'openai_cost_usd': '0.00200000',
    },
    {
      'key': 'medium',
      'label': 'Medium',
      'total_audio_uploads': 1,
      'costed_audio_uploads': 0,
      'missing_cost_data_uploads': 1,
      'recorded_audio_duration_seconds': 30.0,
      'sarvam_cost_inr': null,
      'openai_cost_usd': null,
    },
    {
      'key': 'high',
      'label': 'High',
      'total_audio_uploads': 1,
      'costed_audio_uploads': 1,
      'missing_cost_data_uploads': 0,
      'recorded_audio_duration_seconds': 120.0,
      'sarvam_cost_inr': '1.00000000',
      'openai_cost_usd': '0.00600000',
    },
  ],
  'by_category': [],
  'recent_usage': [
    {
      'upload_id': 'upload-2',
      'processed_at': '2026-08-14T11:00:00Z',
      'original_filename': 'inventory-note.wav',
      'audio_duration_seconds': 120.0,
      'category': 'inventory',
      'severity': 'high',
      'sarvam_estimated_cost_inr': '1.00000000',
      'openai_estimated_cost_usd': '0.00600000',
      'openai_total_tokens': 2750,
    },
  ],
};

class _MemoryTokenStorage extends TokenStorage {
  _MemoryTokenStorage({this.accessToken});

  String? accessToken;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => null;
}
