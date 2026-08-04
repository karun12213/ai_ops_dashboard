import 'dart:async';
import 'dart:typed_data';

import 'package:ai_ops_dashboard/models/report_data.dart';
import 'package:ai_ops_dashboard/models/workspace_context.dart';
import 'package:ai_ops_dashboard/providers/report_provider.dart';
import 'package:ai_ops_dashboard/providers/workspace_provider.dart';
import 'package:ai_ops_dashboard/screens/reports_screen.dart';
import 'package:ai_ops_dashboard/services/csv_export_saver.dart';
import 'package:ai_ops_dashboard/services/report_service.dart';
import 'package:ai_ops_dashboard/services/workspace_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a loading state while Reports data is pending', (
    tester,
  ) async {
    final completer = Completer<ReportData>();
    await _pumpReports(
      tester,
      _FakeReportService(
        onFetch: ({required startDate, required endDate, locationId}) {
          return completer.future;
        },
      ),
    );

    expect(find.text('Loading reports…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(_emptyData);
    await tester.pumpAndSettle();
  });

  testWidgets('shows the API empty state without manufactured report values', (
    tester,
  ) async {
    await _pumpReports(
      tester,
      _FakeReportService(
        onFetch: ({required startDate, required endDate, locationId}) async =>
            _emptyData,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No report data for this period'), findsOneWidget);
    expect(find.text('Revenue total'), findsNothing);
    expect(find.text('Bandra'), findsNothing);
  });

  testWidgets('shows a safe error and retries the Reports request', (
    tester,
  ) async {
    var requests = 0;
    final service = _FakeReportService(
      onFetch: ({required startDate, required endDate, locationId}) async {
        requests += 1;
        if (requests == 1) throw StateError('Sensitive backend detail');
        return _emptyData;
      },
    );
    await _pumpReports(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('Reports are unavailable'), findsOneWidget);
    expect(find.text('Sensitive backend detail'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pumpAndSettle();

    expect(requests, 2);
    expect(find.text('No report data for this period'), findsOneWidget);
  });

  testWidgets('renders totals, trend, channels, and location performance', (
    tester,
  ) async {
    await _pumpReports(
      tester,
      _FakeReportService(
        onFetch: ({required startDate, required endDate, locationId}) async =>
            _populatedData,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Revenue total'), findsOneWidget);
    expect(find.text('Order total'), findsOneWidget);
    expect(find.text('Average ticket'), findsOneWidget);
    expect(find.text('₹102'), findsWidgets);
    expect(find.text('4'), findsWidgets);
    expect(find.text('₹25.50'), findsWidgets);
    expect(find.text('Revenue trend'), findsOneWidget);
    expect(find.text('Dine-in'), findsOneWidget);
    expect(find.text('75.0%'), findsOneWidget);
    expect(find.text('Bandra'), findsWidgets);
    expect(find.text('+12.8%'), findsOneWidget);
  });

  testWidgets('location and period filters issue new scoped requests', (
    tester,
  ) async {
    final requests = <_FetchRequest>[];
    final service = _FakeReportService(
      onFetch: ({required startDate, required endDate, locationId}) async {
        requests.add(
          _FetchRequest(
            startDate: startDate,
            endDate: endDate,
            locationId: locationId,
          ),
        );
        return _populatedData;
      },
    );
    await _pumpReports(tester, service);
    await tester.pumpAndSettle();

    expect(requests.single.startDate, DateTime(2026, 7, 5));
    expect(requests.single.endDate, DateTime(2026, 8, 3));

    await tester.tap(find.text('All locations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bandra').last);
    await tester.pumpAndSettle();

    expect(requests.last.locationId, _locationId);

    await tester.tap(find.text('Last 30 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Last 7 days').last);
    await tester.pumpAndSettle();

    expect(requests.last.startDate, DateTime(2026, 7, 28));
    expect(requests.last.endDate, DateTime(2026, 8, 3));
    expect(requests.last.locationId, _locationId);
  });

  testWidgets('refresh reloads and CSV export saves the active filter', (
    tester,
  ) async {
    var fetches = 0;
    _FetchRequest? exported;
    final saver = _FakeCsvExportSaver();
    final service = _FakeReportService(
      onFetch: ({required startDate, required endDate, locationId}) async {
        fetches += 1;
        return _populatedData;
      },
      onExport: ({required startDate, required endDate, locationId}) async {
        exported = _FetchRequest(
          startDate: startDate,
          endDate: endDate,
          locationId: locationId,
        );
        return ReportExport(
          bytes: Uint8List.fromList([1, 2, 3]),
          filename: 'reports.csv',
        );
      },
    );
    await _pumpReports(tester, service, saver: saver);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('reports-refresh-button')));
    await tester.pumpAndSettle();
    expect(fetches, 2);

    await tester.tap(find.byKey(const Key('reports-export-button')));
    await tester.pumpAndSettle();

    expect(exported?.startDate, DateTime(2026, 7, 5));
    expect(exported?.endDate, DateTime(2026, 8, 3));
    expect(saver.saved?.filename, 'reports.csv');
    expect(saver.saved?.bytes, [1, 2, 3]);
    expect(find.text('CSV export completed.'), findsOneWidget);
  });
}

typedef _FetchCallback =
    Future<ReportData> Function({
      required DateTime startDate,
      required DateTime endDate,
      String? locationId,
    });

typedef _ExportCallback =
    Future<ReportExport> Function({
      required DateTime startDate,
      required DateTime endDate,
      String? locationId,
    });

class _FakeReportService implements ReportService {
  _FakeReportService({required this.onFetch, this.onExport});

  final _FetchCallback onFetch;
  final _ExportCallback? onExport;

  @override
  Future<ReportData> fetch({
    required DateTime startDate,
    required DateTime endDate,
    required String workspaceId,
    String? locationId,
  }) {
    return onFetch(
      startDate: startDate,
      endDate: endDate,
      locationId: locationId,
    );
  }

  @override
  Future<ReportExport> exportCsv({
    required DateTime startDate,
    required DateTime endDate,
    required String workspaceId,
    String? locationId,
  }) {
    final callback = onExport;
    if (callback == null) throw StateError('Export should not be called.');
    return callback(
      startDate: startDate,
      endDate: endDate,
      locationId: locationId,
    );
  }
}

class _FakeCsvExportSaver implements CsvExportSaver {
  ReportExport? saved;

  @override
  Future<void> save(ReportExport export) async {
    saved = export;
  }
}

class _FetchRequest {
  const _FetchRequest({
    required this.startDate,
    required this.endDate,
    required this.locationId,
  });

  final DateTime startDate;
  final DateTime endDate;
  final String? locationId;
}

Future<void> _pumpReports(
  WidgetTester tester,
  ReportService service, {
  CsvExportSaver? saver,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
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
        reportTodayProvider.overrideWithValue(DateTime(2026, 8, 3)),
        reportServiceProvider.overrideWithValue(service),
        if (saver != null) csvExportSaverProvider.overrideWithValue(saver),
      ],
      child: const MaterialApp(home: Scaffold(body: ReportsScreen())),
    ),
  );
  await tester.pump();
}

const _locationId = '95cd56e6-228e-47dc-8fb4-3ac8760c2082';

const _workspaceState = WorkspaceState(
  workspaces: [
    WorkspaceAccess(
      id: 'workspace-1',
      name: 'Restaurant',
      role: WorkspaceRole.owner,
      locations: [
        WorkspaceLocation(id: _locationId, name: 'Bandra', currencyCode: 'INR'),
      ],
    ),
  ],
  activeWorkspaceId: 'workspace-1',
  activeLocationId: _locationId,
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

final _emptyData = ReportData(
  startDate: DateTime(2026, 7, 5),
  endDate: DateTime(2026, 8, 3),
  locationId: null,
  locations: const [],
  totals: const ReportTotals(
    currencyCode: null,
    revenueTotalMinor: 0,
    orderTotal: 0,
    averageTicketMinor: 0,
  ),
  channelSplit: const [],
  revenueTrend: const [],
  locationPerformance: const [],
);

final _populatedData = ReportData(
  startDate: DateTime(2026, 7, 5),
  endDate: DateTime(2026, 8, 3),
  locationId: null,
  locations: const [ReportLocation(id: _locationId, name: 'Bandra')],
  totals: const ReportTotals(
    currencyCode: 'INR',
    revenueTotalMinor: 10200,
    orderTotal: 4,
    averageTicketMinor: 2550,
  ),
  channelSplit: const [
    ReportChannel(
      channel: 'dine_in',
      label: 'Dine-in',
      revenueMinor: 7650,
      orderTotal: 3,
      revenuePercent: 75,
    ),
    ReportChannel(
      channel: 'delivery',
      label: 'Delivery',
      revenueMinor: 2550,
      orderTotal: 1,
      revenuePercent: 25,
    ),
  ],
  revenueTrend: [
    ReportTrendPoint(date: _augustSecond, revenueMinor: 3000, orderTotal: 1),
    ReportTrendPoint(date: _augustThird, revenueMinor: 7200, orderTotal: 3),
  ],
  locationPerformance: const [
    ReportLocationPerformance(
      locationId: _locationId,
      locationName: 'Bandra',
      currencyCode: 'INR',
      revenueMinor: 10200,
      orderTotal: 4,
      averageTicketMinor: 2550,
      revenueGrowthPercent: 12.8,
    ),
  ],
);

final _augustSecond = DateTime(2026, 8, 2);
final _augustThird = DateTime(2026, 8, 3);
