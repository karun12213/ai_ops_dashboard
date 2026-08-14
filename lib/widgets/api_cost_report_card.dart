import 'package:flutter/material.dart';

import '../models/audio_api_cost.dart';

class ApiCostReportCard extends StatelessWidget {
  const ApiCostReportCard({super.key, required this.cost});

  final AudioApiCost cost;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.payments_outlined, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'API Cost Report',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (!cost.isAvailable)
              Text(
                'Cost data unavailable for this upload.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              )
            else ...[
              _CostField(
                label: 'Audio Duration',
                value: _formatDuration(cost.audioDurationSeconds),
              ),
              _CostField(
                label: 'Sarvam Model',
                value: cost.sarvamModel ?? 'Unavailable',
              ),
              _CostField(
                label: 'Sarvam Estimated Cost (INR)',
                value: _formatInr(cost.sarvamEstimatedCostInr),
              ),
              const Divider(height: 28),
              _CostField(
                label: 'OpenAI Model',
                value: cost.openaiModel ?? 'Unavailable',
              ),
              _CostField(
                label: 'Input Tokens',
                value: _formatTokens(cost.openaiInputTokens),
              ),
              _CostField(
                label: 'Cached Input Tokens',
                value: _formatTokens(cost.openaiCachedInputTokens),
              ),
              _CostField(
                label: 'Output Tokens',
                value: _formatTokens(cost.openaiOutputTokens),
              ),
              _CostField(
                label: 'Total Tokens',
                value: _formatTokens(cost.openaiTotalTokens),
              ),
              _CostField(
                label: 'OpenAI Estimated Cost (USD)',
                value: _formatUsd(cost.openaiEstimatedCostUsd),
              ),
              const Divider(height: 28),
              Text(
                'Total Estimated Cost',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  Text(
                    'Sarvam: ${_formatInr(cost.totalInr)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    'OpenAI: ${_formatUsd(cost.totalUsd)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              if (_canCalculateRates(cost)) ...[
                const Divider(height: 28),
                _CostField(
                  label: 'Cost per recorded minute',
                  value: _formatRate(cost, seconds: 60),
                ),
                _CostField(
                  label: 'Estimated cost per recorded hour',
                  value: _formatRate(cost, seconds: 3600),
                  isLast: true,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _CostField extends StatelessWidget {
  const _CostField({
    required this.label,
    required this.value,
    this.isLast = false,
  });

  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          Text('$label:', style: const TextStyle(fontWeight: FontWeight.w700)),
          SelectableText(value),
        ],
      ),
    );
  }
}

bool _canCalculateRates(AudioApiCost cost) =>
    (cost.audioDurationSeconds ?? 0) > 0 &&
    (cost.totalInr != null || cost.totalUsd != null);

String _formatRate(AudioApiCost cost, {required double seconds}) {
  final duration = cost.audioDurationSeconds;
  if (duration == null || duration <= 0) return 'Unavailable';
  final multiplier = seconds / duration;
  final values = <String>[];
  if (cost.totalInr case final value?) {
    values.add('Sarvam ${_formatInr(value * multiplier)}');
  }
  if (cost.totalUsd case final value?) {
    values.add('OpenAI ${_formatUsd(value * multiplier)}');
  }
  return values.isEmpty ? 'Unavailable' : values.join(' · ');
}

String _formatDuration(double? seconds) {
  if (seconds == null) return 'Unavailable';
  return '${seconds.toStringAsFixed(1)} seconds';
}

String _formatTokens(int? value) {
  if (value == null) return 'Unavailable';
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

String _formatInr(double? value) => _formatCurrency(value, '₹', 2);

String _formatUsd(double? value) => _formatCurrency(value, r'$', 4);

String _formatCurrency(double? value, String symbol, int decimalPlaces) {
  if (value == null) return 'Unavailable';
  return '$symbol${value.toStringAsFixed(decimalPlaces)}';
}
