class AudioApiCost {
  const AudioApiCost({
    this.audioDurationSeconds,
    this.sarvamModel,
    this.sarvamEstimatedCostInr,
    this.openaiModel,
    this.openaiInputTokens,
    this.openaiCachedInputTokens,
    this.openaiOutputTokens,
    this.openaiTotalTokens,
    this.openaiEstimatedCostUsd,
    this.totalEstimatedCost = const {},
  });

  final double? audioDurationSeconds;
  final String? sarvamModel;
  final double? sarvamEstimatedCostInr;
  final String? openaiModel;
  final int? openaiInputTokens;
  final int? openaiCachedInputTokens;
  final int? openaiOutputTokens;
  final int? openaiTotalTokens;
  final double? openaiEstimatedCostUsd;
  final Map<String, double> totalEstimatedCost;

  double? get totalInr => totalEstimatedCost['INR'] ?? sarvamEstimatedCostInr;

  double? get totalUsd => totalEstimatedCost['USD'] ?? openaiEstimatedCostUsd;

  bool get isAvailable =>
      sarvamModel != null ||
      sarvamEstimatedCostInr != null ||
      openaiModel != null ||
      openaiInputTokens != null ||
      openaiCachedInputTokens != null ||
      openaiOutputTokens != null ||
      openaiTotalTokens != null ||
      openaiEstimatedCostUsd != null ||
      totalEstimatedCost.isNotEmpty;

  factory AudioApiCost.fromJson(Map<String, dynamic> json) {
    return AudioApiCost(
      audioDurationSeconds: _nullableDouble(json, 'audio_duration_seconds'),
      sarvamModel: _nullableString(json, 'sarvam_model'),
      sarvamEstimatedCostInr: _nullableDouble(
        json,
        'sarvam_estimated_cost_inr',
      ),
      openaiModel: _nullableString(json, 'openai_model'),
      openaiInputTokens: _nullableInt(json, 'openai_input_tokens'),
      openaiCachedInputTokens: _nullableInt(json, 'openai_cached_input_tokens'),
      openaiOutputTokens: _nullableInt(json, 'openai_output_tokens'),
      openaiTotalTokens: _nullableInt(json, 'openai_total_tokens'),
      openaiEstimatedCostUsd: _nullableDouble(
        json,
        'openai_estimated_cost_usd',
      ),
      totalEstimatedCost: _costTotals(json['total_estimated_cost']),
    );
  }
}

String? _nullableString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is String && value.trim().isNotEmpty) return value.trim();
  throw FormatException('Invalid audio API cost $field.');
}

double? _nullableDouble(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  final parsed = switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text),
    _ => null,
  };
  if (parsed == null || !parsed.isFinite || parsed < 0) {
    throw FormatException('Invalid audio API cost $field.');
  }
  return parsed;
}

int? _nullableInt(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is int && value >= 0) return value;
  throw FormatException('Invalid audio API cost $field.');
}

Map<String, double> _costTotals(Object? value) {
  if (value == null) return const {};
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid audio API cost total_estimated_cost.');
  }
  final result = <String, double>{};
  for (final currency in const ['INR', 'USD']) {
    final raw = value[currency];
    if (raw == null) continue;
    final parsed = switch (raw) {
      num number => number.toDouble(),
      String text => double.tryParse(text),
      _ => null,
    };
    if (parsed == null || !parsed.isFinite || parsed < 0) {
      throw FormatException(
        'Invalid audio API cost total_estimated_cost.$currency.',
      );
    }
    result[currency] = parsed;
  }
  return Map.unmodifiable(result);
}
