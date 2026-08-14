import 'dart:async';

import 'package:ai_ops_dashboard/models/cost_analytics.dart';
import 'package:ai_ops_dashboard/models/workspace_context.dart';
import 'package:ai_ops_dashboard/providers/cost_analytics_provider.dart';
import 'package:ai_ops_dashboard/providers/workspace_provider.dart';
import 'package:ai_ops_dashboard/screens/cost_analytics_screen.dart';
import 'package:ai_ops_dashboard/services/cost_analytics_service.dart';
import 'package:ai_ops_dashboard/services/workspace_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a loading state while cost analytics are pending', (
    tester,
  ) async {
    final completer = Completer<CostAnalyticsData>();
    await _pumpAnalytics(
      tester,
      _FakeCostAnalyticsService((_) => completer.future),
    );

    expect(find.text('Loading cost analytics…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));

    completer.complete(_analyticsData);
    await tester.pumpAndSettle();
  });

  testWidgets('renders separate currencies, breakdowns, and recent usage', (
    tester,
  ) async {
    await _pumpAnalytics(
      tester,
      _FakeCostAnalyticsService((_) async => _analyticsData),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cost Analytics'), findsOneWidget);
    expect(find.text('Total audio uploads'), findsOneWidget);
    expect(find.text('3'), findsWidgets);
    expect(find.text('3 min 30.0 sec'), findsWidgets);
    expect(find.text('₹1.50'), findsWidgets);
    expect(find.text(r'$0.0080'), findsWidgets);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('7 DAYS'), findsOneWidget);
    expect(find.text('30 DAYS'), findsOneWidget);
    expect(find.text('Provider spend breakdown'), findsOneWidget);
    expect(find.text('100.0% of tracked INR spend'), findsOneWidget);
    expect(find.text('100.0% of tracked USD spend'), findsOneWidget);
    expect(find.text('Estimated continuous recording cost'), findsOneWidget);
    expect(
      find.text('Estimated if audio is continuously processed'),
      findsOneWidget,
    );
    expect(find.text('1 recorded hour'), findsOneWidget);
    expect(find.text('8 recorded hours'), findsOneWidget);
    expect(find.text('12 recorded hours'), findsOneWidget);
    expect(find.text('30-day estimate'), findsOneWidget);
    expect(find.text('Sarvam: ₹30.00'), findsWidgets);
    expect(find.text(r'OpenAI: $1.9200'), findsOneWidget);
    expect(find.text('Sarvam: ₹10800.00'), findsOneWidget);
    expect(find.text(r'OpenAI: $57.6000'), findsOneWidget);
    expect(find.text('Cost by location / kitchen'), findsOneWidget);
    expect(find.text('Cost by severity'), findsOneWidget);
    expect(find.text('Cost by category'), findsOneWidget);
    expect(find.text('Recorded duration'), findsWidgets);
    expect(find.text('Recent cost activity'), findsOneWidget);
    expect(find.text('inventory-note.wav'), findsOneWidget);
    expect(find.text('legacy-note.wav'), findsOneWidget);
    expect(find.text('2,750'), findsOneWidget);
    expect(find.text('Unavailable'), findsWidgets);
    expect(
      find.text(
        '1 upload is missing cost data. They are excluded from spend totals and cost averages.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Estimated Total Cost'), findsNothing);
  });

  testWidgets('Today and location filters request their own scoped data', (
    tester,
  ) async {
    final requests = <_Request>[];
    await _pumpAnalytics(
      tester,
      _FakeCostAnalyticsService((request) async {
        requests.add(request);
        return _analyticsData;
      }),
    );
    await tester.pumpAndSettle();

    final quickRequests = requests
        .where((request) => request.recentLimit == 1)
        .toList();
    expect(quickRequests, hasLength(3));
    expect(
      quickRequests.any(
        (request) =>
            request.startDate == DateTime(2026, 8, 14) &&
            request.endDate == DateTime(2026, 8, 14),
      ),
      isTrue,
    );
    expect(
      quickRequests.any(
        (request) =>
            request.startDate == DateTime(2026, 8, 8) &&
            request.endDate == DateTime(2026, 8, 14),
      ),
      isTrue,
    );
    expect(
      quickRequests.any(
        (request) =>
            request.startDate == DateTime(2026, 7, 16) &&
            request.endDate == DateTime(2026, 8, 14),
      ),
      isTrue,
    );

    final periodRequestStart = requests.length;
    await tester.tap(find.byKey(const ValueKey('cost-period-last30Days')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Today').last);
    await tester.pumpAndSettle();

    expect(
      requests
          .skip(periodRequestStart)
          .any(
            (request) =>
                request.startDate == DateTime(2026, 8, 14) &&
                request.endDate == DateTime(2026, 8, 14) &&
                request.recentLimit == 25,
          ),
      isTrue,
    );

    final locationRequestStart = requests.length;
    await tester.tap(find.byKey(const ValueKey('cost-location-null-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pastry Kitchen').last);
    await tester.pumpAndSettle();

    expect(
      requests
          .skip(locationRequestStart)
          .every((request) => request.locationId == 'location-2'),
      isTrue,
    );
  });

  testWidgets('keeps the analytics sections responsive on a narrow screen', (
    tester,
  ) async {
    await _pumpAnalytics(
      tester,
      _FakeCostAnalyticsService((_) async => _analyticsData),
      size: const Size(430, 900),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('Estimated continuous recording cost'), findsOneWidget);
    expect(
      find.byKey(const Key('cost-analytics-recent-usage-table')),
      findsOneWidget,
    );
  });
}

Future<void> _pumpAnalytics(
  WidgetTester tester,
  CostAnalyticsService service, {
  Size size = const Size(1400, 1100),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workspaceProvider.overrideWith(
          (ref) => WorkspaceNotifier(
            _UnusedWorkspaceRepository(),
            loadOnCreate: false,
            initialState: _workspaceState,
          ),
        ),
        costAnalyticsTodayProvider.overrideWithValue(DateTime(2026, 8, 14)),
        costAnalyticsServiceProvider.overrideWithValue(service),
      ],
      child: const MaterialApp(home: Scaffold(body: CostAnalyticsScreen())),
    ),
  );
  await tester.pump();
}

class _FakeCostAnalyticsService implements CostAnalyticsService {
  _FakeCostAnalyticsService(this.onFetch);

  final Future<CostAnalyticsData> Function(_Request request) onFetch;

  @override
  Future<CostAnalyticsData> fetch({
    required DateTime startDate,
    required DateTime endDate,
    required String workspaceId,
    String? locationId,
    int recentLimit = 25,
  }) {
    return onFetch(
      _Request(
        startDate: startDate,
        endDate: endDate,
        locationId: locationId,
        recentLimit: recentLimit,
      ),
    );
  }
}

class _Request {
  const _Request({
    required this.startDate,
    required this.endDate,
    required this.locationId,
    required this.recentLimit,
  });

  final DateTime startDate;
  final DateTime endDate;
  final String? locationId;
  final int recentLimit;
}

const _workspaceState = WorkspaceState(
  workspaces: [
    WorkspaceAccess(
      id: 'workspace-1',
      name: 'Restaurant',
      role: WorkspaceRole.owner,
      locations: [
        WorkspaceLocation(
          id: 'location-1',
          name: 'Main Kitchen',
          currencyCode: 'INR',
        ),
        WorkspaceLocation(
          id: 'location-2',
          name: 'Pastry Kitchen',
          currencyCode: 'INR',
        ),
      ],
    ),
  ],
  activeWorkspaceId: 'workspace-1',
  activeLocationId: 'location-1',
  isLoading: false,
);

class _UnusedWorkspaceRepository implements WorkspaceRepository {
  @override
  Future<WorkspaceContext> fetchContext() => throw UnimplementedError();

  @override
  Future<WorkspaceAccess> createWorkspace({
    required String name,
    required String locationName,
    required String currencyCode,
  }) => throw UnimplementedError();

  @override
  Future<WorkspaceLocation> createLocation({
    required String workspaceId,
    required String name,
    required String currencyCode,
  }) => throw UnimplementedError();
}

final _analyticsData = CostAnalyticsData(
  startDate: DateTime(2026, 7, 16),
  endDate: DateTime(2026, 8, 14),
  locationId: null,
  metrics: const CostAnalyticsMetrics(
    totalAudioUploads: 3,
    costedAudioUploads: 2,
    missingCostDataUploads: 1,
    totalRecordedAudioDurationSeconds: 210,
    costedAudioDurationSeconds: 180,
    totalSarvamCostInr: 1.5,
    totalOpenAiCostUsd: 0.008,
    averageSarvamCostPerUploadInr: 0.75,
    averageOpenAiCostPerUploadUsd: 0.004,
    averageSarvamCostPerRecordedMinuteInr: 0.5,
    averageOpenAiCostPerRecordedMinuteUsd: 0.00266667,
    estimatedSarvamCostPerRecordedHourInr: 30,
    estimatedOpenAiCostPerRecordedHourUsd: 0.16,
  ),
  byLocation: const [
    CostAnalyticsBreakdown(
      key: 'location-1',
      label: 'Main Kitchen',
      totalAudioUploads: 2,
      costedAudioUploads: 1,
      missingCostDataUploads: 1,
      recordedAudioDurationSeconds: 90,
      sarvamCostInr: 0.5,
      openAiCostUsd: 0.002,
    ),
    CostAnalyticsBreakdown(
      key: 'location-2',
      label: 'Pastry Kitchen',
      totalAudioUploads: 1,
      costedAudioUploads: 1,
      missingCostDataUploads: 0,
      recordedAudioDurationSeconds: 120,
      sarvamCostInr: 1,
      openAiCostUsd: 0.006,
    ),
  ],
  bySeverity: const [
    CostAnalyticsBreakdown(
      key: 'low',
      label: 'Low',
      totalAudioUploads: 1,
      costedAudioUploads: 1,
      missingCostDataUploads: 0,
      recordedAudioDurationSeconds: 60,
      sarvamCostInr: 0.5,
      openAiCostUsd: 0.002,
    ),
    CostAnalyticsBreakdown(
      key: 'medium',
      label: 'Medium',
      totalAudioUploads: 1,
      costedAudioUploads: 0,
      missingCostDataUploads: 1,
      recordedAudioDurationSeconds: 30,
      sarvamCostInr: null,
      openAiCostUsd: null,
    ),
    CostAnalyticsBreakdown(
      key: 'high',
      label: 'High',
      totalAudioUploads: 1,
      costedAudioUploads: 1,
      missingCostDataUploads: 0,
      recordedAudioDurationSeconds: 120,
      sarvamCostInr: 1,
      openAiCostUsd: 0.006,
    ),
  ],
  byCategory: const [
    CostAnalyticsBreakdown(
      key: 'staff',
      label: 'Staff',
      totalAudioUploads: 1,
      costedAudioUploads: 1,
      missingCostDataUploads: 0,
      recordedAudioDurationSeconds: 60,
      sarvamCostInr: 0.5,
      openAiCostUsd: 0.002,
    ),
    CostAnalyticsBreakdown(
      key: 'inventory',
      label: 'Inventory',
      totalAudioUploads: 1,
      costedAudioUploads: 1,
      missingCostDataUploads: 0,
      recordedAudioDurationSeconds: 120,
      sarvamCostInr: 1,
      openAiCostUsd: 0.006,
    ),
    CostAnalyticsBreakdown(
      key: 'operations',
      label: 'Operations',
      totalAudioUploads: 0,
      costedAudioUploads: 0,
      missingCostDataUploads: 0,
      recordedAudioDurationSeconds: 0,
      sarvamCostInr: null,
      openAiCostUsd: null,
    ),
    CostAnalyticsBreakdown(
      key: 'other',
      label: 'Other',
      totalAudioUploads: 1,
      costedAudioUploads: 0,
      missingCostDataUploads: 1,
      recordedAudioDurationSeconds: 30,
      sarvamCostInr: null,
      openAiCostUsd: null,
    ),
  ],
  recentUsage: [
    CostAnalyticsRecentUsage(
      uploadId: 'upload-2',
      processedAt: DateTime.utc(2026, 8, 14, 11),
      originalFilename: 'inventory-note.wav',
      audioDurationSeconds: 120,
      category: 'inventory',
      severity: 'high',
      sarvamEstimatedCostInr: 1,
      openAiEstimatedCostUsd: 0.006,
      openAiTotalTokens: 2750,
    ),
    CostAnalyticsRecentUsage(
      uploadId: 'upload-legacy',
      processedAt: DateTime.utc(2026, 8, 14, 10),
      originalFilename: 'legacy-note.wav',
      audioDurationSeconds: 30,
      category: 'other',
      severity: 'medium',
      sarvamEstimatedCostInr: null,
      openAiEstimatedCostUsd: null,
      openAiTotalTokens: null,
    ),
  ],
);
