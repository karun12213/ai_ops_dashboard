import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/cost_analytics.dart';
import '../models/workspace_context.dart';
import '../providers/cost_analytics_provider.dart';
import '../providers/workspace_provider.dart';
import '../widgets/page_header.dart';

class CostAnalyticsScreen extends ConsumerWidget {
  const CostAnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(effectiveCostAnalyticsFilterProvider);
    final analytics = ref.watch(costAnalyticsProvider);
    final quickSummaries = ref.watch(costAnalyticsQuickSummariesProvider);
    final locations =
        ref.watch(workspaceProvider).activeWorkspace?.locations ?? const [];

    return RefreshIndicator(
      onRefresh: () => _refresh(ref),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageHeader(
              title: 'Cost Analytics',
              description:
                  'Track AI audio-processing usage and provider spend over time.',
            ),
            const SizedBox(height: 28),
            _AnalyticsFilters(
              filter: filter,
              locations: locations,
              onPeriodChanged: (period) =>
                  _changePeriod(context, ref, filter, period),
              onLocationChanged: (location) {
                ref.read(costAnalyticsFilterProvider.notifier).state = filter
                    .withLocation(location);
              },
              onRefresh: () => _refresh(ref),
            ),
            const SizedBox(height: 16),
            _QuickSummarySection(summaries: quickSummaries),
            const SizedBox(height: 16),
            analytics.when(
              loading: () => const _AnalyticsLoading(),
              error: (_, _) => _AnalyticsError(
                onRetry: () => ref.invalidate(costAnalyticsProvider),
              ),
              data: (data) => _AnalyticsContent(data: data),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh(WidgetRef ref) async {
    final analytics = ref.refresh(costAnalyticsProvider.future);
    final summaries = ref.refresh(costAnalyticsQuickSummariesProvider.future);
    await Future.wait([analytics, summaries]);
  }

  Future<void> _changePeriod(
    BuildContext context,
    WidgetRef ref,
    CostAnalyticsFilter filter,
    CostAnalyticsPeriod period,
  ) async {
    if (period != CostAnalyticsPeriod.custom) {
      ref.read(costAnalyticsFilterProvider.notifier).state = filter.withPeriod(
        period,
        ref.read(costAnalyticsTodayProvider),
      );
      return;
    }
    final today = ref.read(costAnalyticsTodayProvider);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: today,
      initialDateRange: DateTimeRange(
        start: filter.startDate,
        end: filter.endDate,
      ),
      helpText: 'Select cost analytics range',
    );
    if (picked == null || !context.mounted) return;
    if (picked.duration.inDays + 1 > 366) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a range of 366 days or fewer.')),
      );
      return;
    }
    ref.read(costAnalyticsFilterProvider.notifier).state = filter
        .withCustomRange(picked.start, picked.end);
  }
}

class _AnalyticsFilters extends StatelessWidget {
  const _AnalyticsFilters({
    required this.filter,
    required this.locations,
    required this.onPeriodChanged,
    required this.onLocationChanged,
    required this.onRefresh,
  });

  static const _allLocations = '';

  final CostAnalyticsFilter filter;
  final List<WorkspaceLocation> locations;
  final ValueChanged<CostAnalyticsPeriod> onPeriodChanged;
  final ValueChanged<WorkspaceLocation?> onLocationChanged;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<CostAnalyticsPeriod>(
                key: ValueKey('cost-period-${filter.period.name}'),
                initialValue: filter.period,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Period',
                  isDense: true,
                ),
                items: [
                  for (final period in CostAnalyticsPeriod.values)
                    DropdownMenuItem(
                      value: period,
                      child: Text(_periodLabel(period)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) onPeriodChanged(value);
                },
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                key: ValueKey(
                  'cost-location-${filter.locationId}-${locations.length}',
                ),
                initialValue: filter.locationId ?? _allLocations,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Location / Kitchen',
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(
                    value: _allLocations,
                    child: Text('All locations / kitchens'),
                  ),
                  for (final location in locations)
                    DropdownMenuItem(
                      value: location.id,
                      child: Text(location.name),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  if (value == _allLocations) {
                    onLocationChanged(null);
                    return;
                  }
                  onLocationChanged(
                    locations.firstWhere((location) => location.id == value),
                  );
                },
              ),
            ),
            OutlinedButton.icon(
              key: const Key('cost-analytics-refresh-button'),
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh'),
            ),
            Text(
              _rangeLabel(filter.startDate, filter.endDate),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnalyticsContent extends StatelessWidget {
  const _AnalyticsContent({required this.data});

  final CostAnalyticsData data;

  @override
  Widget build(BuildContext context) {
    final metrics = data.metrics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (metrics.missingCostDataUploads > 0) ...[
          _MissingCostNotice(count: metrics.missingCostDataUploads),
          const SizedBox(height: 16),
        ],
        _MetricGrid(metrics: metrics),
        const SizedBox(height: 16),
        _ProviderSpendCard(metrics: metrics),
        const SizedBox(height: 16),
        _ContinuousRecordingCostCard(metrics: metrics),
        const SizedBox(height: 16),
        _BreakdownCard(
          title: 'Cost by location / kitchen',
          rows: data.byLocation,
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final severity = _BreakdownCard(
              title: 'Cost by severity',
              rows: data.bySeverity,
            );
            final category = _BreakdownCard(
              title: 'Cost by category',
              rows: data.byCategory,
            );
            if (constraints.maxWidth < 900) {
              return Column(
                children: [severity, const SizedBox(height: 16), category],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: severity),
                const SizedBox(width: 16),
                Expanded(child: category),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        _RecentUsageCard(rows: data.recentUsage),
      ],
    );
  }
}

class _QuickSummarySection extends StatelessWidget {
  const _QuickSummarySection({required this.summaries});

  final AsyncValue<List<CostAnalyticsQuickSummary>> summaries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Quick summaries',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        summaries.when(
          loading: () => const _QuickSummaryLoading(),
          error: (_, _) => const _QuickSummaryUnavailable(),
          data: (items) => LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1000
                  ? 3
                  : constraints.maxWidth >= 650
                  ? 2
                  : 1;
              const gap = 16.0;
              final width =
                  (constraints.maxWidth - (columns - 1) * gap) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final item in items)
                    SizedBox(
                      width: width,
                      child: _QuickSummaryCard(summary: item),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _QuickSummaryCard extends StatelessWidget {
  const _QuickSummaryCard({required this.summary});

  final CostAnalyticsQuickSummary summary;

  @override
  Widget build(BuildContext context) {
    final metrics = summary.metrics;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _quickSummaryLabel(summary.period),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.9,
              ),
            ),
            const SizedBox(height: 14),
            _SummaryRow(
              label: 'Uploads',
              value: _formatInteger(metrics.totalAudioUploads),
            ),
            _SummaryRow(
              label: 'Recorded duration',
              value: _formatDuration(metrics.totalRecordedAudioDurationSeconds),
            ),
            _SummaryRow(
              label: 'Sarvam',
              value: _formatInr(metrics.totalSarvamCostInr),
            ),
            _SummaryRow(
              label: 'OpenAI',
              value: _formatUsd(metrics.totalOpenAiCostUsd),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _QuickSummaryLoading extends StatelessWidget {
  const _QuickSummaryLoading();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _QuickSummaryUnavailable extends StatelessWidget {
  const _QuickSummaryUnavailable();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Text(
          'Quick summaries are unavailable.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _MissingCostNotice extends StatelessWidget {
  const _MissingCostNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              color: Theme.of(context).colorScheme.tertiary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$count ${count == 1 ? 'upload is' : 'uploads are'} missing cost data. '
                'They are excluded from spend totals and cost averages.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});

  final CostAnalyticsMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      _MetricCard(
        label: 'Total audio uploads',
        value: _formatInteger(metrics.totalAudioUploads),
        icon: Icons.library_music_outlined,
      ),
      _MetricCard(
        label: 'Total recorded audio duration',
        value: _formatDuration(metrics.totalRecordedAudioDurationSeconds),
        icon: Icons.timer_outlined,
      ),
      _MetricCard(
        label: 'Total Sarvam cost',
        value: _formatInr(metrics.totalSarvamCostInr),
        caption: 'INR',
        icon: Icons.currency_rupee_rounded,
      ),
      _MetricCard(
        label: 'Total OpenAI cost',
        value: _formatUsd(metrics.totalOpenAiCostUsd),
        caption: 'USD',
        icon: Icons.token_outlined,
      ),
      _PairedMetricCard(
        label: 'Average cost per upload',
        inr: metrics.averageSarvamCostPerUploadInr,
        usd: metrics.averageOpenAiCostPerUploadUsd,
        icon: Icons.functions_rounded,
      ),
      _PairedMetricCard(
        label: 'Average cost per recorded minute',
        inr: metrics.averageSarvamCostPerRecordedMinuteInr,
        usd: metrics.averageOpenAiCostPerRecordedMinuteUsd,
        icon: Icons.av_timer_rounded,
      ),
      _PairedMetricCard(
        label: 'Estimated cost per recorded hour',
        inr: metrics.estimatedSarvamCostPerRecordedHourInr,
        usd: metrics.estimatedOpenAiCostPerRecordedHourUsd,
        icon: Icons.schedule_rounded,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1150
            ? 4
            : constraints.maxWidth >= 650
            ? 2
            : 1;
        const gap = 16.0;
        final width = (constraints.maxWidth - (columns - 1) * gap) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards) SizedBox(width: width, child: card),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    this.caption,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (caption != null) ...[
              const SizedBox(height: 3),
              Text(caption!, style: Theme.of(context).textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _PairedMetricCard extends StatelessWidget {
  const _PairedMetricCard({
    required this.label,
    required this.inr,
    required this.usd,
    required this.icon,
  });

  final String label;
  final double? inr;
  final double? usd;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('Sarvam: ${_formatInr(inr)}'),
            const SizedBox(height: 5),
            Text('OpenAI: ${_formatUsd(usd)}'),
          ],
        ),
      ),
    );
  }
}

class _ProviderSpendCard extends StatelessWidget {
  const _ProviderSpendCard({required this.metrics});

  final CostAnalyticsMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Provider spend breakdown',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Percentages are normalized separately for INR and USD. They do not compare or combine currencies.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 36,
              runSpacing: 14,
              children: [
                _ProviderValue(
                  label: 'Sarvam',
                  value: _formatInr(metrics.totalSarvamCostInr),
                  percentageLabel: metrics.totalSarvamCostInr == null
                      ? 'Percentage unavailable'
                      : '100.0% of tracked INR spend',
                  color: const Color(0xFF42D3A5),
                ),
                _ProviderValue(
                  label: 'OpenAI',
                  value: _formatUsd(metrics.totalOpenAiCostUsd),
                  percentageLabel: metrics.totalOpenAiCostUsd == null
                      ? 'Percentage unavailable'
                      : '100.0% of tracked USD spend',
                  color: const Color(0xFF64B5F6),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderValue extends StatelessWidget {
  const _ProviderValue({
    required this.label,
    required this.value,
    required this.percentageLabel,
    required this.color,
  });

  final String label;
  final String value;
  final String percentageLabel;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value == 'Unavailable' ? 0 : 1,
              minHeight: 7,
              color: color,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            percentageLabel,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinuousRecordingCostCard extends StatelessWidget {
  const _ContinuousRecordingCostCard({required this.metrics});

  static const _thirtyDayRecordedHours = 12 * 30;

  final CostAnalyticsMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final estimates = [
      const _RecordingEstimate(label: '1 recorded hour', hours: 1),
      const _RecordingEstimate(label: '8 recorded hours', hours: 8),
      const _RecordingEstimate(label: '12 recorded hours', hours: 12),
      const _RecordingEstimate(
        label: '30-day estimate',
        hours: _thirtyDayRecordedHours,
        detail: '12 recorded hours/day × 30 days',
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.multiline_chart_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Estimated continuous recording cost',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Estimated if audio is continuously processed',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 1000
                    ? 4
                    : constraints.maxWidth >= 560
                    ? 2
                    : 1;
                const gap = 12.0;
                final width =
                    (constraints.maxWidth - (columns - 1) * gap) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final estimate in estimates)
                      SizedBox(
                        width: width,
                        child: _RecordingEstimateTile(
                          estimate: estimate,
                          sarvamHourlyRate:
                              metrics.estimatedSarvamCostPerRecordedHourInr,
                          openAiHourlyRate:
                              metrics.estimatedOpenAiCostPerRecordedHourUsd,
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            Text(
              'The 30-day scenario assumes 12 full recorded hours are processed each day. '
              'It is a planning estimate, not a prediction of kitchen usage or billable audio.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingEstimate {
  const _RecordingEstimate({
    required this.label,
    required this.hours,
    this.detail,
  });

  final String label;
  final int hours;
  final String? detail;
}

class _RecordingEstimateTile extends StatelessWidget {
  const _RecordingEstimateTile({
    required this.estimate,
    required this.sarvamHourlyRate,
    required this.openAiHourlyRate,
  });

  final _RecordingEstimate estimate;
  final double? sarvamHourlyRate;
  final double? openAiHourlyRate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            estimate.label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (estimate.detail != null) ...[
            const SizedBox(height: 3),
            Text(
              estimate.detail!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Sarvam: ${_formatInr(_estimate(sarvamHourlyRate, estimate.hours))}',
          ),
          const SizedBox(height: 4),
          Text(
            'OpenAI: ${_formatUsd(_estimate(openAiHourlyRate, estimate.hours))}',
          ),
        ],
      ),
    );
  }

  static double? _estimate(double? hourlyRate, int hours) {
    return hourlyRate == null ? null : hourlyRate * hours;
  }
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.title, required this.rows});

  final String title;
  final List<CostAnalyticsBreakdown> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'No uploads in this period.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Group')),
                    DataColumn(label: Text('Uploads'), numeric: true),
                    DataColumn(label: Text('Recorded duration'), numeric: true),
                    DataColumn(label: Text('Sarvam (INR)'), numeric: true),
                    DataColumn(label: Text('OpenAI (USD)'), numeric: true),
                  ],
                  rows: [
                    for (final row in rows)
                      DataRow(
                        cells: [
                          DataCell(Text(row.label)),
                          DataCell(Text(_formatInteger(row.totalAudioUploads))),
                          DataCell(
                            Text(
                              _formatDuration(row.recordedAudioDurationSeconds),
                            ),
                          ),
                          DataCell(Text(_formatInr(row.sarvamCostInr))),
                          DataCell(Text(_formatUsd(row.openAiCostUsd))),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecentUsageCard extends StatelessWidget {
  const _RecentUsageCard({required this.rows});

  final List<CostAnalyticsRecentUsage> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Recent cost activity',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Text(
                  'No processed audio uploads in this period.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  key: const Key('cost-analytics-recent-usage-table'),
                  columns: const [
                    DataColumn(label: Text('Processed')),
                    DataColumn(label: Text('Original filename')),
                    DataColumn(label: Text('Duration'), numeric: true),
                    DataColumn(label: Text('Category')),
                    DataColumn(label: Text('Severity')),
                    DataColumn(label: Text('Sarvam cost'), numeric: true),
                    DataColumn(label: Text('OpenAI cost'), numeric: true),
                    DataColumn(label: Text('Total tokens'), numeric: true),
                  ],
                  rows: [
                    for (final row in rows)
                      DataRow(
                        cells: [
                          DataCell(Text(_formatDateTime(row.processedAt))),
                          DataCell(
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 240),
                              child: Text(
                                row.originalFilename,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(_formatSeconds(row.audioDurationSeconds)),
                          ),
                          DataCell(Text(_titleCase(row.category))),
                          DataCell(Text(_titleCase(row.severity))),
                          DataCell(
                            Text(_formatInr(row.sarvamEstimatedCostInr)),
                          ),
                          DataCell(
                            Text(_formatUsd(row.openAiEstimatedCostUsd)),
                          ),
                          DataCell(
                            Text(_formatOptionalInteger(row.openAiTotalTokens)),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AnalyticsLoading extends StatelessWidget {
  const _AnalyticsLoading();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 72),
        child: Column(
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('Loading cost analytics…'),
          ],
        ),
      ),
    );
  }
}

class _AnalyticsError extends StatelessWidget {
  const _AnalyticsError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Column(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              'Cost analytics are unavailable',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

String _periodLabel(CostAnalyticsPeriod period) => switch (period) {
  CostAnalyticsPeriod.today => 'Today',
  CostAnalyticsPeriod.last7Days => 'Last 7 Days',
  CostAnalyticsPeriod.last30Days => 'Last 30 Days',
  CostAnalyticsPeriod.custom => 'Custom date range',
};

String _quickSummaryLabel(CostAnalyticsPeriod period) => switch (period) {
  CostAnalyticsPeriod.today => 'TODAY',
  CostAnalyticsPeriod.last7Days => '7 DAYS',
  CostAnalyticsPeriod.last30Days => '30 DAYS',
  CostAnalyticsPeriod.custom => 'CUSTOM',
};

String _formatInr(double? value) =>
    value == null ? 'Unavailable' : '₹${value.toStringAsFixed(2)}';

String _formatUsd(double? value) =>
    value == null ? 'Unavailable' : '\$${value.toStringAsFixed(4)}';

String _formatInteger(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return '${value < 0 ? '-' : ''}$buffer';
}

String _formatOptionalInteger(int? value) =>
    value == null ? 'Unavailable' : _formatInteger(value);

String _formatDuration(double seconds) {
  if (seconds < 60) return '${seconds.toStringAsFixed(1)} sec';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  if (hours > 0) {
    return '$hours hr $minutes min ${remaining.toStringAsFixed(1)} sec';
  }
  return '$minutes min ${remaining.toStringAsFixed(1)} sec';
}

String _formatSeconds(double? seconds) =>
    seconds == null ? 'Unavailable' : '${seconds.toStringAsFixed(1)} sec';

String _rangeLabel(DateTime startDate, DateTime endDate) {
  return '${_shortDate(startDate)} – ${_shortDate(endDate)}, ${endDate.year}';
}

String _shortDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[value.month - 1]} ${value.day}';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  return '${_shortDate(local)}, ${local.year} $hour:$minute ${local.hour < 12 ? 'AM' : 'PM'}';
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return '${value[0].toUpperCase()}${value.substring(1)}';
}
