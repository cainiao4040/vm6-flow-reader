import 'package:flutter/material.dart';

/// 圆形实时指标表盘
class MetricGauge extends StatelessWidget {
  const MetricGauge({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    this.color,
  });

  final String label;
  final double? value;
  final String unit;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          value == null ? '--' : value!.toStringAsFixed(4),
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: c,
          ),
        ),
        if (unit.isNotEmpty)
          Text(unit, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
