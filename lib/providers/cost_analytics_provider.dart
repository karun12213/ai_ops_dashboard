import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/cost_analytics.dart';
import '../models/workspace_context.dart';
import '../services/cost_analytics_service.dart';
import 'auth_provider.dart';
import 'workspace_provider.dart';

enum CostAnalyticsPeriod { today, last7Days, last30Days, custom }

class CostAnalyticsQuickSummary {
  const CostAnalyticsQuickSummary({
    required this.period,
    required this.metrics,
  });

  final CostAnalyticsPeriod period;
  final CostAnalyticsMetrics metrics;
}

class CostAnalyticsFilter {
  const CostAnalyticsFilter({
    required this.period,
    required this.startDate,
    required this.endDate,
    this.locationId,
  });

  final CostAnalyticsPeriod period;
  final DateTime startDate;
  final DateTime endDate;
  final String? locationId;

  factory CostAnalyticsFilter.forPeriod(
    CostAnalyticsPeriod period,
    DateTime today,
  ) {
    final endDate = DateTime(today.year, today.month, today.day);
    final startDate = switch (period) {
      CostAnalyticsPeriod.today => endDate,
      CostAnalyticsPeriod.last7Days => endDate.subtract(
        const Duration(days: 6),
      ),
      CostAnalyticsPeriod.last30Days => endDate.subtract(
        const Duration(days: 29),
      ),
      CostAnalyticsPeriod.custom => endDate,
    };
    return CostAnalyticsFilter(
      period: period,
      startDate: startDate,
      endDate: endDate,
    );
  }

  CostAnalyticsFilter withPeriod(CostAnalyticsPeriod value, DateTime today) {
    final range = CostAnalyticsFilter.forPeriod(value, today);
    return CostAnalyticsFilter(
      period: value,
      startDate: range.startDate,
      endDate: range.endDate,
      locationId: locationId,
    );
  }

  CostAnalyticsFilter withCustomRange(DateTime start, DateTime end) {
    return CostAnalyticsFilter(
      period: CostAnalyticsPeriod.custom,
      startDate: DateTime(start.year, start.month, start.day),
      endDate: DateTime(end.year, end.month, end.day),
      locationId: locationId,
    );
  }

  CostAnalyticsFilter withLocation(WorkspaceLocation? location) {
    return CostAnalyticsFilter(
      period: period,
      startDate: startDate,
      endDate: endDate,
      locationId: location?.id,
    );
  }
}

final costAnalyticsTodayProvider = Provider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

final costAnalyticsFilterProvider =
    StateProvider.autoDispose<CostAnalyticsFilter>((ref) {
      return CostAnalyticsFilter.forPeriod(
        CostAnalyticsPeriod.last30Days,
        ref.watch(costAnalyticsTodayProvider),
      );
    });

final costAnalyticsServiceProvider = Provider<CostAnalyticsService>((ref) {
  return CostAnalyticsService(ref.watch(apiClientProvider));
});

final effectiveCostAnalyticsFilterProvider =
    Provider.autoDispose<CostAnalyticsFilter>((ref) {
      final filter = ref.watch(costAnalyticsFilterProvider);
      final workspace = ref.watch(workspaceProvider).activeWorkspace;
      if (filter.locationId == null ||
          workspace?.locationById(filter.locationId) != null) {
        return filter;
      }
      return filter.withLocation(null);
    });

final costAnalyticsProvider = FutureProvider.autoDispose<CostAnalyticsData>((
  ref,
) {
  final filter = ref.watch(effectiveCostAnalyticsFilterProvider);
  final workspace = ref.watch(workspaceProvider).activeWorkspace;
  if (workspace == null) throw StateError('Workspace context is required.');
  return ref
      .watch(costAnalyticsServiceProvider)
      .fetch(
        startDate: filter.startDate,
        endDate: filter.endDate,
        workspaceId: workspace.id,
        locationId: filter.locationId,
      );
});

final costAnalyticsQuickSummariesProvider =
    FutureProvider.autoDispose<List<CostAnalyticsQuickSummary>>((ref) async {
      final locationId = ref.watch(
        effectiveCostAnalyticsFilterProvider.select(
          (filter) => filter.locationId,
        ),
      );
      final today = ref.watch(costAnalyticsTodayProvider);
      final workspace = ref.watch(workspaceProvider).activeWorkspace;
      if (workspace == null) {
        throw StateError('Workspace context is required.');
      }
      final service = ref.watch(costAnalyticsServiceProvider);
      const periods = [
        CostAnalyticsPeriod.today,
        CostAnalyticsPeriod.last7Days,
        CostAnalyticsPeriod.last30Days,
      ];
      final summaries = await Future.wait(
        periods.map((period) async {
          final range = CostAnalyticsFilter.forPeriod(period, today);
          final data = await service.fetch(
            startDate: range.startDate,
            endDate: range.endDate,
            workspaceId: workspace.id,
            locationId: locationId,
            recentLimit: 1,
          );
          return CostAnalyticsQuickSummary(
            period: period,
            metrics: data.metrics,
          );
        }),
      );
      return summaries;
    });
