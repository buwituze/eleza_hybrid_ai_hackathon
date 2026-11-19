import 'package:flutter/material.dart';

import '../services/hybrid_ai_service.dart' show OnDeviceStatus;

/// On-device / Cloud badges for Firebase AI Logic hybrid inference.
///
/// Everything here works on the trace JSON shape shared by the kiosk
/// (`AiTrace.toJson()`) and the doctor brief (`doctor_brief['ai_trace']`):
///   {step, source: on_device|in_cloud, mode, fallback_reason?, latency_ms}

const _onDeviceColor = Color(0xFF2E7D32); // green — data stayed on the kiosk
const _cloudColor = Color(0xFF1565C0); // blue — Gemini in the cloud
const _fallbackColor = Color(0xFFEF6C00); // orange — on-device fell back

const _stepLabels = {
  'translation': 'Translation',
  'extraction': 'Symptom extraction',
  'question': 'Follow-up question',
  'score': 'Triage score',
  'routing': 'Routing',
  'guidance': 'Patient message',
  'brief': 'Doctor brief',
};

const _fallbackLabels = {
  'timeout': 'on-device too slow → cloud',
  'device_slow': 'device busy → cloud',
  'device_unavailable': 'model not on this device → cloud',
  'device_error': 'on-device error → cloud',
};

String aiStepLabel(String? step) => _stepLabels[step] ?? (step ?? 'AI step');

/// A single "On-device" / "Cloud" chip.
class AiSourceBadge extends StatelessWidget {
  const AiSourceBadge({
    super.key,
    required this.source,
    this.label,
    this.fallbackReason,
    this.latencyMs,
    this.dense = false,
  });

  /// Builds a badge from a trace map.
  factory AiSourceBadge.fromTrace(
    Map<String, dynamic> trace, {
    bool showStep = true,
    bool dense = false,
  }) => AiSourceBadge(
    source: trace['source']?.toString() ?? 'in_cloud',
    label: showStep ? aiStepLabel(trace['step']?.toString()) : null,
    fallbackReason: trace['fallback_reason']?.toString(),
    latencyMs: (trace['latency_ms'] as num?)?.toInt(),
    dense: dense,
  );

  final String source;
  final String? label;
  final String? fallbackReason;
  final int? latencyMs;
  final bool dense;

  bool get _onDevice => source == 'on_device';

  @override
  Widget build(BuildContext context) {
    final color =
        _onDevice
            ? _onDeviceColor
            : (fallbackReason != null ? _fallbackColor : _cloudColor);
    final where = _onDevice ? 'On-device' : 'Cloud';
    final text = label == null ? where : '$label · $where';
    final tooltip = [
      _onDevice
          ? 'Ran on this device with Gemini Nano — the text did not leave it.'
          : 'Ran on Gemini in the cloud via Firebase AI Logic.',
      if (fallbackReason != null)
        'Fallback: ${_fallbackLabels[fallbackReason] ?? fallbackReason}',
      if (latencyMs != null) '${(latencyMs! / 1000).toStringAsFixed(1)} s',
    ].join('\n');

    return Tooltip(
      message: tooltip,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 6 : 8,
          vertical: dense ? 2 : 4,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _onDevice ? Icons.lock_outline : Icons.cloud_outlined,
              size: dense ? 12 : 14,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                fontSize: dense ? 11 : 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            if (fallbackReason != null) ...[
              const SizedBox(width: 3),
              Icon(Icons.swap_horiz, size: dense ? 12 : 14, color: color),
            ],
          ],
        ),
      ),
    );
  }
}

/// Summary line + one badge per AI step.
class AiTraceSummary extends StatelessWidget {
  const AiTraceSummary({
    super.key,
    required this.traces,
    this.dense = false,
    this.showHeadline = true,
  });

  final List<Map<String, dynamic>> traces;
  final bool dense;
  final bool showHeadline;

  /// Reads `doctor_brief['ai_trace']` safely.
  static List<Map<String, dynamic>> tracesFrom(dynamic raw) => [
    if (raw is List)
      for (final t in raw)
        if (t is Map) t.cast<String, dynamic>(),
  ];

  @override
  Widget build(BuildContext context) {
    if (traces.isEmpty) {
      return Text(
        'No AI trace recorded for this session.',
        style: TextStyle(fontSize: dense ? 12 : 13, color: Colors.grey),
      );
    }
    final onDevice = traces.where((t) => t['source'] == 'on_device').length;
    final fallbacks = traces.where((t) => t['fallback_reason'] != null).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHeadline)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '$onDevice of ${traces.length} AI steps ran on-device'
              '${fallbacks > 0 ? ' · $fallbacks fell back to the cloud' : ''}',
              style: TextStyle(
                fontSize: dense ? 12 : 13,
                color: Colors.grey.shade800,
              ),
            ),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in traces) AiSourceBadge.fromTrace(t, dense: dense),
          ],
        ),
      ],
    );
  }
}

/// Kiosk indicator for the Gemini Nano model itself.
class OnDeviceModelChip extends StatelessWidget {
  const OnDeviceModelChip({super.key, this.status, this.downloadProgress});

  final OnDeviceStatus? status;
  final double? downloadProgress;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (status) {
      OnDeviceStatus.available => (
        Icons.lock_outline,
        'On-device AI ready',
        _onDeviceColor,
      ),
      OnDeviceStatus.downloading || OnDeviceStatus.downloadable
          when downloadProgress != null && downloadProgress! < 1 =>
        (
          Icons.downloading,
          'Preparing on-device AI ${(downloadProgress! * 100).round()}%',
          _fallbackColor,
        ),
      OnDeviceStatus.downloading || OnDeviceStatus.downloadable => (
        Icons.downloading,
        'On-device AI not ready · using cloud',
        _fallbackColor,
      ),
      null => (Icons.hourglass_empty, 'Checking on-device AI…', Colors.grey),
      _ => (Icons.cloud_outlined, 'Cloud AI', _cloudColor),
    };
    return Tooltip(
      message:
          'Gemini Nano runs inside Chrome on this kiosk. When it is not '
          'available or too slow, Firebase AI Logic uses Gemini in the cloud.',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
