import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/report_data.dart';
import '../providers/report_provider.dart';
import '../widgets/page_header.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  bool _isExporting = false;

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(reportFilterProvider);
    final report = ref.watch(reportProvider);
    final currentData = report.asData?.value;
    final canExport = report.asData != null && !_isExporting;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageHeader(
              title: 'Reports',
              description:
                  'Review financial and operational performance across locations.',
              action: FilledButton.icon(
                key: const Key('reports-export-button'),
                onPressed: canExport ? _export : null,
                icon: _isExporting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_download_outlined, size: 18),
                label: Text(_isExporting ? 'Exporting…' : 'Export CSV'),
              ),
            ),
            const SizedBox(height: 28),
            _ReportFilters(
              filter: filter,
              locations: currentData?.locations ?? const [],
              onLocationChanged: _changeLocation,
              onPeriodChanged: _changePeriod,
              onRefresh: _refresh,
            ),
            const SizedBox(height: 16),
            report.when(
              loading: () => const _ReportsLoading(),
              error: (_, _) => _ReportsError(onRetry: _refresh),
              data: (data) => data.hasData
                  ? _ReportContent(data: data, filter: filter)
                  : const _ReportsEmpty(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    ref.invalidate(reportProvider);
    try {
      await ref.read(reportProvider.future);
    } catch (_) {
      // The AsyncValue renders the safe error state.
    }
  }

  void _changeLocation(ReportLocation? location) {
    final filter = ref.read(reportFilterProvider);
    ref.read(reportFilterProvider.notifier).state = filter.withLocation(
      location,
    );
  }

  void _changePeriod(ReportPeriod period) {
    final filter = ref.read(reportFilterProvider);
    ref.read(reportFilterProvider.notifier).state = filter.withPeriod(
      period,
      ref.read(reportTodayProvider),
    );
  }

  Future<void> _export() async {
    final filter = ref.read(reportFilterProvider);
    setState(() => _isExporting = true);
    try {
      final export = await ref
          .read(reportServiceProvider)
          .exportCsv(
            startDate: filter.startDate,
            endDate: filter.endDate,
            locationId: filter.locationId,
          );
      await ref.read(csvExportSaverProvider).save(export);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('CSV export completed.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('CSV export failed. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }
}

class _ReportFilters extends StatelessWidget {
  const _ReportFilters({
    required this.filter,
    required this.locations,
    required this.onLocationChanged,
    required this.onPeriodChanged,
    required this.onRefresh,
  });

  static const _allLocations = '';

  final ReportFilter filter;
  final List<ReportLocation> locations;
  final ValueChanged<ReportLocation?> onLocationChanged;
  final ValueChanged<ReportPeriod> onPeriodChanged;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final visibleLocations = [...locations];
    if (filter.locationId != null &&
        !visibleLocations.any((item) => item.id == filter.locationId)) {
      visibleLocations.add(
        ReportLocation(
          id: filter.locationId!,
          name: filter.locationName ?? 'Selected location',
        ),
      );
    }

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
              child: DropdownButtonFormField<String>(
                key: ValueKey(
                  'reports-location-${filter.locationId}-${visibleLocations.length}',
                ),
                initialValue: filter.locationId ?? _allLocations,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Location',
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(
                    value: _allLocations,
                    child: Text('All locations'),
                  ),
                  for (final location in visibleLocations)
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
                    visibleLocations.firstWhere((item) => item.id == value),
                  );
                },
              ),
            ),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<ReportPeriod>(
                key: ValueKey('reports-period-${filter.period.name}'),
                initialValue: filter.period,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Period',
                  isDense: true,
                ),
                items: [
                  for (final period in ReportPeriod.values)
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
            OutlinedButton.icon(
              key: const Key('reports-refresh-button'),
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

class _ReportContent extends StatelessWidget {
  const _ReportContent({required this.data, required this.filter});

  final ReportData data;
  final ReportFilter filter;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TotalsGrid(totals: data.totals),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < 820;
            final performance = _PerformanceCard(data: data, filter: filter);
            final channels = _ChannelMixCard(channels: data.channelSplit);
            if (stacked) {
              return Column(
                children: [performance, const SizedBox(height: 16), channels],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: performance),
                const SizedBox(width: 16),
                Expanded(child: channels),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        _LocationTable(rows: data.locationPerformance),
      ],
    );
  }
}

class _TotalsGrid extends StatelessWidget {
  const _TotalsGrid({required this.totals});

  final ReportTotals totals;

  @override
  Widget build(BuildContext context) {
    final currency = totals.currencyCode ?? '';
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 3
            : constraints.maxWidth >= 560
            ? 2
            : 1;
        const gap = 16.0;
        final width = (constraints.maxWidth - (columns - 1) * gap) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            SizedBox(
              width: width,
              child: _TotalCard(
                label: 'Revenue total',
                value: _formatMoney(totals.revenueTotalMinor, currency),
                icon: Icons.payments_outlined,
                color: const Color(0xFF42D3A5),
              ),
            ),
            SizedBox(
              width: width,
              child: _TotalCard(
                label: 'Order total',
                value: _formatInteger(totals.orderTotal),
                icon: Icons.receipt_long_outlined,
                color: const Color(0xFF64B5F6),
              ),
            ),
            SizedBox(
              width: width,
              child: _TotalCard(
                label: 'Average ticket',
                value: _formatMoney(totals.averageTicketMinor, currency),
                icon: Icons.point_of_sale_outlined,
                color: const Color(0xFFFFB74D),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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

class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard({required this.data, required this.filter});

  final ReportData data;
  final ReportFilter filter;

  @override
  Widget build(BuildContext context) {
    final currency = data.totals.currencyCode ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Revenue trend',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  _formatMoney(data.totals.revenueTotalMinor, currency),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              filter.locationName == null
                  ? 'Combined across all locations'
                  : filter.locationName!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 220,
              child: CustomPaint(
                painter: _TrendPainter(
                  values: [
                    for (final point in data.revenueTrend) point.revenueMinor,
                  ],
                  color: Theme.of(context).colorScheme.primary,
                ),
                size: Size.infinite,
              ),
            ),
            const SizedBox(height: 8),
            _TrendLabels(points: data.revenueTrend),
          ],
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({required this.values, required this.color});

  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()..color = color.withValues(alpha: 0.10);
    for (var line = 0; line <= 4; line++) {
      final y = size.height * line / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    if (values.isEmpty) return;

    final maxValue = values.reduce(math.max);
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = values.length == 1
          ? size.width / 2
          : size.width * index / (values.length - 1);
      final y = maxValue == 0
          ? size.height
          : size.height * (1 - values[index] / maxValue);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    if (values.length == 1) {
      canvas.drawCircle(
        Offset(size.width / 2, maxValue == 0 ? size.height : 0),
        4,
        Paint()..color = color,
      );
      return;
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.10));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

class _TrendLabels extends StatelessWidget {
  const _TrendLabels({required this.points});

  final List<ReportTrendPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    final last = points.length - 1;
    final indexes = <int>{0, last ~/ 3, (last * 2) ~/ 3, last}.toList()..sort();
    return Row(
      children: [
        for (final index in indexes)
          Expanded(
            child: Text(
              _shortDate(points[index].date),
              textAlign: index == 0
                  ? TextAlign.start
                  : index == last
                  ? TextAlign.end
                  : TextAlign.center,
            ),
          ),
      ],
    );
  }
}

class _ChannelMixCard extends StatelessWidget {
  const _ChannelMixCard({required this.channels});

  final List<ReportChannel> channels;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sales by channel',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Current reporting period',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 31),
            for (final channel in channels) ...[
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _channelColor(channel.channel),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(child: Text(channel.label)),
                  Text(
                    '${channel.revenuePercent.toStringAsFixed(1)}%',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: (channel.revenuePercent / 100).clamp(0.0, 1.0),
                color: _channelColor(channel.channel),
                minHeight: 8,
                borderRadius: BorderRadius.circular(8),
              ),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }
}

class _LocationTable extends StatelessWidget {
  const _LocationTable({required this.rows});

  final List<ReportLocationPerformance> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Location performance',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('LOCATION')),
                  DataColumn(label: Text('NET SALES'), numeric: true),
                  DataColumn(label: Text('ORDERS'), numeric: true),
                  DataColumn(label: Text('AVG. TICKET'), numeric: true),
                  DataColumn(label: Text('GROWTH'), numeric: true),
                ],
                rows: [
                  for (final row in rows)
                    DataRow(
                      cells: [
                        DataCell(
                          Text(
                            row.locationName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        DataCell(
                          Text(
                            _formatMoney(row.revenueMinor, row.currencyCode),
                          ),
                        ),
                        DataCell(Text(_formatInteger(row.orderTotal))),
                        DataCell(
                          Text(
                            _formatMoney(
                              row.averageTicketMinor,
                              row.currencyCode,
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            _formatGrowth(row.revenueGrowthPercent),
                            style: TextStyle(
                              color: _growthColor(
                                context,
                                row.revenueGrowthPercent,
                              ),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
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

class _ReportsLoading extends StatelessWidget {
  const _ReportsLoading();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: SizedBox(
        height: 260,
        width: double.infinity,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading reports…'),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportsEmpty extends StatelessWidget {
  const _ReportsEmpty();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SizedBox(
        height: 260,
        width: double.infinity,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.query_stats_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 14),
              Text(
                'No report data for this period',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Choose another period or location, then refresh.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportsError extends StatelessWidget {
  const _ReportsError({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SizedBox(
        height: 260,
        width: double.infinity,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 14),
              Text(
                'Reports are unavailable',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text('Check your connection and try again.'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _channelColor(String channel) => switch (channel) {
  'dine_in' => const Color(0xFF42D3A5),
  'delivery' => const Color(0xFF64B5F6),
  'pickup' => const Color(0xFFFFB74D),
  _ => const Color(0xFFCE93D8),
};

Color _growthColor(BuildContext context, double? growth) {
  if (growth == null || growth == 0) {
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }
  return growth > 0
      ? Theme.of(context).colorScheme.primary
      : Theme.of(context).colorScheme.error;
}

String _formatGrowth(double? value) {
  if (value == null) return 'Not available';
  final prefix = value > 0 ? '+' : '';
  return '$prefix${value.toStringAsFixed(1)}%';
}

String _formatMoney(int minorUnits, String currencyCode) {
  final whole = minorUnits ~/ 100;
  final fraction = minorUnits.remainder(100).abs();
  final formatted = _formatInteger(whole);
  final amount = fraction == 0
      ? formatted
      : '$formatted.${fraction.toString().padLeft(2, '0')}';
  final symbol = switch (currencyCode.toUpperCase()) {
    'INR' => '\u20B9',
    'USD' => r'$',
    'EUR' => '\u20AC',
    'GBP' => '\u00A3',
    '' => '',
    _ => '${currencyCode.toUpperCase()} ',
  };
  return '$symbol$amount';
}

String _formatInteger(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return '${value < 0 ? '-' : ''}$buffer';
}

String _periodLabel(ReportPeriod period) => switch (period) {
  ReportPeriod.last7Days => 'Last 7 days',
  ReportPeriod.last30Days => 'Last 30 days',
  ReportPeriod.thisQuarter => 'This quarter',
};

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
