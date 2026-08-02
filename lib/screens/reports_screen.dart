import 'package:flutter/material.dart';

import '../widgets/page_header.dart';

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Reports',
            description:
                'Review financial and operational performance across locations.',
            action: FilledButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: const Text('Export CSV'),
            ),
          ),
          const SizedBox(height: 28),
          const _ReportFilters(),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 820;
              if (stacked) {
                return const Column(
                  children: [
                    _PerformanceCard(),
                    SizedBox(height: 16),
                    _ChannelMixCard(),
                  ],
                );
              }
              return const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: _PerformanceCard()),
                  SizedBox(width: 16),
                  Expanded(child: _ChannelMixCard()),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          const _LocationTable(),
        ],
      ),
    );
  }
}

class _ReportFilters extends StatelessWidget {
  const _ReportFilters();

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
              child: DropdownButtonFormField<String>(
                initialValue: 'All locations',
                decoration: const InputDecoration(
                  labelText: 'Location',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'All locations',
                    child: Text('All locations'),
                  ),
                  DropdownMenuItem(value: 'Bandra', child: Text('Bandra')),
                  DropdownMenuItem(value: 'Powai', child: Text('Powai')),
                  DropdownMenuItem(
                    value: 'Lower Parel',
                    child: Text('Lower Parel'),
                  ),
                ],
                onChanged: (_) {},
              ),
            ),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                initialValue: 'Last 30 days',
                decoration: const InputDecoration(
                  labelText: 'Period',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'Last 7 days',
                    child: Text('Last 7 days'),
                  ),
                  DropdownMenuItem(
                    value: 'Last 30 days',
                    child: Text('Last 30 days'),
                  ),
                  DropdownMenuItem(
                    value: 'This quarter',
                    child: Text('This quarter'),
                  ),
                ],
                onChanged: (_) {},
              ),
            ),
            OutlinedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard();

  @override
  Widget build(BuildContext context) {
    const values = [
      0.52,
      0.58,
      0.54,
      0.68,
      0.72,
      0.66,
      0.78,
      0.82,
      0.76,
      0.91,
      0.86,
      0.96,
    ];
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
                  '₹68.4L',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Combined across all locations',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 220,
              child: CustomPaint(
                painter: _TrendPainter(
                  values: values,
                  color: Theme.of(context).colorScheme.primary,
                ),
                size: Size.infinite,
              ),
            ),
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Jul 01'),
                Text('Jul 10'),
                Text('Jul 20'),
                Text('Jul 31'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()..color = color.withValues(alpha: 0.10);
    for (var line = 0; line <= 4; line++) {
      final y = size.height * line / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = size.width * index / (values.length - 1);
      final y = size.height * (1 - values[index]);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
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

class _ChannelMixCard extends StatelessWidget {
  const _ChannelMixCard();

  @override
  Widget build(BuildContext context) {
    const channels = [
      ('Dine-in', 0.62, Color(0xFF42D3A5)),
      ('Delivery', 0.24, Color(0xFF64B5F6)),
      ('Pickup', 0.14, Color(0xFFFFB74D)),
    ];
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
                      color: channel.$3,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(child: Text(channel.$1)),
                  Text(
                    '${(channel.$2 * 100).round()}%',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: channel.$2,
                color: channel.$3,
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
  const _LocationTable();

  @override
  Widget build(BuildContext context) {
    const rows = [
      ('Bandra', '₹28,44,800', '4,120', '₹690', '+12.8%'),
      ('Powai', '₹22,18,400', '3,410', '₹651', '+8.4%'),
      ('Lower Parel', '₹17,76,900', '2,530', '₹702', '+15.1%'),
    ];
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
                rows: rows
                    .map(
                      (row) => DataRow(
                        cells: [
                          DataCell(
                            Text(
                              row.$1,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          DataCell(Text(row.$2)),
                          DataCell(Text(row.$3)),
                          DataCell(Text(row.$4)),
                          DataCell(
                            Text(
                              row.$5,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
