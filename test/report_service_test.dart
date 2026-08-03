import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/report_service.dart';
import 'package:ai_ops_dashboard/services/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('loads the exact authenticated range and location contract', () async {
    const locationId = '95cd56e6-228e-47dc-8fb4-3ac8760c2082';
    final apiClient = ApiClient(
      tokenStorage: _MemoryTokenStorage(accessToken: 'reports-access-token'),
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url,
          Uri.parse(
            'http://localhost:8000/api/v1/reports'
            '?start_date=2026-07-05&end_date=2026-08-03'
            '&location_id=$locationId',
          ),
        );
        expect(request.headers['authorization'], 'Bearer reports-access-token');
        return http.Response(
          jsonEncode({
            'start_date': '2026-07-05',
            'end_date': '2026-08-03',
            'location_id': locationId,
            'locations': [
              {'id': locationId, 'name': 'Bandra'},
            ],
            'totals': {
              'currency_code': 'INR',
              'revenue_total_minor': 10200,
              'order_total': 4,
              'average_ticket_minor': 2550,
            },
            'channel_split': [
              {
                'channel': 'dine_in',
                'label': 'Dine-in',
                'revenue_minor': 7650,
                'order_total': 3,
                'revenue_percent': 75.0,
              },
              {
                'channel': 'delivery',
                'label': 'Delivery',
                'revenue_minor': 2550,
                'order_total': 1,
                'revenue_percent': 25.0,
              },
            ],
            'revenue_trend': [
              {'date': '2026-08-02', 'revenue_minor': 3000, 'order_total': 1},
              {'date': '2026-08-03', 'revenue_minor': 7200, 'order_total': 3},
            ],
            'location_performance': [
              {
                'location_id': locationId,
                'location_name': 'Bandra',
                'currency_code': 'INR',
                'revenue_minor': 10200,
                'order_total': 4,
                'average_ticket_minor': 2550,
                'revenue_growth_percent': 12.8,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final report = await ReportService(apiClient).fetch(
      startDate: DateTime(2026, 7, 5),
      endDate: DateTime(2026, 8, 3),
      locationId: locationId,
    );

    expect(report.startDate, DateTime(2026, 7, 5));
    expect(report.endDate, DateTime(2026, 8, 3));
    expect(report.locationId, locationId);
    expect(report.totals.revenueTotalMinor, 10200);
    expect(report.channelSplit.map((item) => item.channel), [
      'dine_in',
      'delivery',
    ]);
    expect(report.revenueTrend.last.revenueMinor, 7200);
    expect(report.locationPerformance.single.revenueGrowthPercent, 12.8);
    expect(report.hasData, isTrue);
  });

  test('parses a legitimate empty Reports response', () async {
    final apiClient = ApiClient(
      tokenStorage: _MemoryTokenStorage(accessToken: 'reports-access-token'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'start_date': '2026-07-05',
            'end_date': '2026-08-03',
            'location_id': null,
            'locations': [],
            'totals': {
              'currency_code': null,
              'revenue_total_minor': 0,
              'order_total': 0,
              'average_ticket_minor': 0,
            },
            'channel_split': [],
            'revenue_trend': [],
            'location_performance': [],
          }),
          200,
        ),
      ),
    );

    final report = await ReportService(
      apiClient,
    ).fetch(startDate: DateTime(2026, 7, 5), endDate: DateTime(2026, 8, 3));

    expect(report.totals.currencyCode, isNull);
    expect(report.hasData, isFalse);
  });

  test(
    'downloads authenticated CSV bytes and accepts only a safe filename',
    () async {
      final apiClient = ApiClient(
        tokenStorage: _MemoryTokenStorage(accessToken: 'reports-access-token'),
        client: MockClient((request) async {
          expect(
            request.url,
            Uri.parse(
              'http://localhost:8000/api/v1/reports/export.csv'
              '?start_date=2026-07-05&end_date=2026-08-03',
            ),
          );
          expect(
            request.headers['authorization'],
            'Bearer reports-access-token',
          );
          expect(request.headers['accept'], 'text/csv');
          return http.Response.bytes(
            utf8.encode('service_date,location\r\n2026-08-03,Bandra\r\n'),
            200,
            headers: {
              'content-type': 'text/csv; charset=utf-8',
              'content-disposition':
                  'attachment; filename="../unsafe report 2026.csv"',
            },
          );
        }),
      );

      final export = await ReportService(apiClient).exportCsv(
        startDate: DateTime(2026, 7, 5),
        endDate: DateTime(2026, 8, 3),
      );

      expect(
        utf8.decode(export.bytes),
        'service_date,location\r\n2026-08-03,Bandra\r\n',
      );
      expect(export.filename, '.._unsafe_report_2026.csv');
      expect(export.bytes, isA<Uint8List>());
    },
  );
}

class _MemoryTokenStorage extends TokenStorage {
  _MemoryTokenStorage({this.accessToken});

  String? accessToken;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => null;
}
