import 'dart:convert';

import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/dashboard_service.dart';
import 'package:ai_ops_dashboard/services/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'loads the exact authenticated date-scoped Dashboard contract',
    () async {
      final tokenStorage = _MemoryTokenStorage(
        accessToken: 'dashboard-access-token',
      );
      final apiClient = ApiClient(
        tokenStorage: tokenStorage,
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url,
            Uri.parse(
              'http://localhost:8000/api/v1/dashboard?service_date=2026-08-03'
              '&workspace_id=workspace-1&location_id=location-1',
            ),
          );
          expect(
            request.headers['authorization'],
            'Bearer dashboard-access-token',
          );
          return http.Response(
            jsonEncode({
              'service_date': '2026-08-03',
              'snapshot': {
                'updated_at': '2026-08-03T12:30:00Z',
                'service_open': true,
                'metrics': {
                  'currency_code': 'INR',
                  'net_sales_minor': 10200,
                  'net_sales_change_percent': 12.4,
                  'orders_served': 4,
                  'orders_change_percent': 8.1,
                  'average_ticket_minor': 2550,
                  'average_ticket_change_percent': null,
                  'average_table_turn_minutes': 47,
                  'table_turn_change_percent': -5.2,
                },
                'hourly_sales': [
                  {'hour': 17, 'net_sales_minor': 3000},
                  {'hour': 18, 'net_sales_minor': 7200},
                ],
                'service_pulse': {
                  'occupied_tables': 11,
                  'total_tables': 20,
                  'active_kitchen_tickets': 7,
                  'kitchen_capacity': 16,
                  'pickup_orders': 3,
                  'pickup_capacity': 10,
                  'staff_on_shift': 15,
                  'staff_scheduled': 18,
                },
              },
              'recent_activity': [
                {
                  'id': '95cd56e6-228e-47dc-8fb4-3ac8760c2082',
                  'occurred_at': '2026-08-03T17:02:00Z',
                  'title': 'Dinner shift opened',
                  'actor': 'Floor Manager',
                  'category': 'service',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final data = await DashboardService(apiClient).fetch(
        serviceDate: DateTime(2026, 8, 3),
        workspaceId: 'workspace-1',
        locationId: 'location-1',
      );

      expect(data.serviceDate, DateTime(2026, 8, 3));
      expect(data.snapshot?.metrics.netSalesMinor, 10200);
      expect(data.snapshot?.metrics.averageTicketChangePercent, isNull);
      expect(data.snapshot?.hourlySales.map((point) => point.hour), [17, 18]);
      expect(data.snapshot?.servicePulse.staffScheduled, 18);
      expect(data.recentActivity.single.category, 'service');
    },
  );

  test('parses a legitimate empty Dashboard response', () async {
    final apiClient = ApiClient(
      tokenStorage: _MemoryTokenStorage(accessToken: 'dashboard-access-token'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'service_date': '2026-08-03',
            'snapshot': null,
            'recent_activity': [],
          }),
          200,
        ),
      ),
    );

    final data = await DashboardService(apiClient).fetch(
      serviceDate: DateTime(2026, 8, 3),
      workspaceId: 'workspace-1',
      locationId: 'location-1',
    );

    expect(data.snapshot, isNull);
    expect(data.recentActivity, isEmpty);
  });
}

class _MemoryTokenStorage extends TokenStorage {
  _MemoryTokenStorage({this.accessToken});

  String? accessToken;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => null;
}
