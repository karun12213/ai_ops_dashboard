import 'dart:convert';

import 'package:ai_ops_dashboard/models/workspace_context.dart';
import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/token_storage.dart';
import 'package:ai_ops_dashboard/services/workspace_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('loads and parses the authenticated workspace context', () async {
    final service = WorkspaceService(
      ApiClient(
        tokenStorage: _MemoryTokenStorage('workspace-access-token'),
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url,
            Uri.parse('http://localhost:8000/api/v1/workspaces/context'),
          );
          expect(
            request.headers['authorization'],
            'Bearer workspace-access-token',
          );
          return http.Response(
            jsonEncode({
              'workspaces': [
                {
                  'id': 'workspace-1',
                  'name': 'Restaurant Group',
                  'role': 'owner',
                  'locations': [
                    {
                      'id': 'location-1',
                      'name': 'Main Floor',
                      'currency_code': 'INR',
                    },
                  ],
                },
                {
                  'id': 'workspace-2',
                  'name': 'Partner Restaurant',
                  'role': 'member',
                  'locations': [],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );

    final context = await service.fetchContext();

    expect(context.workspaces, hasLength(2));
    expect(context.workspaces.first.role, WorkspaceRole.owner);
    expect(context.workspaces.first.locations.single.name, 'Main Floor');
    expect(context.workspaces.last.role, WorkspaceRole.member);
  });

  test(
    'creates workspaces and locations with the exact API contract',
    () async {
      var requestNumber = 0;
      final service = WorkspaceService(
        ApiClient(
          tokenStorage: _MemoryTokenStorage('workspace-access-token'),
          client: MockClient((request) async {
            requestNumber += 1;
            expect(request.method, 'POST');
            expect(
              request.headers['authorization'],
              'Bearer workspace-access-token',
            );
            expect(request.headers['content-type'], 'application/json');

            if (requestNumber == 1) {
              expect(
                request.url,
                Uri.parse('http://localhost:8000/api/v1/workspaces'),
              );
              expect(jsonDecode(request.body), {
                'name': 'Restaurant Group',
                'location_name': 'Main Floor',
                'currency_code': 'INR',
              });
              return http.Response(
                jsonEncode({
                  'id': 'workspace-1',
                  'name': 'Restaurant Group',
                  'role': 'owner',
                  'locations': [
                    {
                      'id': 'location-1',
                      'name': 'Main Floor',
                      'currency_code': 'INR',
                    },
                  ],
                }),
                201,
              );
            }

            expect(
              request.url,
              Uri.parse(
                'http://localhost:8000/api/v1/workspaces/workspace-1/locations',
              ),
            );
            expect(jsonDecode(request.body), {
              'name': 'Terrace',
              'currency_code': 'INR',
            });
            return http.Response(
              jsonEncode({
                'id': 'location-2',
                'name': 'Terrace',
                'currency_code': 'INR',
              }),
              201,
            );
          }),
        ),
      );

      final workspace = await service.createWorkspace(
        name: 'Restaurant Group',
        locationName: 'Main Floor',
        currencyCode: 'INR',
      );
      final location = await service.createLocation(
        workspaceId: workspace.id,
        name: 'Terrace',
        currencyCode: 'INR',
      );

      expect(workspace.locations.single.id, 'location-1');
      expect(location.id, 'location-2');
      expect(requestNumber, 2);
    },
  );

  test('rejects malformed workspace roles from the API', () async {
    final service = WorkspaceService(
      ApiClient(
        tokenStorage: _MemoryTokenStorage('workspace-access-token'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'workspaces': [
                {
                  'id': 'workspace-1',
                  'name': 'Restaurant',
                  'role': 'administrator',
                  'locations': [],
                },
              ],
            }),
            200,
          ),
        ),
      ),
    );

    await expectLater(service.fetchContext(), throwsFormatException);
  });
}

class _MemoryTokenStorage extends TokenStorage {
  _MemoryTokenStorage(this.accessToken);

  final String accessToken;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => null;
}
