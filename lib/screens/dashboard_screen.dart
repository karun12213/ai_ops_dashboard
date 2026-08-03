import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/dashboard_data.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/page_header.dart';
import '../widgets/stat_card.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedDate = ref.watch(dashboardDateProvider);
    final dashboard = ref.watch(dashboardProvider);
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Good service starts here',
            description:
                'A live operational snapshot for ${_longDate(selectedDate)}.',
            action: OutlinedButton.icon(
              onPressed: () => _selectDate(context, ref, selectedDate),
              icon: const Icon(Icons.calendar_today_outlined, size: 18),
              label: Text(
                _isToday(selectedDate) ? 'Today' : _shortDate(selectedDate),
              ),
            ),
          ),
          const SizedBox(height: 28),
          dashboard.when(
            loading: () => const _DashboardLoading(),
            error: (_, _) => _DashboardError(
              onRetry: () => ref.invalidate(dashboardProvider),
            ),
            data: (data) => _DashboardContent(data: data),
          ),
        ],
      ),
    );
  }

  Future<void> _selectDate(
    BuildContext context,
    WidgetRef ref,
    DateTime selectedDate,
  ) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'Select service date',
    );
    if (picked == null || !context.mounted) return;
    ref.read(dashboardDateProvider.notifier).state = DateTime(
      picked.year,
      picked.month,
      picked.day,
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    final snapshot = data.snapshot;
    if (snapshot == null && data.recentActivity.isEmpty) {
      return const _DashboardEmpty();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (snapshot == null)
          const _SnapshotEmpty()
        else ...[
          _MetricGrid(metrics: snapshot.metrics),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 850;
              final sales = _SalesOverview(snapshot: snapshot);
              final pulse = _ServicePulse(snapshot: snapshot);
              if (stacked) {
                return Column(
                  children: [sales, const SizedBox(height: 16), pulse],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: sales),
                  const SizedBox(width: 16),
                  Expanded(child: pulse),
                ],
              );
            },
          ),
        ],
        const SizedBox(height: 16),
        _RecentActivity(activities: data.recentActivity),
      ],
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});

  final DashboardMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1150
            ? 4
            : constraints.maxWidth >= 620
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
              child: StatCard(
                label: 'Net sales',
                value: _formatMoney(
                  metrics.netSalesMinor,
                  metrics.currencyCode,
                ),
                change: _formatChange(metrics.netSalesChangePercent),
                changeIsIncrease: _isIncrease(metrics.netSalesChangePercent),
                changeIsFavorable: _isIncrease(metrics.netSalesChangePercent),
                icon: Icons.payments_outlined,
                color: const Color(0xFF42D3A5),
              ),
            ),
            SizedBox(
              width: width,
              child: StatCard(
                label: 'Orders served',
                value: _formatInteger(metrics.ordersServed),
                change: _formatChange(metrics.ordersChangePercent),
                changeIsIncrease: _isIncrease(metrics.ordersChangePercent),
                changeIsFavorable: _isIncrease(metrics.ordersChangePercent),
                icon: Icons.receipt_long_outlined,
                color: const Color(0xFF64B5F6),
              ),
            ),
            SizedBox(
              width: width,
              child: StatCard(
                label: 'Average ticket',
                value: _formatMoney(
                  metrics.averageTicketMinor,
                  metrics.currencyCode,
                ),
                change: _formatChange(metrics.averageTicketChangePercent),
                changeIsIncrease: _isIncrease(
                  metrics.averageTicketChangePercent,
                ),
                changeIsFavorable: _isIncrease(
                  metrics.averageTicketChangePercent,
                ),
                icon: Icons.point_of_sale_outlined,
                color: const Color(0xFFFFB74D),
              ),
            ),
            SizedBox(
              width: width,
              child: StatCard(
                label: 'Table turn time',
                value: metrics.averageTableTurnMinutes == null
                    ? 'Not reported'
                    : '${metrics.averageTableTurnMinutes} min',
                change: _formatChange(metrics.tableTurnChangePercent),
                changeIsIncrease: _isIncrease(metrics.tableTurnChangePercent),
                changeIsFavorable:
                    metrics.tableTurnChangePercent != null &&
                    metrics.tableTurnChangePercent! <= 0,
                icon: Icons.timer_outlined,
                color: const Color(0xFFCE93D8),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SalesOverview extends StatelessWidget {
  const _SalesOverview({required this.snapshot});

  final DashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final points = snapshot.hourlySales;
    final maximum = points.fold<int>(
      0,
      (current, point) =>
          point.netSalesMinor > current ? point.netSalesMinor : current,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sales overview',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Hourly net sales',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(snapshot.serviceOpen ? 'Open service' : 'Closed'),
                ),
              ],
            ),
            const SizedBox(height: 28),
            if (points.isEmpty)
              const _SectionEmpty(
                icon: Icons.bar_chart_rounded,
                message: 'No hourly sales have been recorded.',
              )
            else ...[
              SizedBox(
                height: 210,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var index = 0; index < points.length; index++) ...[
                      Expanded(
                        child: Tooltip(
                          message:
                              '${_formatHour(points[index].hour)} · '
                              '${_formatMoney(points[index].netSalesMinor, snapshot.metrics.currencyCode)}',
                          child: FractionallySizedBox(
                            heightFactor: maximum == 0
                                ? 0.04
                                : (points[index].netSalesMinor / maximum).clamp(
                                    0.04,
                                    1.0,
                                  ),
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              decoration: BoxDecoration(
                                color: index == points.length - 1
                                    ? scheme.primary
                                    : scheme.primary.withValues(alpha: 0.35),
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(6),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (index < points.length - 1) const SizedBox(width: 7),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatHour(points.first.hour),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  Text(
                    _formatHour(points.last.hour),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ServicePulse extends StatelessWidget {
  const _ServicePulse({required this.snapshot});

  final DashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final pulse = snapshot.servicePulse;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Service pulse',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Current floor status',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 25),
            _PulseItem(
              label: 'Dining room',
              detail: pulse.totalTables == 0
                  ? '${pulse.occupiedTables} tables reported'
                  : '${pulse.occupiedTables} of ${pulse.totalTables} tables',
              value: _ratio(pulse.occupiedTables, pulse.totalTables),
              color: const Color(0xFF42D3A5),
            ),
            const SizedBox(height: 22),
            _PulseItem(
              label: 'Kitchen load',
              detail: '${pulse.activeKitchenTickets} active tickets',
              value: _ratio(pulse.activeKitchenTickets, pulse.kitchenCapacity),
              color: const Color(0xFFFFB74D),
            ),
            const SizedBox(height: 22),
            _PulseItem(
              label: 'Pickup queue',
              detail: '${pulse.pickupOrders} orders',
              value: _ratio(pulse.pickupOrders, pulse.pickupCapacity),
              color: const Color(0xFF64B5F6),
            ),
            const SizedBox(height: 22),
            _PulseItem(
              label: 'Staff on shift',
              detail: pulse.staffScheduled == 0
                  ? '${pulse.staffOnShift} reported'
                  : '${pulse.staffOnShift} of ${pulse.staffScheduled}',
              value: _ratio(pulse.staffOnShift, pulse.staffScheduled),
              color: const Color(0xFFCE93D8),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulseItem extends StatelessWidget {
  const _PulseItem({
    required this.label,
    required this.detail,
    required this.value,
    required this.color,
  });

  final String label;
  final String detail;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              detail,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        LinearProgressIndicator(
          value: value,
          minHeight: 7,
          borderRadius: BorderRadius.circular(8),
          color: color,
        ),
      ],
    );
  }
}

class _RecentActivity extends StatelessWidget {
  const _RecentActivity({required this.activities});

  final List<DashboardActivity> activities;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent activity',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (activities.isEmpty)
              const _SectionEmpty(
                icon: Icons.history_toggle_off_rounded,
                message: 'No activity has been recorded for this date.',
              )
            else
              for (var index = 0; index < activities.length; index++) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    child: Icon(
                      _activityIcon(activities[index].category),
                      size: 20,
                    ),
                  ),
                  title: Text(activities[index].title),
                  subtitle: Text(activities[index].actor),
                  trailing: Text(_formatTime(activities[index].occurredAt)),
                ),
                if (index < activities.length - 1) const Divider(height: 1),
              ],
          ],
        ),
      ),
    );
  }
}

class _DashboardLoading extends StatelessWidget {
  const _DashboardLoading();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 320,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading Dashboard…'),
          ],
        ),
      ),
    );
  }
}

class _DashboardError extends StatelessWidget {
  const _DashboardError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 44,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Dashboard data is unavailable',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Check the connection and try again.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
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

class _DashboardEmpty extends StatelessWidget {
  const _DashboardEmpty();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 56),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.event_note_rounded,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'No Dashboard data yet',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Operational metrics and activity will appear when data is recorded for this date.',
                textAlign: TextAlign.center,
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

class _SnapshotEmpty extends StatelessWidget {
  const _SnapshotEmpty();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: _SectionEmpty(
          icon: Icons.monitor_heart_outlined,
          message: 'No operational snapshot has been recorded for this date.',
        ),
      ),
    );
  }
}

class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 36,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
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

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String _longDate(DateTime value) {
  return '${_weekdayNames[value.weekday - 1]}, '
      '${_monthNames[value.month - 1]} ${value.day}, ${value.year}';
}

String _shortDate(DateTime value) {
  return '${_monthNames[value.month - 1].substring(0, 3)} ${value.day}';
}

bool _isToday(DateTime value) {
  final now = DateTime.now();
  return value.year == now.year &&
      value.month == now.month &&
      value.day == now.day;
}

bool _isIncrease(double? value) => value != null && value >= 0;

String? _formatChange(double? value) {
  if (value == null) return null;
  return '${value.abs().toStringAsFixed(1)}%';
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
    'EUR' => '€',
    'GBP' => '£',
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

String _formatHour(int hour) {
  final normalized = hour % 24;
  final displayHour = normalized == 0
      ? 12
      : normalized > 12
      ? normalized - 12
      : normalized;
  return '$displayHour ${normalized < 12 ? 'AM' : 'PM'}';
}

String _formatTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour == 0
      ? 12
      : local.hour > 12
      ? local.hour - 12
      : local.hour;
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${local.hour < 12 ? 'AM' : 'PM'}';
}

double _ratio(int value, int capacity) {
  if (capacity <= 0) return 0;
  return (value / capacity).clamp(0.0, 1.0).toDouble();
}

IconData _activityIcon(String category) {
  return switch (category.toLowerCase()) {
    'service' => Icons.door_front_door_outlined,
    'inventory' => Icons.inventory_2_outlined,
    'export' => Icons.file_download_outlined,
    'staff' => Icons.groups_outlined,
    _ => Icons.bolt_outlined,
  };
}
